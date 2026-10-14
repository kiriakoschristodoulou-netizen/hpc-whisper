#!/usr/bin/env python3
"""Make a pretend recording of turbotest.wav: a crude sound chip (ghosts), a room
(echo), the phone's 48 kHz, a clock difference, noise. For checking analyze.py.
usage: simulate.py turbotest.wav out.wav [native_rate] [noise]"""
import sys, wave
import numpy as np
from scipy.signal import resample_poly, resample
src = sys.argv[1]; out = sys.argv[2]
native = int(sys.argv[3]) if len(sys.argv) > 3 else 43200
noise = float(sys.argv[4]) if len(sys.argv) > 4 else 0.002
with wave.open(src) as w:
    x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(float) / 32768
# crude conversion to the chip's own rate (linear interpolation), then played at that rate
n = int(len(x) * native / 44100)
t = np.arange(n) * 44100 / native
y = np.interp(t, np.arange(len(x)), x)
# the room: two echoes
z = y.copy(); d1, d2 = int(native * 0.003), int(native * 0.011)
echo = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
z[d1:] += 0.4 * echo * y[:-d1]; z[d2:] += 0.2 * echo * y[:-d2]
# the phone at 48 kHz, its clock 120 ppm fast
g = np.gcd(48000, native)
r = resample_poly(z, 48000 // g, native // g)
r = resample(r, int(round(len(r) / 1.00012)))
r = np.concatenate([np.zeros(48000 * 2), 0.15 * r, np.zeros(48000 * 2)])
rng = np.random.default_rng(1)
r += noise * rng.standard_normal(len(r)) + 0.05 * np.sin(2 * np.pi * 300 * np.arange(len(r)) / 48000)
q = np.clip(np.round(r * 32767), -32767, 32767).astype('<i2')
with wave.open(out, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000); w.writeframes(q.tobytes())
