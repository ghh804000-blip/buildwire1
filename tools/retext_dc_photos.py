"""Rewrites the printed ratings on the 24 V DC variants' photos, which are copies of the AC parts' photos.

The DC variants made by upgrade_devices.py (DC_VARIANTS) reuse the original pictures, so a 24 V DC relay still said
"230V AC" on its face. This erases each printed line (filling it from the plastic on either side, so the shading
stays) and prints the DC text in a matching size and color.

Always starts from the original part's picture, so it can be run again safely. Run after upgrade_devices.py:
python tools/retext_dc_photos.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

DEVICES = Path(__file__).resolve().parent.parent / "assets" / "devices"
FONTS = [Path("C:/Windows/Fonts/arial.ttf"), Path("C:/Windows/Fonts/segoeui.ttf"), Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]

# (source id, DC id, states, [(erase box x0, y0, x1, y1 in source pixels, new text)])
JOBS = [
    ("schneider_rxm4ab2p7", "schneider_rxm4ab2bd", ["open", "closed", "preview"], [
        ((266, 910, 432, 936), "RXM4AB2BD"),
        ((266, 946, 380, 972), "24V DC"),
    ]),
    ("logo_230rce", "logo_24rce", ["off", "run", "preview"], [
        ((58, 18, 88, 38), "L+"),
        ((136, 18, 156, 38), "M"),
        ((515, 143, 872, 168), "DC 24V INPUT8xDC", "flat"),
        ((737, 381, 820, 403), "24RCE"),
    ]),
]


def font_for(cap_height):
    path = next((f for f in FONTS if f.exists()), None)
    size = max(6, int(cap_height * 1.4))
    while path is not None:
        font = ImageFont.truetype(str(path), size)
        box = font.getbbox("X")
        if box[3] - box[1] <= cap_height or size <= 6:
            return font
        size -= 1
    return ImageFont.load_default()


def erase(img, box, flat=False):
    """Fills the box row by row, blending the pixels just left and right of it (or from the left only when the
    surface is flat and the right edge runs into a border)."""
    x0, y0, x1, y1 = box
    px = img.load()
    for y in range(y0, y1):
        left = px[x0 - 2, y]
        right = left if flat else px[x1 + 2, y]
        for x in range(x0, x1):
            t = (x - x0) / max(1, x1 - x0)
            px[x, y] = tuple(round(left[c] + (right[c] - left[c]) * t) for c in range(4))


def text_color(img, box):
    """The brightest color in the old text, so the new text matches it."""
    region = img.crop(box).convert("RGBA")
    pixels = sorted(region.getdata(), key=lambda p: p[0] + p[1] + p[2], reverse=True)
    top = pixels[: max(1, len(pixels) // 25)]
    return tuple(round(sum(p[c] for p in top) / len(top)) for c in range(4))


def retext(source_id, target_id, state, lines):
    src = DEVICES / f"{source_id}__{state}.webp"
    if not src.exists():
        return False
    img = Image.open(src).convert("RGBA")
    draw = ImageDraw.Draw(img)
    for box, text, *mode in lines:
        color = text_color(img, box)
        erase(img, box, flat="flat" in mode)
        x0, y0, x1, y1 = box
        cap = (y1 - y0) - 6
        font = font_for(cap)
        top = font.getbbox("X")[1]
        draw.text((x0 + 2, y0 + 3 - top), text, font=font, fill=color)
    img.save(DEVICES / f"{target_id}__{state}.webp", lossless=False, quality=92, method=6)
    return True


def main():
    done = 0
    for source_id, target_id, states, lines in JOBS:
        for state in states:
            done += retext(source_id, target_id, state, lines)
    print(f"rewrote {done} pictures")


if __name__ == "__main__":
    main()
