"""Removes the plain white background from a product photo: flood fill from the borders over near-white pixels,
then crop to the device and feather the edge. Usage: python cut_sr3.py src out_png preview_png"""
import sys
from collections import deque

import numpy as np
from PIL import Image, ImageFilter

src, out, preview = sys.argv[1:4]
img = Image.open(src).convert('RGB')
a = np.asarray(img).astype(np.int16)
h, w, _ = a.shape
# Background: very bright and almost colorless.
bright = (a.min(axis=2) >= 246) & ((a.max(axis=2) - a.min(axis=2)) <= 6)
bg = np.zeros((h, w), bool)
q = deque()
for x in range(w):
    for y in (0, h - 1):
        if bright[y, x] and not bg[y, x]:
            bg[y, x] = True
            q.append((y, x))
for y in range(h):
    for x in (0, w - 1):
        if bright[y, x] and not bg[y, x]:
            bg[y, x] = True
            q.append((y, x))
while q:
    y, x = q.popleft()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = y + dy, x + dx
        if 0 <= ny < h and 0 <= nx < w and bright[ny, nx] and not bg[ny, nx]:
            bg[ny, nx] = True
            q.append((ny, nx))

alpha = Image.fromarray(np.where(bg, 0, 255).astype(np.uint8))
# Close pinholes, then soften the edge by a pixel.
alpha = alpha.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
rgba = img.copy()
rgba.putalpha(alpha)
box = Image.fromarray((np.asarray(alpha) > 20).astype(np.uint8) * 255).getbbox()
rgba = rgba.crop(box)
rgba.save(out)
print('box', box, 'size', rgba.size)
dark = Image.new('RGBA', rgba.size, (40, 46, 52, 255))
dark.alpha_composite(rgba)
dark.convert('RGB').save(preview)
