"""Copy generated devices into the app and convert catalog symbols from QElectroTech .elmt to SVG.

usage: python -I sync_assets.py
Writes assets/devices/<id>__<state>.svg, assets/symbols/<id>.svg, assets/sounds, and assets/devices/index.json.
"""
import json
import math
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

APP = Path(__file__).resolve().parent.parent
PROJECT = APP.parent
STARTER = PROJECT / "starter-assets"
CATALOG = PROJECT / "licensed-assets" / "catalog" / "catalog.json"
SCALE = 0.75  # mm per QElectroTech unit
MAX_SYMBOL_MM = 60  # longest side of a symbol on the canvas

CATEGORY_SYMBOLS = {
    "relays_contactors": "Relay dan kontaktor", "protection": "Proteksi", "control_signaling": "Kontrol dan sinyal",
    "motors_loads": "Motor dan beban", "sensors_instruments": "Sensor dan instrumen", "terminals": "Terminal",
    "transformers_supplies": "Trafo dan catu daya", "converters": "Konverter", "sources": "Sumber",
    "home_installation": "Instalasi rumah", "electronics": "Elektronika", "connectors": "Konektor",
}


def style_of(node):
    style = dict(part.split(":", 1) for part in (node.get("style") or "").split(";") if ":" in part)
    width = {"none": 0, "hight": 2.0, "eleve": 2.0, "thin": 0.5, "normal": 1.0}.get(style.get("line-weight", "normal"), 1.0)
    fill = style.get("filling", "none")
    color = style.get("color", "black")
    safe = lambda c: c if re.fullmatch(r"[a-z]+", c) else "black"
    return f'fill="{"none" if fill == "none" else safe(fill)}" stroke="{safe(color)}" stroke-width="{width}"'


def number(node, key, default=0.0):
    try:
        return float(node.get(key, default))
    except (TypeError, ValueError):
        return default


def convert(path):
    root = ET.parse(path).getroot()
    width, height = number(root, "width", 20), number(root, "height", 20)
    hx, hy = number(root, "hotspot_x"), number(root, "hotspot_y")
    desc = root.find("description")
    parts = []
    terminals = []
    if desc is None:
        return None
    for node in desc:
        tag = node.tag
        s = style_of(node)
        if tag == "line":
            parts.append(f'<line x1="{number(node, "x1")}" y1="{number(node, "y1")}" x2="{number(node, "x2")}" y2="{number(node, "y2")}" {s}/>')
        elif tag == "rect":
            parts.append(f'<rect x="{number(node, "x")}" y="{number(node, "y")}" width="{number(node, "width")}" height="{number(node, "height")}" {s}/>')
        elif tag == "circle":
            d = number(node, "diameter")
            parts.append(f'<circle cx="{number(node, "x") + d / 2}" cy="{number(node, "y") + d / 2}" r="{d / 2}" {s}/>')
        elif tag == "ellipse":
            w, h = number(node, "width"), number(node, "height")
            parts.append(f'<ellipse cx="{number(node, "x") + w / 2}" cy="{number(node, "y") + h / 2}" rx="{w / 2}" ry="{h / 2}" {s}/>')
        elif tag == "polygon":
            points = []
            i = 1
            while node.get(f"x{i}") is not None:
                points.append(f'{number(node, f"x{i}")},{number(node, f"y{i}")}')
                i += 1
            element = "polyline" if node.get("closed") == "false" else "polygon"
            parts.append(f'<{element} points="{" ".join(points)}" {s}/>')
        elif tag == "arc":
            x, y, w, h = number(node, "x"), number(node, "y"), number(node, "width"), number(node, "height")
            start, sweep = math.radians(number(node, "start")), math.radians(number(node, "angle"))
            cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
            x1, y1 = cx + rx * math.cos(start), cy - ry * math.sin(start)
            x2, y2 = cx + rx * math.cos(start + sweep), cy - ry * math.sin(start + sweep)
            large = 1 if abs(sweep) > math.pi else 0
            flag = 0 if sweep > 0 else 1
            parts.append(f'<path d="M{x1:.2f} {y1:.2f}A{rx} {ry} 0 {large} {flag} {x2:.2f} {y2:.2f}" {s}/>')
        elif tag == "text":
            value = escape(node.get("text") or "")
            if value:
                parts.append(f'<text x="{number(node, "x")}" y="{number(node, "y")}" font-family="Inter" font-size="{number(node, "size", 7)}" fill="black">{value}</text>')
        elif tag == "terminal":
            terminals.append((number(node, "x"), number(node, "y"), node.get("orientation", "n")))
    if not parts or not terminals:
        return None
    left, top = -hx, -hy
    pad = 8
    view = (left - pad, top - pad, width + pad * 2, height + pad * 2)
    body = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view[0]} {view[1]} {view[2]} {view[3]}" width="{view[2]}" height="{view[3]}">'
        f'<rect x="{view[0]}" y="{view[1]}" width="{view[2]}" height="{view[3]}" rx="3" fill="#ffffff" stroke="#c4cad0" stroke-width="0.6"/>'
        + "".join(parts) + "</svg>\n"
    )
    side = {"n": "top", "s": "bottom", "e": "right", "w": "left"}
    return {
        "svg": body, "view": view,
        "terminals": [
            {"id": f"T{i + 1}", "x": round((x - view[0]) / view[2], 4), "y": round((y - view[1]) / view[3], 4), "side": side.get(o, "top"), "class": "control"}
            for i, (x, y, o) in enumerate(terminals)
        ],
    }


