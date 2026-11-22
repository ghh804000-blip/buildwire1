"""Makes colour variants of the BuildWire logo by swapping its pink plate for another colour.

The engraving itself is kept as drawn. Writes brand/variants/<name>.png (1024 px) and a comparison sheet; the
original logo files are not touched.

usage: python brand/recolor_logo.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "final" / "logo-sumber.png"
OUT = HERE / "variants"

# name: plate colour, corner radius as a fraction of the size.
VARIANTS = {
    "pelat-kuning": ((0xF2, 0xA9, 0x00), 0.14),
    "pelat-baja": ((0x3A, 0x40, 0x46), 0.14),
    "pelat-oranye": ((0xE0, 0x6A, 0x10), 0.14),
}


def pinkness(rgb: np.ndarray) -> np.ndarray:
    """0..1, how much each pixel belongs to the pink plate (hue near 340°, saturated)."""
    r, g, b = (rgb[..., i] / 255.0 for i in range(3))
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    pinkish = (r > g + 0.15) & (r > b)
    return np.clip((sat - 0.2) / 0.35, 0, 1) * pinkish


def main():
    src = np.asarray(Image.open(SOURCE).convert("RGB")).astype(np.float32)
    size = src.shape[0]
    plate_weight = pinkness(src)
    # The corners outside the original rounded plate are black: treat them as plate too.
    corner = Image.new("L", (size, size), 0)
    ImageDraw.Draw(corner).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.17), fill=255)
    outside = np.asarray(corner) < 128
    plate_weight = np.where(outside, 1.0, plate_weight)[..., None]
    OUT.mkdir(exist_ok=True)
    tiles = []
    for name, (colour, radius) in VARIANTS.items():
        art = src * (1 - plate_weight) + np.array(colour, np.float32) * plate_weight
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius), fill=255)
        image = Image.fromarray(art.clip(0, 255).astype(np.uint8)).convert("RGBA")
        image.putalpha(mask)
        image = image.resize((1024, 1024), Image.LANCZOS)
        image.save(OUT / f"{name}.png")
        tiles.append(image)
    original = Image.open(SOURCE).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    sheet = Image.new("RGB", (4 * 300 + 50, 340), (236, 238, 239))
    for i, tile in enumerate([original, *tiles]):
        t = tile.resize((280, 280), Image.LANCZOS)
        sheet.paste(t, (10 + i * 310, 30), t)
    sheet.save(OUT / "perbandingan.png")
    print("wrote", ", ".join(VARIANTS), "and perbandingan.png")


if __name__ == "__main__":
    main()
