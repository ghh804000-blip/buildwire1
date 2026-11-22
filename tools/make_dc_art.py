"""Draws the generic DC devices' art into assets/devices/.

generic_source_dc_adjustable__on.svg  a 0-60 V DC lab supply in the style of the AC lab supply.
(The DC motor is a photo, tools/sources/dc_motor_photo.png, not drawn here.)

Generic illustrative devices, not real products. Run: python tools/make_dc_art.py
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "devices"


def screw(x, y):
    return (f'<circle cx="{x}" cy="{y}" r="27" fill="#59636e"/><circle cx="{x}" cy="{y}" r="21" fill="#c5ccd3"/>'
            f'<path d="M{x - 13} {y}H{x + 13}M{x} {y - 13}V{y + 13}" stroke="#4a535c" stroke-width="5" stroke-linecap="round"/>')


def label(x, y, text, size=23, weight=600, fill="#e8edf2"):
    return f'<text x="{x}" y="{y}" font-family="Inter" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="middle">{text}</text>'


def supply():
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 620" width="500" height="620">'
        '<rect x="5" y="5" width="490" height="610" rx="20" fill="#3a1f1f"/>'
        '<rect x="50.0" y="55.8" width="400.0" height="260.4" rx="8" fill="#1a0b0b" stroke="#5f4b4b" stroke-width="3"/>'
        + label(250.0, 356.2, 'DC lab supply', 26) + label(250.0, 392, '0 – 60 V', 22, 400, '#c9b1b1') +
        screw(130, 530) + screw(370, 530) + label(130, 490, '+', 26, 700, '#ff7a6b') + label(370, 490, '−', 26, 700, '#8fb4ff') +
        '</svg>'
    )


def junction():
    """A solder dot where a wire branches."""
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" width="40" height="40">'
            '<circle cx="20" cy="20" r="15" fill="#1b2024"/><circle cx="20" cy="20" r="9" fill="#c5ccd3"/></svg>')


def main():
    (OUT / 'generic_source_dc_adjustable__on.svg').write_text(supply(), encoding='utf-8')
    (OUT / 'generic_junction__on.svg').write_text(junction(), encoding='utf-8')
    print('wrote DC art')


if __name__ == '__main__':
    main()