def main():
    missing = [p for p in (STARTER / "devices", STARTER / "sounds", CATALOG) if not p.exists()]
    if missing:
        raise SystemExit("Missing external asset sources (no files deleted):\n" + "\n".join(f"  - {p}" for p in missing))
    devices_dir, symbols_dir, sounds_dir = APP / "assets/devices", APP / "assets/symbols", APP / "assets/sounds"
    for folder in (devices_dir, symbols_dir, sounds_dir):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    index = []
    for meta in sorted((STARTER / "devices").glob("*/device.json")):
        definition = json.loads(meta.read_text(encoding="utf-8"))
        for state, file in definition["states"].items():
            shutil.copy(meta.parent / file, devices_dir / f'{definition["id"]}__{state}.svg')
        definition["art"] = "device"
        index.append(definition)
    device_count = len(index)
    for wav in (STARTER / "sounds").glob("*.wav"):
        shutil.copy(wav, sounds_dir)

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["devices"]
    converted = failed = 0
    for entry in catalog:
        if entry["level"] != "symbol_only":
            continue
        result = convert(PROJECT / entry["path"])
        if result is None:
            failed += 1
            continue
        (symbols_dir / f'{entry["id"]}.svg').write_text(result["svg"], encoding="utf-8")
        view = result["view"]
        # Large drawings would otherwise dwarf every device on the canvas.
        scale = min(SCALE, MAX_SYMBOL_MM / max(view[2], view[3]))
        index.append({
            "id": entry["id"], "name": entry["name"], "name_id": entry["name"], "designator": "Y",
            "category": f'symbol:{entry["category"]}', "category_label": CATEGORY_SYMBOLS.get(entry["category"], entry["category"]),
            "size_mm": {"width": round(view[2] * scale, 2), "height": round(view[3] * scale, 2)}, "ratings": {},
            "terminals": result["terminals"], "states": {"on": "on"}, "default_state": "on", "behavior": {"kind": "symbol"}, "sounds": {},
            "art": "symbol", "license": "CC-BY 3.0", "source": "QElectroTech elements",
        })
        converted += 1
    (devices_dir / "index.json").write_text(json.dumps(index, ensure_ascii=False), encoding="utf-8")
    print(f"devices {device_count}, symbols {converted}, unconverted {failed}, total {len(index)}")


if __name__ == "__main__":
    main()
