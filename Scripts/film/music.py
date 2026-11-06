#!/usr/bin/env python3
"""The film's score, generated from the same timeline as the pictures.

    python3 music.py out.wav

Every sound that goes with something on screen is placed at that moment.
"""
import sys
import numpy as np

SR = 48000
DUR = 48.0
N = int(SR * DUR)
rng = np.random.default_rng(1729)
out = np.zeros((N, 2))


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def place(buf, at, gain=1.0, pan=0.0, track=None):
    target = out if track is None else track
    i = int(at * SR)
    if i >= N:
        return
    n = min(len(buf), N - i)
    if n <= 0:
        return
    left = np.cos((pan + 1) * np.pi / 4) * gain
    right = np.sin((pan + 1) * np.pi / 4) * gain
    target[i:i + n, 0] += buf[:n] * left
    target[i:i + n, 1] += buf[:n] * right


def env(n, attack, release, curve=1.0):
    e = np.ones(n)
    a = min(int(attack * SR), n)
    r = min(int(release * SR), n)
    if a:
        e[:a] = np.linspace(0, 1, a) ** curve
    if r:
        e[-r:] *= np.linspace(1, 0, r) ** curve
    return e


def pad(freq, dur, bright=0.5, attack=2.0, release=2.5):
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for h, amp in [(1, 1), (2, .45 * bright + .1), (3, .25 * bright), (4, .14 * bright), (5, .08 * bright), (6, .04 * bright)]:
        for detune in (-0.0035, 0.0, 0.0041):
            phase = rng.random() * 6.283
            y += amp * np.sin(2 * np.pi * freq * h * (1 + detune) * t + phase + .5 * np.sin(2 * np.pi * .13 * t + phase))
    return y / 6 * env(n, attack, release, 1.6)


def pluck(freq, dur=1.4, bright=.6):
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for h in range(1, 7):
        y += (bright ** (h - 1)) * np.sin(2 * np.pi * freq * h * t) * np.exp(-t * (2.6 + h * 1.3)) / h
    return y * (1 - np.exp(-t * 900))


def bell(freq, dur=2.4):
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for ratio, amp, decay in [(1, 1, 1.9), (2.01, .45, 3), (3.02, .22, 4.5), (4.2, .12, 6.5)]:
        y += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t * decay)
    return y * (1 - np.exp(-t * 1500))


def sub_hit(freq=48, dur=1.6, drop=.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    sweep = freq * (1 + 2.5 * np.exp(-t * 34))
    return np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t * 4.2)


def band_noise(dur, lo, hi):
    """Noise between two frequencies, each of which may be a curve over time."""
    n = int(dur * SR)
    win = 2048
    hop = win // 2
    noise = rng.standard_normal(n + win)
    y = np.zeros(n + win)
    window = np.hanning(win)
    lows = np.interp(np.arange(0, n + win, hop), np.linspace(0, n + win, len(np.atleast_1d(lo))), np.atleast_1d(lo))
    highs = np.interp(np.arange(0, n + win, hop), np.linspace(0, n + win, len(np.atleast_1d(hi))), np.atleast_1d(hi))
    freqs = np.fft.rfftfreq(win, 1 / SR)
    for k, start in enumerate(range(0, n, hop)):
        spec = np.fft.rfft(noise[start:start + win] * window)
        mask = np.exp(-((np.maximum(0, lows[k] - freqs) / (lows[k] * .4 + 1)) ** 2) - ((np.maximum(0, freqs - highs[k]) / (highs[k] * .4 + 1)) ** 2))
        y[start:start + win] += np.fft.irfft(spec * mask) * window
    return y[:n] / (np.std(y[:n]) + 1e-9)


def whoosh(dur=.9, lo=250, hi=6500, peak=.6):
    n = int(dur * SR)
    t = np.linspace(0, 1, n)
    y = band_noise(dur, [lo, hi, lo], [lo * 3, hi * 2.4, lo * 3])
    shape = np.where(t < peak, (t / peak) ** 2.2, ((1 - t) / (1 - peak)) ** 1.8)
    return y * shape


