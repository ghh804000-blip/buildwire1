"""Synthesizes the running-motor loops into assets/sounds/.

motor_run_3p.wav  a 3-phase induction motor at full speed: rotor rumble, cooling-fan air, slot whine, bearing hiss
motor_run_1p.wav  a single-phase motor: the same parts, smaller, with more 100 Hz and a capacitor-motor buzz

The old files were mostly 100 Hz hum, which is also what a contactor coil makes, so the two sounded alike. These are
built from what you actually hear from a motor, and every part is a whole number of cycles over the file, with the
noise made periodic in the frequency domain, so the loop has no seam.

The app plays the loop slower while the motor spins up or coasts down (playback rate follows rotor speed), so the
whine and fan sweep up in pitch as it gains speed.

Mono, 16-bit, 44.1 kHz like the other sounds. Run: python tools/make_motor_sounds.py
"""

import wave
from pathlib import Path

import numpy as np

RATE = 44100
SECONDS = 3
N = RATE * SECONDS
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"
t = np.arange(N) / RATE
rng = np.random.default_rng(7)


def tone(freq, amp, phase=None):
    # Round to a whole number of cycles over the file so the loop is seamless.
    f = round(freq * SECONDS) / SECONDS
    return amp * np.sin(2 * np.pi * f * t + (rng.uniform(0, 2 * np.pi) if phase is None else phase))


def shaped_noise(shape):
    """Periodic noise with the magnitude spectrum given by shape(freqs)."""
    freqs = np.fft.rfftfreq(N, 1 / RATE)
    spectrum = shape(freqs) * np.exp(1j * rng.uniform(0, 2 * np.pi, len(freqs)))
    spectrum[0] = 0
    x = np.fft.irfft(spectrum, N)
    return x / np.max(np.abs(x))


def band(f, lo, hi, slope=2):
    return 1 / (1 + (lo / np.maximum(f, 1)) ** (2 * slope)) / (1 + (f / hi) ** (2 * slope))


def motor(rotation, whine, poles_slots, hum, air, buzz, scale=1.0):
    x = np.zeros(N)
    # Rotor rumble: the shaft frequency and a few harmonics, felt more than heard.
    for k, a in [(1, 0.08), (2, 0.06), (3, 0.04), (4, 0.03)]:
        x += tone(rotation * k, a)
    # Cooling fan: broadband air, pulsing at the blade-pass rate. Its band moves down as the fan slows.
    s = scale
    fan = shaped_noise(lambda f: band(f, 180 * s, 2200 * s, 1) * (1 + 0.6 * band(f, 500 * s, 900 * s, 2)))
    blade = 1 + 0.35 * np.sin(2 * np.pi * round(rotation * 9 * SECONDS) / SECONDS * t)
    x += air * fan * blade
    # Slot whine: the tone that rises when a motor spins up, with its partials and a slow shimmer.
    shimmer = 1 + 0.15 * np.sin(2 * np.pi * (1 / SECONDS) * t)
    for k, a in [(1, 1.0), (2, 0.35), (3, 0.12)]:
        x += 0.12 * a * shimmer * tone(whine * k, 1)
    # Rotor slot passing, a softer rasp an octave off the whine.
    x += 0.05 * tone(rotation * poles_slots, 1)
    # A little electrical hum at twice line frequency, kept well below the mechanical sound.
    x += hum * (tone(100, 1) + 0.4 * tone(200, 1))
    # Capacitor-motor buzz: a nasal 300-600 Hz edge.
    if buzz:
        x += buzz * shaped_noise(lambda f: band(f, 300, 650, 3))
    # Bearing hiss up top.
    x += 0.025 * shaped_noise(lambda f: band(f, 4000, 9000, 2))
    return x


def save(name, x, rms_target):
    x = x - x.mean()
    x *= rms_target / np.sqrt((x ** 2).mean())
    x = np.clip(x, -0.98, 0.98)
    data = (x * 32767).astype("<i2").tobytes()
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)
    print(f"wrote {name}.wav")


# Speeds (share of full) the 3-phase motor is also rendered at, as motor_run_3p_<percent>.wav. Must match
# AppState.rotorLayers. The app crossfades between neighbours by rotor speed, so the pitch rise does not depend on the
# audio plugin changing pitch with playback rate (Windows keeps pitch when it slows playback).
LAYERS = [0.12, 0.18, 0.26, 0.36, 0.48, 0.62, 0.78, 1.0]


def main():
    # 4-pole motor, about 1450 rpm: 24.2 Hz at the shaft.
    save("motor_run_3p", motor(rotation=24.2, whine=1180, poles_slots=28, hum=0.03, air=0.55, buzz=0), 0.17)
    for s in LAYERS:
        # Everything mechanical scales with speed; the fan's air gets thinner and duller as it slows.
        x = motor(rotation=24.2 * s, whine=1180 * s, poles_slots=28, hum=0.03, air=0.55 * (0.5 + 0.5 * s), buzz=0, scale=s)
        save(f"motor_run_3p_{round(s * 100)}", x, 0.17)
    # Smaller 2-pole single-phase motor, about 2850 rpm: 47.5 Hz, a higher whine and more hum.
    save("motor_run_1p", motor(rotation=47.5, whine=1620, poles_slots=24, hum=0.07, air=0.45, buzz=0.12), 0.16)


if __name__ == "__main__":
    main()
