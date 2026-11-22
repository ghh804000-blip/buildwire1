"""Synthesizes the device explosion sounds into assets/sounds/.

explosion_1..3.wav  a sharp electrical bang with a low boom, debris crackle and a fading rumble (three takes)
sizzle.wav          a seamless loop of frying, arcing crackle, played while a device overheats

Mono, 16-bit, 44.1 kHz like the other sounds. Run: python tools/make_explosion_sounds.py
"""

import wave
from pathlib import Path

import numpy as np

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"


def lowpass(x, cutoff):
    """One-pole low-pass, applied twice for a softer slope."""
    a = np.exp(-2 * np.pi * cutoff / RATE)
    for _ in range(2):
        y = np.empty_like(x)
        acc = 0.0
        for i, v in enumerate(x):
            acc = (1 - a) * v + a * acc
            y[i] = acc
        x = y
    return x


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def write(name, x):
    x = x / (np.max(np.abs(x)) + 1e-9) * 0.92
    # Fade the last few milliseconds so nothing clicks.
    tail = min(len(x), int(0.01 * RATE))
    x[-tail:] *= np.linspace(1, 0, tail)
    data = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())


def explosion(seed):
    rng = np.random.default_rng(seed)
    length = 2.2 + rng.uniform(-0.2, 0.3)
    n = int(length * RATE)
    t = np.arange(n) / RATE

    # The crack: a few milliseconds of bright noise.
    crack = rng.standard_normal(n) * np.exp(-t / 0.012)
    crack = highpass(crack, 1800)

    # The boom: a falling low thump plus filtered noise.
    f0 = rng.uniform(48, 62)
    freq = f0 + 90 * np.exp(-t / 0.05)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    thump = np.sin(phase) * np.exp(-t / 0.35) * (1 - np.exp(-t / 0.003))
    body = lowpass(rng.standard_normal(n), 420) * np.exp(-t / 0.45) * 2.4

    # The rumble that hangs on.
    rumble = lowpass(rng.standard_normal(n), 120) * np.exp(-t / 0.9) * 3.0

    # Debris and arcing: random sharp ticks, densest right after the bang.
    debris = np.zeros(n)
    count = int(rng.uniform(55, 80))
    for _ in range(count):
        start = int(abs(rng.exponential(0.35)) * RATE) + int(0.03 * RATE)
        if start >= n - 400:
            continue
        size = int(rng.uniform(60, 380))
        tick = rng.standard_normal(size) * np.exp(-np.arange(size) / (size / 5))
        debris[start:start + size] += tick * rng.uniform(0.15, 0.6) * np.exp(-start / RATE / 0.8)
    debris = highpass(debris, 1200)

    x = crack * 1.4 + thump * 1.6 + body + rumble + debris * 0.9
    # Soft saturation makes it sound loud without clipping.
    return np.tanh(x * 1.6)


def sizzle():
    rng = np.random.default_rng(7)
    length = 2.0
    n = int(length * RATE)
    hiss = highpass(rng.standard_normal(n), 2500) * 0.18
    # Mains buzz that wobbles, as a stressed coil does.
    t = np.arange(n) / RATE
    buzz = (np.sign(np.sin(2 * np.pi * 100 * t)) * 0.5 + np.sin(2 * np.pi * 200 * t) * 0.3) * 0.12
    buzz *= 0.6 + 0.4 * np.sin(2 * np.pi * 3 * t)
    crackle = np.zeros(n)
    for _ in range(420):
        start = int(rng.uniform(0, n - 300))
        size = int(rng.uniform(20, 220))
        crackle[start:start + size] += rng.standard_normal(size) * np.exp(-np.arange(size) / (size / 4)) * rng.uniform(0.2, 1.0)
    crackle = highpass(crackle, 900)
    x = hiss + buzz + crackle * 0.55
    # Crossfade the ends so the loop is seamless.
    fade = int(0.08 * RATE)
    ramp = np.linspace(0, 1, fade)
    x[:fade] = x[:fade] * ramp + x[-fade:] * (1 - ramp)
    x = x[:-fade]
    x = x / (np.max(np.abs(x)) + 1e-9) * 0.7
    data = (x * 32767).astype("<i2")
    with wave.open(str(OUT / "sizzle.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())


if __name__ == "__main__":
    for take in range(1, 4):
        write(f"explosion_{take}", explosion(100 + take))
    sizzle()
    print("wrote explosion_1..3.wav and sizzle.wav to", OUT)
