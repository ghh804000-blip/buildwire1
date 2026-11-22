"""Prototype: writes a ladder grid into a copy of a Zelio Soft 2 file (patching the P-records in place), to test which
files Zelio Soft accepts. Usage:
  python tools/zm2_write_probe.py template.zm2 source.zm2 out.zm2   (copies source's grid into template)
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit('\\', 1)[0].rsplit('/', 1)[0])
from zm2_probe import records  # noqa: E402


def offsets(b):
    """{n: byte offset of the value} for the P1..Pn records."""
    i = b.find(b'\x02\x00\x00\x00P1\x00')
    out = {}
    while i >= 0:
        n = struct.unpack_from('<I', b, i)[0]
        name = b[i + 4:i + 4 + n]
        if n > 6 or not name.startswith(b'P') or b[i + 4 + n] != 0:
            break
        out[int(name[1:])] = i + 5 + n
        i += n + 9
    return out


def main(template, source, out):
    t = bytearray(open(template, 'rb').read())
    s = open(source, 'rb').read()
    grid = records(s)
    where = offsets(t)
    rows = grid[1]
    for k in range(3, 3 + rows * 6):
        struct.pack_into('<I', t, where[k], grid.get(k, 0))
    open(out, 'wb').write(t)
    print('wrote', out)


if __name__ == '__main__':
    main(*sys.argv[1:4])
