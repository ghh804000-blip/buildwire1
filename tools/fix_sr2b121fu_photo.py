"""SR2B121FU edit from Gemini has a duplicated I5 terminal (9 inputs instead of 8). Drops the second I5 column by
sliding I6, I7, I8 and the blind hole one pitch left, then fills the freed space with plain housing."""
import sys

import numpy as np
from PIL import Image

src, out, zoom = sys.argv[1:4]
img = Image.open(src).convert('RGB')
a = np.asarray(img).copy()

# Find the exact pitch and the start of the duplicated column from the screw heads (dark blobs) in the screw row.
row = a[85:110, 240:700].astype(int).min(axis=2).min(axis=0)  # darkest value per x across the screw row
dark = row < 90
cols = []
x = 0
while x < len(dark):
    if dark[x]:
        start = x
        while x < len(dark) and dark[x]:
            x += 1
        if x - start > 8:
            cols.append((240 + start, 240 + x))
    x += 1
print('screws', cols)
centers = [(s + e) / 2 for s, e in cols]
pitch = (centers[-1] - centers[0]) / (len(centers) - 1)
print('pitch', pitch)
assert len(cols) == 10, 'expected 9 screws + hole'
dup_left = round((centers[4] + centers[5]) / 2)  # boundary between the first and second I5
y0, y1 = 45, 122
p = round(pitch)
end = cols[-1][1] + 8  # just past the blind hole
a[y0:y1, dup_left:end - p] = a[y0:y1, dup_left + p:end]
# Plain housing for the freed strip, taken from just right of the old hole.
a[y0:y1, end - p:end] = a[y0:y1, end + 4:end + 4 + p]
fixed = Image.fromarray(a)
fixed.save(out)
fixed.crop((240, 40, 700, 125)).resize((460 * 3, 85 * 3)).save(zoom)
