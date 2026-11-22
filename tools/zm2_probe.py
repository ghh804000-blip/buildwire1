"""Prints the ladder program of Zelio Soft 2 .zm2 files as text, using the element table stored in each file.

Interoperability probe; the format notes are in tools/zelio_zm2_format.md.
Usage: python tools/zm2_probe.py file.zm2 [...]
"""
import struct
import sys

INDEX = '123456789ABCDEFGHJKLNPQRSTUVWXYZ'  # Zelio skips I, M and O in item numbers


def records(b):
    """{n: value} for the P1..Pn run of `len:u32 name NUL value:u32` records."""
    i = b.find(b'\x02\x00\x00\x00P1\x00')
    out = {}
    while i >= 0:
        n = struct.unpack_from('<I', b, i)[0]
        name = b[i + 4:i + 4 + n]
        if n > 6 or not name.startswith(b'P') or b[i + 4 + n] != 0:
            break
        out[int(name[1:])] = struct.unpack_from('<I', b, i + 5 + n)[0]
        i += n + 9
    return out


def element_table(p, rows):
    """Element types after the grid: (letter, nc letter, count, first index char, first code, coil kinds)."""
    k = 3 + rows * 6
    types = []
    while k in p and 0x41 <= p[k] <= 0x5A:
        upper, lower, count, first, code, nkinds = (p[k + j] for j in range(6))
        kinds = [p[k + 6 + j] for j in range(nkinds)]
        types.append((chr(upper), chr(lower) if lower else None, count, chr(first), code, kinds))
        k += 6 + nkinds
    return types


def kind_label(c):
    return {0xFA: '[', 0x12: '^'}.get(c, chr(c) if 32 < c < 127 else f'#{c:x}')


def name_of(code, types):
    for letter, lower, count, first, start, kinds in types:
        per = 1 + len(kinds)
        if start <= code < start + count * per:
            item, part = divmod(code - start, per)
            label = INDEX[INDEX.index(first) + item] if first in INDEX else str(item + 1)
            return letter, lower, label, (kind_label(kinds[part - 1]) if part else None)
    return '?', None, f'{code:#x}', None


def cell_text(v, types, coil):
    if v == 0:
        return ''
    code = v & 0x3FF
    if code == 1:
        text = '---'
    else:
        letter, lower, label, kind = name_of(code, types)
        if coil:
            text = f'{kind or ""}{letter}{label}'
        else:
            text = f'{(lower or letter.lower()) if v & 0x400 else letter}{label}'
    if v & 0x8000:
        text = '^' + text
    if v & 0x4000:
        text += 'v'
    return text


def dump(path):
    b = open(path, 'rb').read()
    p = records(b)
    at = b.find(b'SR')
    model = b[at:at + 12].split(b'\x00')[0].decode(errors='replace')
    if not p:
        print(f'== {path}: no ladder grid')
        return
    rows = p[1]
    types = element_table(p, rows)
    print(f'== {path}  ({model}, {rows} rows)')
    print('   types: ' + ', '.join(f'{t[0]}x{t[2]}@{t[4]:#x}' for t in types))
    for r in range(rows):
        cells = [p.get(3 + r * 6 + c, 0) for c in range(6)]
        if any(cells):
            line = ' | '.join(f'{cell_text(v, types, c == 5):<9}' for c, v in enumerate(cells))
            print(f'   {r + 1:03d}: {line}')


if __name__ == '__main__':
    for f in sys.argv[1:]:
        dump(f)
