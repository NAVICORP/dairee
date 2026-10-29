"""The intro video's music bed: a warm C, G, Am, F loop at 96 beats a
minute with soft plucks, kick and shaker, made from sine waves (no samples,
nothing to license). Same bed as Kuree's video.

  python3 tools/store/music.py <out.wav> [seconds]
"""
import sys
import wave

import numpy as np

OUT = sys.argv[1] if len(sys.argv) > 1 else 'music.wav'
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 36.8
SR = 44100
N = int(SR * DUR)
t = np.arange(N) / SR
beat = 60 / 96
bar = beat * 4


def note(m):
    return 440 * 2 ** ((m - 69) / 12)


chords = [[48, 55, 60, 64, 67], [43, 55, 59, 62, 67], [45, 57, 60, 64, 69], [41, 57, 60, 65, 69]]
out = np.zeros(N)
# pad and bass
for i in range(int(DUR / bar) + 1):
    ch = chords[i % 4]
    s = int(i * bar * SR)
    e = min(N, int((i + 1) * bar * SR + 0.6 * SR))
    if s >= N:
        break
    tt = np.arange(e - s) / SR
    env = np.minimum(1, tt / 0.9) * np.minimum(1, np.maximum(0, (bar + 0.6 - tt) / 0.6))
    for m in ch[1:]:
        f = note(m)
        v = 0.6 * np.sin(2 * np.pi * f * tt + 0.3 * np.sin(2 * np.pi * 5 * tt)) + 0.2 * np.sin(2 * np.pi * 2 * f * tt)
        out[s:e] += 0.028 * env * v
    f = note(ch[0])
    b = np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2 * f * tt)
    out[s:e] += 0.10 * np.minimum(1, tt / 0.02) * np.exp(-tt * 1.2) * b * (tt < bar)
# plucked arpeggio on eighths once the logo has shown
pattern = [0, 2, 1, 3, 4, 3, 2, 1]
for k in range(int(DUR / (beat / 2))):
    st = k * beat / 2
    if st < 3.0 or st > DUR - 1.5:
        continue
    ch = chords[int(st / bar) % 4]
    m = ch[1:][pattern[k % 8] % 4] + 12
    s = int(st * SR)
    e = min(N, s + int(1.2 * SR))
    tt = np.arange(e - s) / SR
    f = note(m)
    v = np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(2 * np.pi * 2 * f * tt) * np.exp(-tt * 6) + 0.1 * np.sin(2 * np.pi * 3 * f * tt) * np.exp(-tt * 9)
    out[s:e] += 0.05 * np.minimum(1, tt / 0.004) * np.exp(-tt * 3.2) * v * (0.8 if k % 2 else 1.0)
# soft kick and shaker
rng = np.random.default_rng(3)
for k in range(int(DUR / beat)):
    st = k * beat
    if st < 3.2 or st > DUR - 1.6:
        continue
    s = int(st * SR)
    if k % 2 == 0:
        e = min(N, s + int(0.35 * SR))
        tt = np.arange(e - s) / SR
        f = 50 + 60 * np.exp(-tt * 30)
        out[s:e] += 0.16 * np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9)
    for h in (0, 0.5):
        s2 = int((st + h * beat) * SR)
        e2 = min(N, s2 + int(0.08 * SR))
        n = np.diff(np.concatenate([[0], rng.standard_normal(e2 - s2)]))
        tt = np.arange(e2 - s2) / SR
        out[s2:e2] += 0.012 * n * np.exp(-tt * 45) * (1.0 if h else 0.6)
# a little room
rev = np.zeros(N)
for d, g in [(0.031, 0.35), (0.047, 0.3), (0.071, 0.25), (0.113, 0.2), (0.167, 0.15), (0.241, 0.1)]:
    D = int(d * SR)
    rev[D:] += g * out[:-D]
mix = (out + 0.6 * rev) * np.minimum(1, t / 1.0) * np.minimum(1, np.maximum(0, (DUR - t) / 2.2))
mix = mix / np.max(np.abs(mix)) * 0.7
lag = int(0.012 * SR)
st = np.stack([mix, np.concatenate([np.zeros(lag), mix[:-lag]]) * 0.98 + 0.02 * mix], 1)
w = wave.open(OUT, 'wb')
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(SR)
w.writeframes((st * 32767).astype(np.int16).tobytes())
w.close()
print('made', OUT)
