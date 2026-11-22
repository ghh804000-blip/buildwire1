"""Synthesizes the brushed DC motor loops into assets/sounds/.

motor_run_dc.wav and motor_run_dc_<percent>.wav  a small permanent-magnet DC motor: the buzzy, raspy commutator
tone (brushes crossing the commutator segments), brush hiss, a light fan, and a bearing whine. No 100 Hz mains hum:
a DC motor has none, which is part of why it sounds unlike the induction motors.

Rendered at the same speeds as the other machines (LAYERS) so the app can crossfade by speed. A DC motor's speed
follows its voltage, so on the adjustable supply the pitch follows the knob. Builds on make_motor_sounds.py.
Run: python tools/make_dc_motor_sounds.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_motor_sounds as m  # noqa: E402

N, SECONDS = m.N, m.SECONDS
t = m.t


def buzz(freq, amp, partials=9):
    """A raspy tone: a few odd and even partials falling off slowly, like brushes chattering on segments."""
    x = np.zeros(N)
    for k in range(1, partials + 1):
        x += m.tone(freq * k, amp / k ** 0.9)
    return x


def dc_motor(scale):
    s = scale
    rotation = 50 * s  # about 3000 rpm
    segments = 12
    x = np.zeros(N)
    x += m.tone(rotation, 0.06) + m.tone(rotation * 2, 0.04)
    # Commutator: segment-pass buzz, wobbling a little in strength turn by turn.
    wobble = 1 + 0.25 * np.sin(2 * np.pi * round(rotation * SECONDS) / SECONDS * t)
    x += 0.07 * buzz(rotation * segments, 1) * wobble
    # Brush hiss and sparks.
    x += 0.10 * (0.4 + 0.6 * s) * m.shaped_noise(lambda f: m.band(f, 2500, 9000, 2))
    # A small fan.
    x += 0.22 * s ** 1.2 * m.shaped_noise(lambda f: m.band(f, 300, 2400, 1))
    # Bearing whine.
    x += 0.035 * m.tone(2300 * s, 1)
    return x


def main():
    m.save('motor_run_dc', dc_motor(1.0), 0.15)
    for s in m.LAYERS:
        m.save(f'motor_run_dc_{round(s * 100)}', dc_motor(s), 0.15)


if __name__ == '__main__':
    main()
