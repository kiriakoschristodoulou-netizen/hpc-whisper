#!/usr/bin/env python3
"""Makes w3tab.inc: the fixed-point tables of the handheld's format 3 modem.
Run: python3 gen-tables.py   (writes w3tab.inc next to it)"""
import math, os
H = 12; TAPS = 24; PH = 256

def bessel0(x):
    s = 1; t = 1
    for k in range(1, 30):
        t *= (x / (2 * k)) ** 2; s += t
    return s

def table(fc):
    """windowed sinc (Kaiser, beta 6), 24 taps, 257 sub-steps, Q14, unity gain at 0 Hz (as Resampler.java)"""
    rows = []
    for p in range(PH + 1):
        frac = p / PH; row = []
        for k in range(TAPS):
            t = k - (H - 1) - frac
            sinc = 2 * fc if abs(t) < 1e-9 else math.sin(2 * math.pi * fc * t) / (math.pi * t)
            r = t / (H + 0.5)
            w = 0 if abs(r) >= 1 else bessel0(6 * math.sqrt(1 - r * r)) / bessel0(6)
            row.append(sinc * w)
        s = sum(row); rows.append([round(v / s * 16384) for v in row])
    return rows

def block(name, typ, vals, per=16):
    lines = [", ".join(str(v) for v in vals[i:i + per]) for i in range(0, len(vals), per)]
    return "  %s: array[0..%d] of %s = (\n    %s);" % (name, len(vals) - 1, typ, ",\n    ".join(lines))

out = ["{ made by gen-tables.py in this folder: do not edit }"]
# sending: 51200 -> 44100 (cut-off at 22.05 kHz); listening: up from the handheld's rate (cut-off at its half rate)
for name, fc in [("RSM_DOWN", 44100 / 2 / 51200), ("RSM_UP", 0.5)]:
    out.append(block(name, "SmallInt", [v for r in table(fc) for v in r]))
out.append(block("COS4K", "SmallInt", [round(16384 * math.cos(2 * math.pi * i / 4096)) for i in range(4096)]))
out.append(block("ATANTAB", "Integer", [round(math.atan(2 ** -i) / (2 * math.pi) * 65536) for i in range(16)]))
out.append(block("FADETAB", "Integer", [round(32767 * (0.5 - 0.5 * math.cos(math.pi * k / 48))) for k in range(48)]))
# log2(1 + i/256), Q12, for signal-to-noise figures in whole numbers
out.append(block("LOG2TAB", "Integer", [round(4096 * math.log2(1 + i / 256)) for i in range(257)]))
# the listening filters' coefficients (Q14), as Rx.java computes them: high-pass at 17.5 kHz (Q 0.5412, 1.3066) and 300 Hz (Q 0.7071)
def hp(hz, q):
    w = 2 * math.pi * hz / 51200; al = math.sin(w) / (2 * q); c = math.cos(w); a0 = 1 + al
    return [round((1 + c) / 2 / a0 * 16384), round(-(1 + c) / a0 * 16384), round((1 + c) / 2 / a0 * 16384),
            round(-2 * c / a0 * 16384), round((1 - al) / a0 * 16384)]
out.append(block("BQ_SILENT1", "LongInt", hp(17500, 0.5412)))
out.append(block("BQ_SILENT2", "LongInt", hp(17500, 1.3066)))
out.append(block("BQ_FAST", "LongInt", hp(300, 0.7071)))
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3tab.inc"), "w").write("\n".join(out) + "\n")
