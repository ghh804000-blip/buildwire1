#!/usr/bin/env python3
"""
import_extracted.py  –  Convert extracted component.json assets into the
DeviceDef index.json format used by the BuildWire app.

Usage:
    python -I import_extracted.py              # normal run (copies images + writes index.json)
    python -I import_extracted.py --dry-run    # parse & convert only, print summary, skip file I/O
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import unicodedata
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths (relative to this script's location inside buildwire/tools/)
# ---------------------------------------------------------------------------

SCRIPT_DIR   = Path(__file__).resolve().parent                       # buildwire/tools/
TD_ROOT      = SCRIPT_DIR.parent                                     # buildwire/
PROJECT_ROOT = TD_ROOT.parent                                       # yap/
EXTRACTED    = PROJECT_ROOT / "assets" / "extracted"
DEVICES_DIR  = TD_ROOT / "assets" / "devices"
INDEX_JSON   = DEVICES_DIR / "index.json"

# ---------------------------------------------------------------------------
# Signal → class mapping
# ---------------------------------------------------------------------------
SIGNAL_MAP: dict[str, str] = {
    "Power":     "power",
    "Potencia":  "power",
    "Control":   "control",
    "Señal":     "control",
    "Signal":    "control",
}

# ---------------------------------------------------------------------------
# Category directory name → (category slug, human-readable label in Indonesian)
# ---------------------------------------------------------------------------
CATEGORY_MAP: dict[str, tuple[str, str]] = {
    "ACTUATORS":                ("loads",        "Beban"),
    "AUXILIARY BLOCKS":         ("contactors",   "Kontaktor"),
    "CONTACTORS":               ("contactors",   "Kontaktor"),
    "CONTROL DEVICES":          ("control",      "Kontrol"),
    "DIN RAIL":                 ("structure",    "Struktur panel"),
    "DISTRIBUTION":             ("terminals",    "Terminal dan busbar"),
    "DRIVES":                   ("control",      "Kontrol"),
    "ENCAPSULATED RELAY":       ("relays",       "Relay dan timer"),
    "ENCLOSURES":               ("structure",    "Struktur panel"),
    "MCB":                      ("protection",   "Proteksi"),
    "MCCB":                     ("protection",   "Proteksi"),
    "METERS & INSTRUMENTS":     ("meters",       "Alat ukur"),
    "MPCB":                     ("protection",   "Proteksi"),
    "PASSIVE COMPONENTS":       ("loads",        "Beban"),
    "PHASE MONITORING RELAYS":  ("relays",       "Relay dan timer"),
    "PHASE PROTECTION RELAY":   ("protection",   "Proteksi"),
    "PLC":                      ("automation",   "PLC dan HMI"),
    "POWER SUPPLY":             ("sources",      "Sumber"),
    "RCCB":                     ("protection",   "Proteksi"),
    "SAFETY RELAY":             ("relays",       "Relay dan timer"),
    "SENSORS":                  ("sensors",      "Sensor"),
    "SIGNALING":                ("loads",        "Beban"),
    "SOCKET OUTLETS":           ("loads",        "Beban"),
    "THERMAL OVERLOAD RELAYS":  ("protection",   "Proteksi"),
    "TIMERS":                   ("relays",       "Relay dan timer"),
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def slugify(text: str) -> str:
    """Create a safe, clean identifier for filenames and index references."""
    text = text.replace("+", "_plus_").replace("-", "_minus_").replace(",", "_")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^\w\s]", "", text.lower()).strip()
    return re.sub(r"[\s_]+", "_", text).strip("_")


def get_name(comp: dict, default_id: str) -> str:
    """Return a human-readable name from name field (dict or str) or id."""
    name_field = comp.get("name")
    if isinstance(name_field, dict):
        return (
            name_field.get("en")
            or name_field.get("es")
            or name_field.get("ar")
            or next(iter(name_field.values()), "")
            or default_id
        )
    elif isinstance(name_field, str) and name_field.strip():
        return name_field.strip()
    return default_id


def size_mm(comp: dict) -> dict[str, float]:
    """Compute size_mm from physical dims or graphics size."""
    phys = comp.get("physical", {})
    w = phys.get("widthMm")
    h = phys.get("heightMm")
    if w is not None and h is not None:
        try:
            return {"width": round(float(w), 1), "height": round(float(h), 1)}
        except (ValueError, TypeError):
            pass

    gfx = comp.get("graphics", {}).get("size", {})
    pw = gfx.get("width")
    ph = gfx.get("height")
    if pw and ph:
        try:
            fpw = float(pw)
            fph = float(ph)
            # Units >= 1000 are in 1/100 mm (e.g. 4800x8400 -> 48x84 mm)
            if fpw >= 1000 or fph >= 1000:
                return {"width": round(fpw / 100.0, 1), "height": round(fph / 100.0, 1)}
            elif fpw > 300 or fph > 300:
                # Pixel dimensions of rendered images (~10 px per mm)
                return {"width": round(fpw / 10.0, 1), "height": round(fph / 10.0, 1)}
            else:
                return {"width": round(fpw, 1), "height": round(fph, 1)}
        except (ValueError, TypeError):
            pass

    return {"width": 54.0, "height": 90.0}


def map_terminals(comp: dict) -> list[dict]:
    """Convert component.json terminals to DeviceDef terminal format."""
    out: list[dict] = []
    seen = set()
    for t in comp.get("terminals", []):
        tid = str(t.get("id", "")).strip()
        if not tid:
            continue
        # Ensure terminal IDs are unique per device
        if tid in seen:
            orig = tid
            k = 2
            while f"{orig}_{k}" in seen:
                k += 1
            tid = f"{orig}_{k}"
        seen.add(tid)

        nx = float(t.get("nx", 0.5))
        ny = float(t.get("ny", 0.5))
        direction = t.get("direction")
        if direction not in ("top", "bottom", "left", "right"):
            direction = "top" if ny < 0.5 else "bottom"

        sig = t.get("signal", "")
        wire_class = SIGNAL_MAP.get(sig, "power")

        out.append({
            "id": tid,
            "x": round(nx, 4),
            "y": round(ny, 4),
            "side": direction,
            "class": wire_class,
        })
    return out


def extract_ratings(comp: dict) -> dict:
    """Build ratings dict from simulation and physical fields."""
    sim = comp.get("simulation", {})
    ratings: dict[str, Any] = {}

    rc = sim.get("ratedCurrentA")
    if rc is not None:
        try:
            ratings["rated_current_a"] = float(rc)
        except (ValueError, TypeError):
            pass

    curve = sim.get("protectionCurve")
    if curve:
        ratings["curve"] = str(curve)

    for tp in sim.get("terminalPairs", []):
        supply = tp.get("supply", {})
        rv = supply.get("ratedVoltageV")
        if rv is not None:
            try:
                ratings["rated_voltage_v"] = float(rv)
            except (ValueError, TypeError):
                pass
            break

    return ratings


def convert_component(comp_json_path: Path, category_dir_name: str) -> dict | None:
    """Read component.json and convert to DeviceDef format."""
    try:
        with open(comp_json_path, "r", encoding="utf-8") as f:
            comp = json.load(f)
    except Exception as exc:
        print(f"  WARNING: cannot read {comp_json_path}: {exc}", file=sys.stderr)
        return None

    raw_id = comp.get("id") or comp_json_path.parent.name
    cid = slugify(raw_id)
    name = get_name(comp, comp_json_path.parent.name)

    cat_slug, cat_label = CATEGORY_MAP.get(
        category_dir_name, (category_dir_name.lower().replace(" ", "_"), category_dir_name.title())
    )

    comp_dir = comp_json_path.parent
    sim = comp.get("simulation", {})
    raw_states = sim.get("states", {})
    pairs = sim.get("terminalPairs", [])
    rule = sim.get("activationRule") or "none"

    # Identify existing image files in component folder
    available_images: dict[str, str] = {}
    for p in comp_dir.glob("*.webp"):
        available_images[p.name.lower()] = p.name

    # Determine default state image
    default_img_name = None
    for cand in ["preview.webp", "state_off.webp", "off.webp", "original.webp"]:
        if cand.lower() in available_images:
            default_img_name = available_images[cand.lower()]
            break
    if not default_img_name and available_images:
        default_img_name = next(iter(available_images.values()))

    # Determine active / on image
    on_img_name = None
    for cand in ["on.webp", "state_on.webp", "completed.webp", "timing.webp", "closed.webp"]:
        if cand.lower() in available_images:
            on_img_name = available_images[cand.lower()]
            break
    if not on_img_name:
        on_img_name = default_img_name

    # Check raw_states for explicit images
    state_to_file: dict[str, str] = {}
    for sname, sdata in raw_states.items():
        if isinstance(sdata, dict):
            img = sdata.get("image")
            if img and img.lower() in available_images:
                state_to_file[sname] = available_images[img.lower()]
        elif isinstance(sdata, str) and sdata.lower() in available_images:
            state_to_file[sname] = available_images[sdata.lower()]

    # Set up states, default_state, and behavior according to activationRule
    states: dict[str, str] = {}
    image_copies: list[tuple[str, str]] = []  # [(src_filename, dst_filename)]
    behavior: dict[str, Any] = {"controls": []}

    # 1. COIL (contactors, control relays)
    if rule == "coil":
        behavior["kind"] = "coil"
        default_state = "open"
        states["open"] = f"{cid}__open.webp"
        states["closed"] = f"{cid}__closed.webp"

        # Find coil terminals
        coil_found = False
        for tp in pairs:
            if tp.get("simBehavior") == "coil":
                terms = tp.get("terminals", [])
                if len(terms) >= 2:
                    sup = tp.get("supply", {})
                    behavior["coil"] = {
                        "a": terms[0],
                        "b": terms[1],
                        "volts": sup.get("ratedVoltageV", 230),
                        "supply": sup.get("voltage", "ac"),
                    }
                    coil_found = True
                    break
        if not coil_found:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            if "A1" in all_tids and "A2" in all_tids:
                behavior["coil"] = {"a": "A1", "b": "A2", "volts": 230, "supply": "ac"}

        # Build contacts (NO closed in 'closed', NC closed in 'open')
        contacts = []
        for tp in pairs:
            sb = tp.get("simBehavior", "")
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                if sb == "contact_no" or sb == "contact":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["closed"]})
                elif sb == "contact_nc":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["open"]})
        if contacts:
            behavior["contacts"] = contacts

    # 2. TIMERS
    elif rule == "timer" or cat_slug == "timers":
        timer_mode = sim.get("timerMode", "ton")
        is_ton = (timer_mode == "ton")
        behavior["kind"] = "timer_on" if is_ton else "timer_off"
        behavior["default_time_s"] = 3.0
        default_state = "open" if is_ton else "closed"

        states["open"] = f"{cid}__open.webp"
        states["timing"] = f"{cid}__timing.webp"
        states["closed"] = f"{cid}__closed.webp"

        for tp in pairs:
            if tp.get("simBehavior") == "coil":
                terms = tp.get("terminals", [])
                if len(terms) >= 2:
                    behavior["coil"] = {"a": terms[0], "b": terms[1], "volts": 230, "supply": "ac"}
                    break
        if "coil" not in behavior:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            if "A1" in all_tids and "A2" in all_tids:
                behavior["coil"] = {"a": "A1", "b": "A2", "volts": 230, "supply": "ac"}
            elif len(all_tids) >= 2:
                behavior["coil"] = {"a": all_tids[0], "b": all_tids[1], "volts": 230, "supply": "ac"}

        contacts = []
        for tp in pairs:
            sb = tp.get("simBehavior", "")
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                if sb == "contact_no":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["closed"]})
                elif sb == "contact_nc":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["open"]})
        if contacts:
            behavior["contacts"] = contacts

    # 3. LOADS / ACTUATORS / SIGNALING / RESISTIVE
    elif rule in ("load", "resistive", "process_tank") or cat_slug in ("loads", "actuators"):
        behavior["kind"] = "load"
        default_state = "off"
        states["off"] = f"{cid}__off.webp"
        states["on"] = f"{cid}__on.webp"

        terms = None
        for tp in pairs:
            if tp.get("simBehavior", "").startswith("load") or tp.get("currentPath") == "sink":
                terms = tp.get("terminals", [])
                if len(terms) >= 2:
                    break
        if not terms or len(terms) < 2:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            if len(all_tids) >= 2:
                terms = [all_tids[0], all_tids[1]]

        if terms and len(terms) >= 2:
            behavior["load"] = {
                "a": terms[0],
                "b": terms[1],
                "volts": 230,
                "supply": "ac",
            }

    # 4. MOTORS
    elif rule == "motor":
        all_tids = [t.get("id") for t in comp.get("terminals", [])]
        is_3p = any(tid in all_tids for tid in ("U1", "V1", "W1", "U", "V", "W")) or len(all_tids) >= 6
        if is_3p:
            behavior["kind"] = "motor3"
            default_state = "stopped"
            states["stopped"] = f"{cid}__stopped.webp"
            states["run_fwd"] = f"{cid}__run_fwd.webp"
            states["run_rev"] = f"{cid}__run_rev.webp"
        else:
            behavior["kind"] = "load"
            default_state = "off"
            states["off"] = f"{cid}__off.webp"
            states["on"] = f"{cid}__on.webp"
            if len(all_tids) >= 2:
                behavior["load"] = {"a": all_tids[0], "b": all_tids[1], "volts": 230, "supply": "ac"}

    # 5. PROTECTION (MCB, MCCB, MPCB, RCCB, thermal overload, safety)
    elif rule == "protection" or cat_slug == "protection":
        behavior["kind"] = "switchgear"
        behavior["protective"] = True
        default_state = "off"
        states["off"] = f"{cid}__off.webp"
        states["on"] = f"{cid}__on.webp"
        states["tripped"] = f"{cid}__tripped.webp"

        contacts = []
        for tp in pairs:
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                contacts.append({"a": terms[0], "b": terms[1], "closed": ["on"]})
        if not contacts:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            for i in range(0, len(all_tids) - 1, 2):
                contacts.append({"a": all_tids[i], "b": all_tids[i + 1], "closed": ["on"]})
        if contacts:
            behavior["contacts"] = contacts

        behavior["operate"] = {
            "type": "click",
            "map": {"off": "on", "on": "off", "tripped": "off"},
        }
        rc = sim.get("ratedCurrentA")
        if rc is not None:
            try:
                frc = float(rc)
                behavior["controls"] = [{
                    "key": "rated_current_a",
                    "label": "Arus setting",
                    "unit": "A",
                    "min": 1,
                    "max": max(100, int(frc * 1.5)),
                    "default": frc,
                }]
            except (ValueError, TypeError):
                pass
        behavior["thermal"] = {"trip_state": "tripped", "instant_multiple": 7}

    # 6. PUSHBUTTON
    elif rule == "pushbutton":
        behavior["kind"] = "switchgear"
        default_state = "off"
        states["off"] = f"{cid}__off.webp"
        states["on"] = f"{cid}__on.webp"

        contacts = []
        for tp in pairs:
            sb = tp.get("simBehavior", "")
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                if sb == "contact_no":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["on"]})
                elif sb == "contact_nc":
                    contacts.append({"a": terms[0], "b": terms[1], "closed": ["off"]})
        if not contacts:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            if len(all_tids) >= 2:
                contacts.append({"a": all_tids[0], "b": all_tids[1], "closed": ["on"]})
        behavior["contacts"] = contacts

        is_estop = "parada" in raw_id.lower() or "estop" in raw_id.lower() or "emergencia" in raw_id.lower()
        behavior["operate"] = {
            "type": "click" if is_estop else "hold",
            "map": {"off": "on", "on": "off"},
        }

    # 7. SWITCH / SELECTOR
    elif rule in ("switch", "selector", "phase_selector"):
        behavior["kind"] = "switchgear"
        seq = sim.get("stateSequence") or list(raw_states.keys()) or ["off", "on"]
        default_state = sim.get("defaultState", seq[0])

        for s in seq:
            states[s] = f"{cid}__{s}.webp"

        contacts = []
        for tp in pairs:
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                closed_states = [s for s in seq if s != default_state] or ["on"]
                contacts.append({"a": terms[0], "b": terms[1], "closed": closed_states})
        if not contacts:
            all_tids = [t.get("id") for t in comp.get("terminals", [])]
            if len(all_tids) >= 2:
                contacts.append({"a": all_tids[0], "b": all_tids[1], "closed": ["on", "pos1"]})
        behavior["contacts"] = contacts

        op_map = {}
        for i, s in enumerate(seq):
            op_map[s] = seq[(i + 1) % len(seq)]
        behavior["operate"] = {"type": "click", "map": op_map}

    # 8. POWER SUPPLY DC
    elif rule == "power_supply_dc":
        behavior["kind"] = "psu"
        default_state = "off"
        states["off"] = f"{cid}__off.webp"
        states["on"] = f"{cid}__on.webp"

        all_tids = [t.get("id") for t in comp.get("terminals", [])]
        term_l = "L" if "L" in all_tids else (all_tids[0] if all_tids else "L")
        term_n = "N" if "N" in all_tids else (all_tids[1] if len(all_tids) > 1 else "N")
        behavior["input"] = {"a": term_l, "b": term_n, "volts": 230, "supply": "ac"}
        outputs = {}
        if "+" in all_tids:
            outputs["+"] = "DC+"
        if "-" in all_tids:
            outputs["-"] = "DC-"
        if outputs:
            behavior["outputs"] = outputs

    # 9. METERS
    elif rule == "meter" or cat_slug == "meters":
        behavior["kind"] = "meter"
        default_state = "on"
        states["on"] = f"{cid}__on.webp"
        all_tids = [t.get("id") for t in comp.get("terminals", [])]
        if len(all_tids) >= 2:
            behavior["meter"] = {"a": all_tids[0], "b": all_tids[1], "screen": [0.1, 0.1, 0.8, 0.4], "show": ["V"]}

    # 10. PLC
    elif rule == "plc" or cat_slug == "automation":
        behavior["kind"] = "plc"
        default_state = "off"
        states["off"] = f"{cid}__off.webp"
        states["run"] = f"{cid}__run.webp"
        all_tids = [t.get("id") for t in comp.get("terminals", [])]
        if len(all_tids) >= 2:
            behavior["input"] = {"a": all_tids[0], "b": all_tids[1], "volts": 230, "supply": "ac"}

    # 11. PASSIVE / DISTRIBUTION / DIN RAIL / ENCLOSURE / FALLBACK
    else:
        contacts = []
        for tp in pairs:
            terms = tp.get("terminals", [])
            if len(terms) >= 2:
                contacts.append({"a": terms[0], "b": terms[1], "closed": ["on"]})
        if contacts:
            behavior["kind"] = "switchgear"
            default_state = "on"
            states["on"] = f"{cid}__on.webp"
            behavior["contacts"] = contacts
        else:
            behavior["kind"] = "passive" if comp.get("terminals") else "structural"
            default_state = "on"
            states["on"] = f"{cid}__on.webp"

    # Always ensure default_state is in states
    if default_state not in states:
        default_state = next(iter(states.keys()))

    # Build exact image copies list for EVERY state
    for s in states:
        dst = f"{cid}__{s}.webp"
        src = state_to_file.get(s)
        if not src:
            if s in ("on", "closed", "run_fwd", "run_rev", "timing"):
                src = on_img_name or default_img_name
            else:
                src = default_img_name
        if src:
            image_copies.append((src, dst))

    # Also always ensure preview image {cid}__preview.webp exists
    if default_img_name:
        image_copies.append((default_img_name, f"{cid}__preview.webp"))

    device: dict[str, Any] = {
        "format": "starter-device/2",
        "id": cid,
        "name": name,
        "name_id": name,
        "designator": comp.get("tagPrefix", "X"),
        "category": cat_slug,
        "category_label": cat_label,
        "size_mm": size_mm(comp),
        "ratings": extract_ratings(comp),
        "terminals": map_terminals(comp),
        "states": states,
        "default_state": default_state,
        "behavior": behavior,
        "sounds": {},
        "loop_sounds": {},
        "art": "device",
        "raster": True,
        "source": "extracted-assets",
    }

    device["_meta"] = {
        "comp_dir": str(comp_dir),
        "image_copies": image_copies,
    }

    return device


def find_all_components(root: Path):
    """Yield (comp_json_path, top_category_dir_name) for every component.json."""
    for cat_dir in sorted(root.iterdir()):
        if not cat_dir.is_dir():
            continue
        cat_name = cat_dir.name
        for comp_json in sorted(cat_dir.rglob("component.json")):
            yield comp_json, cat_name


def copy_images(device: dict, dry_run: bool) -> int:
    """Copy state + preview images. Returns count of files copied."""
    meta = device.get("_meta", {})
    comp_dir = Path(meta.get("comp_dir", ""))
    copies: list[tuple[str, str]] = meta.get("image_copies", [])
    count = 0

    for src_name, dst_name in copies:
        src = comp_dir / src_name
        dst = DEVICES_DIR / dst_name
        if src.exists():
            if not dry_run:
                shutil.copy2(src, dst)
            count += 1
        else:
            print(f"  WARNING: missing image {src}", file=sys.stderr)

    return count


def main():
    dry_run = "--dry-run" in sys.argv

    if not EXTRACTED.is_dir():
        print(f"ERROR: extracted assets directory not found: {EXTRACTED}", file=sys.stderr)
        sys.exit(1)

    if not dry_run:
        DEVICES_DIR.mkdir(parents=True, exist_ok=True)

    # ---- Load existing index.json (starter devices) ----
    starter_devices: list[dict] = []
    if INDEX_JSON.exists():
        try:
            with open(INDEX_JSON, "r", encoding="utf-8") as f:
                existing = json.load(f)
            starter_devices = [
                d for d in existing
                if d.get("source") != "extracted-assets"
            ]
        except (json.JSONDecodeError, OSError) as exc:
            print(f"WARNING: could not read existing index.json: {exc}", file=sys.stderr)

    print(f"Existing starter devices & symbols: {len(starter_devices)}")

    # ---- Convert all extracted components ----
    converted: list[dict] = []
    category_counts: dict[str, int] = {}
    errors = 0
    total_images = 0

    for comp_path, cat_name in find_all_components(EXTRACTED):
        device = convert_component(comp_path, cat_name)
        if device is None:
            errors += 1
            continue

        imgs = copy_images(device, dry_run)
        total_images += imgs

        device.pop("_meta", None)
        converted.append(device)

        label = CATEGORY_MAP.get(cat_name, (cat_name, cat_name))[1]
        category_counts[label] = category_counts.get(label, 0) + 1

    # ---- Merge & write ----
    combined = starter_devices + converted

    if not dry_run:
        with open(INDEX_JSON, "w", encoding="utf-8") as f:
            json.dump(combined, f, ensure_ascii=False)
        print(f"\nWrote {INDEX_JSON}  ({len(combined)} devices total)")
    else:
        print(f"\n[DRY RUN] Would write {len(combined)} devices to {INDEX_JSON}")

    # ---- Summary ----
    print(f"\n{'='*50}")
    print(f"  Converted: {len(converted)} devices")
    print(f"  Images:    {total_images} files {'(would be copied)' if dry_run else 'copied'}")
    print(f"  Errors:    {errors} components skipped")
    print(f"{'='*50}")
    print(f"\nPer category:")
    for label in sorted(category_counts):
        print(f"  {label:35s} {category_counts[label]:4d}")
    print()


if __name__ == "__main__":
    main()
