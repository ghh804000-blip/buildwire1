"""Package rendered logo PNGs from brand/final/png into the app's icon files.

usage: python -I make_logo.py
"""
import shutil
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
PNG = HERE / "final" / "png"
ICON_SIZES = [256, 64, 48, 32, 24, 16]


def main():
    images = [(size, (PNG / f"logo-{size}.png").read_bytes()) for size in ICON_SIZES]
    offset = 6 + 16 * len(images)
    out = struct.pack("<HHH", 0, 1, len(images))
    for size, data in images:
        out += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    icon = APP / "windows" / "runner" / "resources" / "app_icon.ico"
    icon.write_bytes(out + b"".join(data for _size, data in images))
    shutil.copy(PNG / "logo-64.png", APP / "web" / "favicon.png")
    for name, size in (("Icon-192", 192), ("Icon-512", 512), ("Icon-maskable-192", 192), ("Icon-maskable-512", 512)):
        shutil.copy(PNG / f"logo-{size}.png", APP / "web" / "icons" / f"{name}.png")
    brand = APP / "assets" / "brand"
    brand.mkdir(parents=True, exist_ok=True)
    shutil.copy(PNG / "logo-128.png", brand / "logo.png")
    print("icon bytes", icon.stat().st_size)


if __name__ == "__main__":
    main()
