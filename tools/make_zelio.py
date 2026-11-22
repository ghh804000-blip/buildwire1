"""Zelio Logic smart relays for the catalog, from the background-removed photos in tools/sources.

The photos were supplied by the user (licence is the user's call). For each model this finds the screw terminals in
the top and bottom rows, names them in the order printed on the housing, finds the LCD and the six keys, writes the
device pictures and returns the catalog entries. upgrade_devices.py adds them on every run.

Run alone to write a check image per model into tools/sources/zelio_check/:  python tools/make_zelio.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

TOOLS = Path(__file__).resolve().parent
SOURCES = TOOLS / "sources"
DEVICES = TOOLS.parent / "assets" / "devices"

SR3_TOP = ["I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "IA", "IB", "IC", "ID", "IE", "IF", "IG"]
SR3_BOTTOM = [t for q in ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7"] for t in (f"{q}.1", f"{q}.2")] + ["C", "Q8", "Q9", "QA"]
SR3_OUTPUTS = {**{f"Q{n}": [f"Q{n}.1", f"Q{n}.2"] for n in range(1, 8)}, "Q8": ["C", "Q8"], "Q9": ["C", "Q9"], "QA": ["C", "QA"]}


def pairs(names):
    return [t for q in names for t in (f"{q}.1", f"{q}.2")]


# id, photo, name, supply terminals, volts, ac/dc, top labels after the supply (None = a screw that is skipped),
# bottom labels, outputs {Q: [a, b]}, height in mm (width follows the photo)
MODELS = [
    dict(id="zelio_sr3b261fu", photo="zelio_sr3b261fu_photo.png", name="Schneider Zelio Logic SR3B261FU",
         supply=("L", "N"), volts=230, kind="ac", top=SR3_TOP, bottom=SR3_BOTTOM, outputs=SR3_OUTPUTS),
    dict(id="zelio_sr3b261b", photo="zelio_sr3b261b_photo.png", name="Schneider Zelio Logic SR3B261B (24 V AC)",
         supply=("L", "N"), volts=24, kind="ac", top=SR3_TOP, bottom=SR3_BOTTOM, outputs=SR3_OUTPUTS),
    dict(id="zelio_sr3b261bd", photo="zelio_sr3b261bd_photo.png", name="Schneider Zelio Logic SR3B261BD (24 V DC)",
         supply=("+", "-"), volts=24, kind="dc", top=SR3_TOP, bottom=SR3_BOTTOM, outputs=SR3_OUTPUTS),
    dict(id="zelio_sr2b201fu", photo="zelio_sr2b201fu_photo.png", name="Schneider Zelio Logic SR2B201FU",
         supply=("L", "N"), volts=230, kind="ac", top=SR3_TOP[:12],
         bottom=pairs([f"Q{n}" for n in range(1, 9)]), outputs={f"Q{n}": [f"Q{n}.1", f"Q{n}.2"] for n in range(1, 9)}),
    dict(id="zelio_sr2b121fu", photo="zelio_sr2b121fu_photo.png", name="Schneider Zelio Logic SR2B121FU",
         supply=("L", "N"), volts=230, kind="ac", top=SR3_TOP[:8],
         bottom=pairs([f"Q{n}" for n in range(1, 5)]), outputs={f"Q{n}": [f"Q{n}.1", f"Q{n}.2"] for n in range(1, 5)}),
    # The BD has a sensor-supply "+" before I1; it is the same point as the supply "+", so it is not offered.
    dict(id="zelio_sr2b121bd", photo="zelio_sr2b121bd_photo.png", name="Schneider Zelio Logic SR2B121BD (24 V DC)",
         supply=("+", "-"), volts=24, kind="dc", top=[None, "I1", "I2", "I3", "I4", "I5", "I6", "I7", "IB", "IC"],
         bottom=pairs([f"Q{n}" for n in range(1, 5)]), outputs={f"Q{n}": [f"Q{n}.1", f"Q{n}.2"] for n in range(1, 5)}),
]

HEIGHT_MM = 90.0


def screws(img, y0, y1):
    """Centers (x, y) of the screw heads between rows y0 and y1: round, metallic grey, with a dark rim. The blind
    holes at the end of the top row are flat black and are left out."""
    a = np.asarray(img.convert("RGB")).astype(int)
    band = a[y0:y1]
    lum = band.mean(axis=2)
    alpha = np.asarray(img)[y0:y1, :, 3] if img.mode == "RGBA" else np.full(lum.shape, 255)
    # Screw heads are clearly darker than the white housing.
    dark = (lum < 150) & (alpha > 200)
    cols = dark.sum(axis=0)
    found = []
    x = 0
    w = len(cols)
    while x < w:
        if cols[x] >= 4:
            s = x
            while x < w and cols[x] >= 4:
                x += 1
            if x - s >= 8:
                ys = np.where(dark[:, s:x].any(axis=1))[0]
                cy = y0 + (ys.min() + ys.max()) / 2
                region = lum[ys.min():ys.max() + 1, s:x]
                # Holes are near black everywhere; screws have light threads inside.
                bright_inside = (region > 110).mean()
                found.append(((s + x) / 2, cy, x - s, bright_inside))
        x += 1
    return found


def keep_screws(found):
    return [(x, y) for x, y, width, bright in found if bright > 0.08]


def lcd_rect(img):
    """The LCD: the largest near-black area in the middle band."""
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w, _ = a.shape
    lum = a.mean(axis=2)
    dark = lum < 70
    ys, xs = np.where(dark[int(h * 0.25):int(h * 0.7), :int(w * 0.6)])
    ys = ys + int(h * 0.25)
    # Keep the dense block: rows and columns where most pixels are dark.
    # Rows of the LCD are dark over more than a quarter of the width; the keys below are narrower. Keep the
    # longest unbroken run so the key row never joins the screen.
    dense = [y for y in range(ys.min(), ys.max() + 1) if dark[y, :int(w * 0.6)].sum() > w * 0.28]
    runs, run = [], [dense[0]]
    for y in dense[1:]:
        if y == run[-1] + 1:
            run.append(y)
        else:
            runs.append(run)
            run = [y]
    runs.append(run)
    rows = max(runs, key=len)
    cols = [x for x in range(xs.min(), xs.max() + 1) if dark[rows[0]:rows[-1] + 1, x].mean() > 0.6]
    return cols[0], rows[0], cols[-1], rows[-1]


def keys(img, lcd):
    """Six round keys under the LCD, left to right: left, down, up, right, Menu/OK, then the white key."""
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w, _ = a.shape
    x0, y0, x1, y1 = lcd
    top = y1 + int(h * 0.02)
    bottom = min(h, y1 + int(h * 0.2))
    region = a[top:bottom, :int(w * 0.75)]
    lum0 = region.mean(axis=2)
    teal0 = (region[:, :, 1] - region[:, :, 0] > 25) & (lum0 > 60)
    # The key row: the rows with the most key-coloured pixels.
    count = ((lum0 < 120) | teal0).sum(axis=1)
    peak = int(np.argmax(count))
    half = max(8, int(h * 0.035))
    top, bottom = top + max(0, peak - half), top + peak + half
    band = a[top:bottom, :int(w * 0.75)]
    lum = band.mean(axis=2)
    # Dark grey/blue keys and the green/teal Menu key (the white key is placed by the spacing below).
    mask = (lum < 120) | ((band[:, :, 1] - band[:, :, 0] > 25) & (lum > 60))
    cols = mask.sum(axis=0)
    blobs = []
    x = 0
    while x < len(cols):
        if cols[x] >= 6:
            s = x
            while x < len(cols) and cols[x] >= 6:
                x += 1
            if x - s >= 12:
                ys = np.where(mask[:, s:x].any(axis=1))[0]
                blobs.append((s, top + ys.min(), x, top + ys.max()))
        x += 1
    blobs = [b for b in blobs if (b[2] - b[0]) < w * 0.08][:5]
    # The white key: same row, right of Menu, light with a rim; find it by the spacing.
    if len(blobs) == 5:
        step = (blobs[4][0] - blobs[0][0]) / 4
        s = blobs[4][0] + step * 1.35
        blobs.append((s, blobs[4][1], s + (blobs[4][2] - blobs[4][0]), blobs[4][3]))
    return blobs


def screw_row(img, y0, y1):
    """The rows holding the screw heads: a band around the row with the most dark pixels."""
    a = np.asarray(img.convert("RGB")).astype(int)
    alpha = np.asarray(img)[:, :, 3]
    lum = a.mean(axis=2)
    dark = ((lum < 150) & (alpha > 200)).sum(axis=1)
    peak = y0 + int(np.argmax(dark[y0:y1]))
    half = max(6, int(img.size[1] * 0.022))
    return peak - half, peak + half


def measure(model):
    img = Image.open(SOURCES / model["photo"]).convert("RGBA")
    w, h = img.size
    top = keep_screws(screws(img, *screw_row(img, int(h * 0.03), int(h * 0.22))))
    bottom = keep_screws(screws(img, *screw_row(img, int(h * 0.84), h - 2)))
    lcd = lcd_rect(img)
    ks = keys(img, lcd)
    return img, top, bottom, lcd, ks


def check(model):
    img, top, bottom, lcd, ks = measure(model)
    labels_top = [model["supply"][0], model["supply"][1]] + model["top"]
    out = img.copy()
    d = ImageDraw.Draw(out)
    for (x, y), name in zip(top, labels_top):
        d.ellipse((x - 6, y - 6, x + 6, y + 6), outline="red", width=2)
        d.text((x - 6, y + 10), str(name), fill="red")
    for (x, y), name in zip(bottom, model["bottom"]):
        d.ellipse((x - 6, y - 6, x + 6, y + 6), outline="blue", width=2)
        d.text((x - 8, y - 22), name, fill="blue")
    d.rectangle(lcd, outline="lime", width=3)
    for b, name in zip(ks, ["L", "D", "U", "R", "OK", "ESC"]):
        d.rectangle(b, outline="magenta", width=2)
        d.text((b[0], b[1] - 12), name, fill="magenta")
    print(f'{model["id"]}: top {len(top)}/{len(labels_top)}  bottom {len(bottom)}/{len(model["bottom"])}  keys {len(ks)}  lcd {lcd}')
    dst = SOURCES / "zelio_check"
    dst.mkdir(exist_ok=True)
    bg = Image.new("RGBA", out.size, (40, 46, 52, 255))
    bg.alpha_composite(out)
    bg.convert("RGB").save(dst / f'{model["id"]}.png')


def norm_rect(box, w, h):
    x0, y0, x1, y1 = box
    return [round(x0 / w, 4), round(y0 / h, 4), round((x1 - x0) / w, 4), round((y1 - y0) / h, 4)]


def device(model):
    """The catalog entry for one model, writing its pictures into assets/devices."""
    img, top, bottom, lcd, ks = measure(model)
    w, h = img.size
    a, b = model["supply"]
    labels_top = [a, b] + model["top"]
    if len(top) < len(labels_top) or len(bottom) < len(model["bottom"]):
        raise SystemExit(f'{model["id"]}: found {len(top)} top / {len(bottom)} bottom screws, need {len(labels_top)} / {len(model["bottom"])}')
    terminals = []
    for (x, y), name in zip(top, labels_top):
        if name is None:
            continue
        cls = "power" if name in (a, b) else "control"
        terminals.append({"id": name, "x": round(x / w, 4), "y": round(y / h, 4), "side": "top", "class": cls})
    for (x, y), name in zip(bottom, model["bottom"]):
        terminals.append({"id": name, "x": round(x / w, 4), "y": round(y / h, 4), "side": "bottom", "class": "control"})
    pic = img.copy()
    pic.thumbnail((900, 900))
    for state in ("off", "run", "preview"):
        pic.save(DEVICES / f'{model["id"]}__{state}.webp', quality=90, method=6)
    names = ["left", "down", "up", "right", "ok", "esc"]
    inputs = [t for t in model["top"] if t]
    return {
        "format": "starter-device/2", "id": model["id"], "name": model["name"], "name_id": model["name"],
        "designator": "A", "category": "automation", "category_label": "PLC dan HMI",
        "size_mm": {"width": round(HEIGHT_MM * w / h, 1), "height": HEIGHT_MM},
        "ratings": {"voltage_v": model["volts"], "inputs": len(inputs), "outputs": len(model["outputs"])},
        "states": {"off": f'{model["id"]}__off.webp', "run": f'{model["id"]}__run.webp'},
        "default_state": "off",
        "terminals": terminals,
        "behavior": {
            "controls": [], "kind": "plc",
            "input": {"a": a, "b": b, "volts": model["volts"], "supply": model["kind"]},
            # Zelio addressing: inputs I1..IG, outputs Q1..QA, keys Z1..Z4, counters C, timers T, relays M.
            "plc": {"family": "zelio", "inputs": inputs, "outputs": model["outputs"]},
            "panel": {
                "lcd": norm_rect(lcd, w, h), "bg": "#A9C27A", "fg": "#18240F", "off": "#3B4236",
                "keys": {name: norm_rect(k, w, h) for name, k in zip(names, ks)},
            },
        },
        "sounds": {}, "loop_sounds": {}, "art": "device", "raster": True, "source": "user-photo", "group": "PLC",
        "note": ("Terminal + dan - untuk catu 24 V DC; input aktif bila diberi +24 V." if model["kind"] == "dc"
                 else f'Catu L-N {model["volts"]} V AC; input aktif bila diberi L.'),
    }


def zelio_devices():
    return [device(m) for m in MODELS]


if __name__ == "__main__":
    for m in MODELS:
        check(m)
