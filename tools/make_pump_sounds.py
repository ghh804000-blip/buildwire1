"""Synthesizes the running-pump loops into assets/sounds/.

pump_run.wav and pump_run_<percent>.wav  a small centrifugal pump: a 2-pole motor, the impeller's vane-pass hum,
water rushing through the pipe with slow turbulence, a throb at shaft speed, and the odd bubble.

A pump is driven by a motor, but what you hear is mostly the water, so this is its own sound rather than the motor
loop. Like the motor, it is rendered at several speeds (LAYERS) and the app crossfades between them by speed, so the
pitch rises while the pump spins up; at low speed the water barely moves, so the flow comes in with speed.

Every part repeats a whole number of times over the file and the noise is made periodic, so the loop has no seam.
Builds on the helpers in make_motor_sounds.py. Run: python tools/make_pump_sounds.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_motor_sounds as m  # noqa: E402

N, RATE, SECONDS = m.N, m.RATE, m.SECONDS
t = m.t
rng = np.random.default_rng(11)


def turbulence(lo, hi):
    """A slow, periodic wobble between about -1 and 1."""
    x = m.shaped_noise(lambda f: m.band(f, lo, hi, 2))
    return x / np.max(np.abs(x))


def bubbles(scale):
    """Short damped pings at random moments, wrapped around the end so the loop stays seamless."""
    out = np.zeros(N)
    count = int(10 + 22 * scale)
    for _ in range(count):
        start = rng.integers(0, N)
        freq = rng.uniform(320, 950) * (0.7 + 0.3 * scale)
        length = int(RATE * rng.uniform(0.012, 0.035))
        k = np.arange(length)
        ping = np.sin(2 * np.pi * freq * k / RATE) * np.exp(-k / (length / 4)) * rng.uniform(0.3, 1)
        idx = (start + k) % N
        out[idx] += ping
    return out


def pump(scale):
    s = scale
    rotation = 47.5 * s  # 2-pole motor, about 2850 rpm
    vanes = 6
    x = np.zeros(N)
    # The motor underneath: shaft rumble and a quiet slot whine.
    for k, a in [(1, 0.05), (2, 0.04), (3, 0.025)]:
        x += m.tone(rotation * k, a)
    for k, a in [(1, 1.0), (2, 0.3)]:
        x += 0.05 * a * m.tone(1450 * s * k, 1)
    # The impeller: the vane-pass hum that makes a pump sound like a pump.
    x += 0.09 * m.tone(rotation * vanes, 1) + 0.035 * m.tone(rotation * vanes * 2, 1)
    # Water through the pipe: broadband rush, swelling and settling, throbbing at shaft speed.
    flow = m.shaped_noise(lambda f: m.band(f, 160, 1700, 1) * (1 + 0.8 * m.band(f, 350, 700, 2)))
    swell = 1 + 0.35 * turbulence(0.4, 3.0)
    throb = 1 + 0.18 * np.sin(2 * np.pi * round(rotation * SECONDS) / SECONDS * t)
    x += 0.62 * s ** 1.3 * flow * swell * throb
    # Spray and hiss at the top, and bubbles in the stream.
    x += 0.06 * s * m.shaped_noise(lambda f: m.band(f, 2500, 7000, 2))
    x += 0.05 * s * bubbles(s)
    # A trace of electrical hum.
    x += 0.02 * (m.tone(100, 1) + 0.4 * m.tone(200, 1))
    return x


def main():
    m.save('pump_run', pump(1.0), 0.15)
    for s in m.LAYERS:
        m.save(f'pump_run_{round(s * 100)}', pump(s), 0.15)


if __name__ == '__main__':
    main()