def click(freq=2300, dur=.05):
    n = int(dur * SR)
    t = np.arange(n) / SR
    body = np.sin(2 * np.pi * freq * t) * np.exp(-t * 170)
    noise = rng.standard_normal(n) * np.exp(-t * 340) * .55
    thud = np.sin(2 * np.pi * 180 * t) * np.exp(-t * 60) * .8
    return body * .45 + noise + thud


def shutter():
    a = band_noise(.05, 1400, 9000) * np.exp(-np.arange(int(.05 * SR)) / SR * 90)
    b = band_noise(.09, 800, 6000) * np.exp(-np.arange(int(.09 * SR)) / SR * 55)
    y = np.zeros(int(.2 * SR))
    y[:len(a)] += a * .8
    i = int(.075 * SR)
    y[i:i + len(b)] += b[:len(y) - i]
    return y


def reverb(x, seconds=3.2, brightness=5200):
    """Long hall: convolved with shaped noise, one impulse per channel."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    wet = np.zeros_like(x)
    fft_n = x.shape[0] + n
    freqs = np.fft.rfftfreq(fft_n, 1 / SR)
    damp = np.exp(-(freqs / brightness) ** 2)
    for ch in range(2):
        ir = rng.standard_normal(n) * np.exp(-t * 6.2 / seconds)
        ir[:int(.018 * SR)] = 0
        ir /= np.sqrt(np.sum(ir ** 2))
        wet[:, ch] = np.fft.irfft(np.fft.rfft(x[:, ch], fft_n) * np.fft.rfft(ir, fft_n) * damp, fft_n)[:x.shape[0]]
    return wet


# ---------------------------------------------------------------------------
# Harmony: D minor colours, opening to a warm D major at the mark.
BPM = 96
BEAT = 60 / BPM
bars = [
    (0.0, [38, 45, 53, 57, 60], .25),     # Dm(add) — dark, wide
    (7.0, [34, 46, 53, 58, 62], .45),     # Bb
    (11.0, [41, 48, 57, 60, 64], .5),     # F
    (15.3, [36, 48, 55, 60, 64], .55),    # C
    (19.2, [38, 50, 57, 62, 65], .6),     # Dm
    (22.0, [34, 46, 53, 62, 65], .6),     # Bb
    (25.0, [36, 48, 55, 64, 67], .7),     # C
    (27.4, [33, 45, 52, 60, 64], .7),     # Am
    (30.6, [34, 46, 58, 62, 65], .8),     # Bb
    (32.5, [36, 48, 60, 64, 67], .9),     # C
    (35.2, [41, 53, 60, 65, 69], .55),    # F — arrives
    (36.5, [38, 50, 57, 65, 69], .35),    # Dm, airy
    (39.9, [34, 46, 58, 65, 69], .35),    # Bb
    (41.7, [36, 48, 60, 67, 72], .4),     # C sus, waiting
    (43.65, [38, 50, 57, 62, 66, 69, 74, 78], .65),  # D major: home
]
pads = np.zeros((N, 2))
for i, (at, notes, bright) in enumerate(bars):
    end = bars[i + 1][0] if i + 1 < len(bars) else DUR + 1.5
    length = end - at + 2.4
    for k, note in enumerate(notes):
        place(pad(midi(note), length, bright, attack=1.6 if i else 3.0, release=2.4), at, gain=.09 if note > 44 else .17, pan=(k / max(1, len(notes) - 1) - .5) * .7, track=pads)
pads *= np.interp(np.arange(N) / SR, [0, 3, 30, 35, 36.5, 41.5, 43.6, 46, 48], [.55, .8, 1, 1.1, .55, .7, 1.25, 1, .55])[:, None]
out += pads

# Pulse: plucks on the chord, thickening as it goes.
plucks = np.zeros((N, 2))
pattern = [0, 2, 3, 4, 2, 3, 1, 3]
step = BEAT / 2
t0 = 7.0
i = 0
at = t0
while at < 36.0:
    current = [b for b in bars if b[0] <= at][-1]
    notes = sorted(current[1][1:])
    note = notes[pattern[i % len(pattern)] % len(notes)] + 12
    density = np.interp(at, [7, 15, 22, 30.6, 35], [.55, .75, 1, 1, .8])
    if rng.random() < density:
        vel = (.75 + .25 * (i % 4 == 0)) * np.interp(at, [7, 12, 22, 30, 35, 36], [.3, .6, .75, 1, 1, .3])
        place(pluck(midi(note), 1.2, .55), at, gain=.085 * vel, pan=np.sin(i * .9) * .55, track=plucks)
    # Sixteenths once the run is going.
    if at >= 30.6 and at < 34.3:
        place(pluck(midi(note + 12), .5, .4), at + step / 2, gain=.03, pan=-np.sin(i * .9) * .5, track=plucks)
    i += 1
    at += step
out += plucks

# Heartbeat, from the moment the app acts.
beats = np.zeros((N, 2))
at = 15.3
while at < 36.3:
    level = np.interp(at, [15.3, 22, 30.6, 34, 36], [.3, .5, .8, 1, .3])
    place(sub_hit(46), at, gain=.42 * level, track=beats)
    at += BEAT * (2 if at < 30.6 else 1)
out += beats

fx = np.zeros((N, 2))
# The line of light between shots.
for at in [6.9, 15.3, 22.0, 27.3, 36.4, 41.6]:
    place(whoosh(1.0), at - .05, gain=.085, track=fx)
    place(bell(midi(86), 1.6), at + .46, gain=.018, pan=.25, track=fx)

# 1. Sheets rustling past.
for k in range(46):
    at = rng.random() * 6.4 + .3
    d = .12 + rng.random() * .22
    place(whoosh(d, 1200, 7000, .35), at, gain=.012 + rng.random() * .012, pan=rng.random() * 1.6 - .8, track=fx)

# 2. The scan.
n = int(1.8 * SR)
scan_tone = band_noise(1.8, [500, 3200, 5200], [1500, 7000, 9800])
place(scan_tone * np.sin(np.linspace(0, np.pi, n)) ** 1.3, 7.72, gain=.08, track=fx)
hum_t = np.arange(n) / SR
place(np.sin(2 * np.pi * np.cumsum(np.linspace(260, 780, n)) / SR) * np.sin(np.linspace(0, np.pi, n)) ** 2, 7.72, gain=.035, track=fx)
scale = [62, 65, 67, 69, 72, 74, 77]
for i in range(7):                    # frames drawn around each block
    place(bell(midi(scale[i] + 12), 1.8), 9.55 + i * .09, gain=.032, pan=(i - 3) * .12, track=fx)
for i in range(7):                    # each block flying to the column
    place(whoosh(.75, 400, 3600, .55), 11.0 + i * .13, gain=.028, pan=-.4 + i * .13, track=fx)
    place(pluck(midi(scale[i] + 24), .9, .35), 11.95 + i * .13, gain=.034, pan=-.1 + i * .08, track=fx)

# 3. Capture.
for i in range(4):
    place(click(1700 + i * 160), 15.75 + i * .13 + .05, gain=.2, pan=(i - 1.5) * .22, track=fx)
place(sub_hit(70, .7), 16.17, gain=.3, track=fx)
drag = band_noise(.9, 1800, 4200)
place(drag * np.sin(np.linspace(0, np.pi, len(drag))), 16.95, gain=.016, track=fx)
place(pluck(midi(79), .6, .3), 18.0, gain=.06, track=fx)
place(click(2600), 18.85, gain=.2, track=fx)
place(shutter(), 18.87, gain=.13, track=fx)
scan2 = band_noise(1.25, [700, 3400], [1800, 8200])
place(scan2 * np.sin(np.linspace(0, np.pi, len(scan2))) ** 1.3, 19.15, gain=.062, track=fx)
place(bell(midi(81), 2.2), 20.35, gain=.05, track=fx)

# 4. The ribbon: rising air as it pulls back; a seam every so often.
air = band_noise(5.6, [300, 900, 3200], [1100, 3400, 9000])
place(air * env(len(air), 1.6, 1.1, 1.4), 22.1, gain=.05, track=fx)
at = 22.5
gap = .36
while at < 27.2:
    place(click(3200, .03), at, gain=.038, pan=np.sin(at * 2.1) * .6, track=fx)
    at += gap
    gap = max(.1, gap * .955)


# 5. Show it once, then all of it.
def capture_time(i, total=64, start=30.6, end=34.3):
    if i == 0:
        return 28.45
    return start + (end - start) * ((i - 1) / (total - 2)) ** .62


place(shutter(), 28.45, gain=.2, track=fx)
place(bell(midi(84), 1.2), 28.47, gain=.03, track=fx)
place(click(1500), 29.5, gain=.24, track=fx)
place(whoosh(.45, 900, 5200, .35), 29.53, gain=.035, track=fx)
for i in range(1, 64):
    at = capture_time(i)
    pitch = 62 + scale[i % 7] - 62 + 12 + int(i / 64 * 12)
    place(shutter(), at, gain=.055 + .02 * (i / 64), pan=np.sin(i * 1.9) * .7, track=fx)
    place(pluck(midi(pitch), .32, .45), at, gain=.024 + .018 * (i / 64), pan=np.sin(i * 1.3) * .6, track=fx)
riser = band_noise(3.7, [300, 1100, 5200], [900, 4000, 12000])
place(riser * np.linspace(0, 1, len(riser)) ** 2.4, 30.6, gain=.075, track=fx)
col = whoosh(1.2, 200, 3200, .78)
place(col, 34.15, gain=.14, track=fx)
place(sub_hit(40, 2.4), 35.2, gain=.8, track=fx)
for k, note in enumerate([65, 69, 72, 77]):
    place(bell(midi(note + 12), 3.2), 35.2 + k * .035, gain=.05, pan=(k - 1.5) * .25, track=fx)

# 6. Words of light.
for k, at in enumerate([36.9, 37.55, 38.2, 38.8, 39.35]):
    place(whoosh(.55, 800, 6200, .7), at - .25, gain=.03, pan=(k - 2) * .25, track=fx)
    place(bell(midi([74, 77, 81, 79, 77][k]), 1.9), at + .02, gain=.05, pan=(k - 2) * .2, track=fx)
place(whoosh(.7, 400, 3600, .7), 39.65, gain=.05, track=fx)
place(sub_hit(55, 1.1), 40.0, gain=.45, track=fx)
place(click(620, .09), 40.0, gain=.27, track=fx)

# 7. The mark.
for i in range(3):
    place(whoosh(1.0, 300, 4000, .6), 41.9 + i * .16, gain=.04, pan=(i - 1) * .4, track=fx)
    place(click(900, .06), 42.72 + i * .16, gain=.1, track=fx)
for i, note in enumerate([74, 78, 81, 86]):
    place(bell(midi(note + 12), 3.8), 43.4 + i * .12, gain=.058, pan=(i - 1.5) * .25, track=fx)
place(sub_hit(36, 4.0), 43.65, gain=.95, track=fx)
place(bell(midi(62), 5), 43.65, gain=.09, track=fx)
place(bell(midi(74), 4), 45.25, gain=.06, track=fx)
place(pluck(midi(90), 2.8, .4), 45.65, gain=.03, track=fx)
out += fx

# Room around everything, a little more of it on what is high.
wet = reverb(out, 3.4)
mix = out * .88 + wet * .52

# Gentle master: stops DC, soft-limits, and leaves the head and tail clean.
mix -= mix.mean(axis=0)
mix /= np.max(np.abs(mix))
mix = np.tanh(mix * 1.5) / np.tanh(1.5)
mix *= np.interp(np.arange(N) / SR, [0, .4, DUR - 1.4, DUR - .05, DUR], [0, 1, 1, 0, 0])[:, None]
mix = mix / np.max(np.abs(mix)) * .89

path = sys.argv[1] if len(sys.argv) > 1 else 'music.wav'
import wave
with wave.open(path, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix * 32767).astype('<i2').tobytes())
rms = np.sqrt(np.mean(mix ** 2))
print(f'{path}: {DUR:.0f} s, peak {np.max(np.abs(mix)):.2f}, rms {20 * np.log10(rms):.1f} dB')
