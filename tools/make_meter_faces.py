"""Builds needle-free dial faces for analog meters so the app can draw a live needle.

Writes `<id>__face.webp` next to the device art; the original state images are left untouched.
Coordinates are fractions of the image width (x) and width-scaled height (y, same scale as x).
"""
from pathlib import Path

import numpy as np
from PIL import Image

DEVICES = Path(__file__).resolve().parent.parent / "assets" / "devices"

# id: (needle tip, needle base, half width) in fractions of image width, measured on the original photo.
NEEDLES = {
    "oumik_m72_voltmeter": ((484 / 900, 166 / 900), (590 / 900, 565 / 900), 0.024),
    "oumik_frequency_meter": ((496 / 900, 272 / 900), (523 / 900, 588 / 900), 0.017),
}


def erase_needle(image: Image.Image, tip, base, half_width=0.017, dark=8) -> Image.Image:
    rgba = np.array(image.convert("RGBA")).astype(np.float32)
    h, w = rgba.shape[:2]
    p0 = np.array([tip[0] * w, tip[1] * w])
    p1 = np.array([base[0] * w, base[1] * w])
    axis = p1 - p0
    length = np.linalg.norm(axis)
    axis /= length
    normal = np.array([-axis[1], axis[0]])
    ys, xs = np.mgrid[0:h, 0:w]
    rel = np.stack([xs - p0[0], ys - p0[1]], axis=-1)
    along = rel @ axis
    across = rel @ normal
    hw = half_width * w
    band = (along > -hw) & (along < length) & (np.abs(across) < hw)
    luma = rgba[..., :3] @ np.array([0.299, 0.587, 0.114])
    # Fill each band pixel from the dial on both sides of the needle, blended by position across it.
    foot = p0[None, :] + np.outer(along[band], axis)
    sides = []
    for side in (-1, 1):
        q = foot + normal * side * hw * 1.3
        qx = np.clip(np.round(q[:, 0]).astype(int), 0, w - 1)
        qy = np.clip(np.round(q[:, 1]).astype(int), 0, h - 1)
        sides.append(rgba[qy, qx])
    t = ((across[band] / hw) + 1) / 2
    fill = sides[0] * (1 - t)[:, None] + sides[1] * t[:, None]
    fill_luma = fill[:, :3] @ np.array([0.299, 0.587, 0.114])
    # Only replace what is darker than the dial around it: the needle and its shadow.
    darker = luma[band] < fill_luma - dark
    out = rgba.copy()
    idx = np.nonzero(band)
    out[idx[0][darker], idx[1][darker]] = fill[darker]
    return Image.fromarray(out.clip(0, 255).astype(np.uint8))


def main():
    for device, (tip, base, half_width) in NEEDLES.items():
        source = Image.open(DEVICES / f"{device}__on.webp")
        face = erase_needle(source, tip, base, half_width)
        face.save(DEVICES / f"{device}__face.webp", quality=92)
        print("wrote", f"{device}__face.webp")


if __name__ == "__main__":
    main()
