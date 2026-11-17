#!/usr/bin/env python3
"""Makes the Lowkeys sound set from nothing but arithmetic.

    python3 tools/make_sounds.py            # writes app/sounds/*.wav

Every sound is synthesized (noise bursts, damped sines, a ratchet), so the
repo carries no recordings and no licence questions. The output is seeded:
running it again writes the same files, byte for byte.

To use recorded samples instead, put files with these names in a folder and
set "sounds_dir" in config.json. Numbered files (key1, key2, ...) are picked
at random:

    key1..keyN   a letter          space    the space bar
    strike       backspace         return   the carriage coming back
    bell         nearing the margin         goal   the sitting's goal reached
"""
import array
import math
import os
import random
import sys
import wave

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "app", "sounds")


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def noise(n, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def lowpass(xs, cutoff):
    a = 1.0 - math.exp(-2.0 * math.pi * cutoff / RATE)
    out, y = [], 0.0
    for x in xs:
        y += a * (x - y)
        out.append(y)
    return out


def highpass(xs, cutoff):
    low = lowpass(xs, cutoff)
    return [x - l for x, l in zip(xs, low)]


def add(buf, at, xs, amp=1.0):
    """Mixes xs into buf starting at 'at' seconds."""
    start = int(at * RATE)
    end = min(len(buf), start + len(xs))
    for i in range(start, end):
        buf[i] += amp * xs[i - start]


def burst(rng, seconds, tau, cutoff=None, low=False):
    """A noise burst that dies away with time constant tau (seconds)."""
    n = int(RATE * seconds)
    xs = noise(n, rng)
    if cutoff:
        xs = lowpass(xs, cutoff) if low else highpass(xs, cutoff)
    return [x * math.exp(-i / (tau * RATE)) for i, x in enumerate(xs)]


def ring(freq, seconds, tau, phase=0.0):
    """A damped sine."""
    n = int(RATE * seconds)
    w = 2.0 * math.pi * freq / RATE
    return [math.sin(w * i + phase) * math.exp(-i / (tau * RATE)) for i in range(n)]


def finish(buf, peak):
    """Scales to the given peak and fades the last few ms to nothing."""
    top = max(abs(x) for x in buf) or 1.0
    k = peak / top
    fade = int(0.004 * RATE)
    n = len(buf)
    out = []
    for i, x in enumerate(buf):
        g = k
        if i >= n - fade:
            g *= (n - 1 - i) / fade
        out.append(x * g)
    return out


def key(rng):
    """A type slug hitting paper on the platen, then the key coming back up."""
    buf = silence(0.12)
    add(buf, 0.0, burst(rng, 0.02, 0.0018, 2500), 0.9)                     # the hit
    add(buf, 0.0, burst(rng, 0.05, 0.009, 800, low=True), 0.5)             # platen thud
    add(buf, 0.0, ring(rng.uniform(150, 210), 0.1, 0.022), 0.55)           # body
    add(buf, 0.0, ring(rng.uniform(420, 520), 0.06, 0.012), 0.25)
    add(buf, 0.0, ring(rng.uniform(2300, 2900), 0.05, 0.010), 0.12)        # metal
    add(buf, 0.0, ring(rng.uniform(4100, 5200), 0.03, 0.006), 0.08)
    back = rng.uniform(0.028, 0.040)
    add(buf, back, burst(rng, 0.012, 0.0012, 3000), 0.22)                  # key return
    add(buf, back, ring(900, 0.03, 0.005), 0.08)
    return finish(buf, 0.8)


def space(rng):
    """The space bar: heavier and duller, no slug."""
    buf = silence(0.16)
    add(buf, 0.0, burst(rng, 0.08, 0.016, 500, low=True), 0.8)
    add(buf, 0.0, ring(110, 0.14, 0.030), 0.5)
    add(buf, 0.0, burst(rng, 0.015, 0.0016, 2200), 0.35)
    add(buf, 0.045, burst(rng, 0.012, 0.0012, 2800), 0.2)
    return finish(buf, 0.75)


def strike(rng):
    """Backspace: a short double tap with a scrape under it."""
    buf = silence(0.14)
    add(buf, 0.0, burst(rng, 0.02, 0.0018, 2200), 0.7)
    add(buf, 0.0, ring(170, 0.09, 0.020), 0.45)
    add(buf, 0.0, lowpass(burst(rng, 0.07, 0.03, 1200), 3500), 0.12)
    add(buf, 0.024, burst(rng, 0.015, 0.0014, 2600), 0.5)
    add(buf, 0.024, ring(260, 0.06, 0.014), 0.3)
    return finish(buf, 0.7)


def carriage(rng):
    """The carriage coming back: a ratchet that speeds up, then a stop."""
    buf = silence(0.6)
    t, gap = 0.0, 0.026
    while t < 0.37:
        add(buf, t, burst(rng, 0.008, 0.0010, 3000), rng.uniform(0.3, 0.45))
        add(buf, t, ring(rng.uniform(1500, 2100), 0.012, 0.003), 0.1)
        t += gap
        gap = max(0.012, gap * 0.93)
    whir = lowpass(noise(int(0.4 * RATE), rng), 1200)
    n = len(whir)
    whir = [x * math.sin(math.pi * i / n) for i, x in enumerate(whir)]
    add(buf, 0.0, whir, 0.12)
    add(buf, 0.40, burst(rng, 0.12, 0.025, 400, low=True), 0.9)            # the stop
    add(buf, 0.40, ring(95, 0.19, 0.045), 0.6)
    return finish(buf, 0.8)


def ding(f0, seconds=1.3):
    """One strike of a small bell: a few partials that aren't quite in tune."""
    buf = silence(seconds)
    for ratio, amp, tau in ((1.0, 0.6, 0.45), (1.003, 0.25, 0.45), (2.76, 0.3, 0.25),
                            (5.40, 0.15, 0.12), (8.93, 0.08, 0.06)):
        add(buf, 0.0, ring(f0 * ratio, seconds, tau), amp)
    return buf


def bell(rng):
    buf = ding(2093.0)
    add(buf, 0.0, burst(rng, 0.01, 0.001, 3000), 0.3)
    return finish(buf, 0.5)


def goal(rng):
    """Two bells, the second higher: you got there."""
    buf = silence(1.7)
    add(buf, 0.0, ding(2093.0))
    add(buf, 0.22, ding(2637.0))
    add(buf, 0.0, burst(rng, 0.01, 0.001, 3000), 0.3)
    add(buf, 0.22, burst(rng, 0.01, 0.001, 3000), 0.3)
    return finish(buf, 0.5)


def write(name, samples, out_dir):
    data = array.array("h", (int(max(-1.0, min(1.0, x)) * 32767) for x in samples))
    if sys.byteorder == "big":
        data.byteswap()
    path = os.path.join(out_dir, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())
    return path


def main(out_dir=OUT):
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(1874)   # the year the Sholes and Glidden went on sale
    made = []
    for i in range(1, 5):
        made.append(write("key%d" % i, key(rng), out_dir))
    made.append(write("space", space(rng), out_dir))
    made.append(write("strike", strike(rng), out_dir))
    made.append(write("return", carriage(rng), out_dir))
    made.append(write("bell", bell(rng), out_dir))
    made.append(write("goal", goal(rng), out_dir))
    return made


if __name__ == "__main__":
    for p in main(sys.argv[1] if len(sys.argv) > 1 else OUT):
        print(os.path.relpath(p))
