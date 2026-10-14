#!/usr/bin/env python3
"""HPC Whisper Turbo test: the test sounds.

turbotest.wav  (44100 Hz, played by the handheld, recorded by the phone)
  Measures how much more the inaudible band can carry: the band's response
  and ghosts (a slow sweep), several tones at once ("multi-tone"), and many
  carriers at once with phase coding ("OFDM"). Every section uses known
  pseudo-random data (fixed seeds), so a recording shows exact error rates.

phone-test.wav (48000 Hz, played by the phone, recorded by the handheld)
  Measures what the handheld's microphone hears: a sweep over the whole
  range, steady tones, and an audible multi-carrier burst.

The section table is written to sections.json; analyze.py uses it.
Run: python3 gen.py outdir
"""
import json, sys, os
import numpy as np

R = 44100
PEAK = 0.5                  # single tones at HPC Whisper's default 50 % volume
rng_seed = 20261014


def chirp(f0, f1, dur, rate=R, amp=PEAK):
    n = int(dur * rate)
    t = np.arange(n) / rate
    ph = 2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * dur))
    return amp * np.sin(ph) * fade(n, rate)


def fade(n, rate, ms=5):
    w = np.ones(n)
    k = min(n // 2, int(rate * ms / 1000))
    if k > 0:
        r = 0.5 - 0.5 * np.cos(np.pi * np.arange(k) / k)
        w[:k] = r
        w[-k:] = r[::-1]
    return w


def multitone(grid, k, sym_ms, nsym, seed, rate=R, peak=PEAK):
    """k tones at once out of the grid, a new set every symbol; smooth 2 ms
    cross-fades between symbols (sudden changes would click)."""
    rng = np.random.default_rng(seed)
    ns = int(rate * sym_ms / 1000)
    sets = [np.sort(rng.choice(len(grid), k, replace=False)) for _ in range(nsym)]
    out = np.zeros(ns * nsym)
    xf = int(rate * 0.002)
    t = np.arange(ns + xf) / rate
    env = np.ones(ns + xf)
    r = 0.5 - 0.5 * np.cos(np.pi * np.arange(xf) / xf)
    env[:xf] = r
    env[-xf:] = r[::-1]
    for s, st in enumerate(sets):
        a = s * ns
        seg = np.zeros(ns + xf)
        for i in st:
            seg += np.sin(2 * np.pi * grid[i] * (t + a / rate))
        seg *= env
        b = min(len(out), a + ns + xf)
        out[a:b] += seg[:b - a]
    out *= peak / max(1e-9, np.max(np.abs(out)))
    return out, [s.tolist() for s in sets]


def ofdm(f0, step, ncar, sym_ms, cp_ms, nsym, seed, rate=R, peak=PEAK, pilot_every=8):
    """ncar carriers, step Hz apart, each symbol a cyclic prefix plus one FFT
    period of 1/step... (sym_ms is the FFT period, a whole number of cycles of
    every carrier). Data: differential QPSK from symbol to symbol; every
    pilot_every-th carrier is a pilot (phase always +0)."""
    rng = np.random.default_rng(seed)
    nfft = int(round(rate * sym_ms / 1000))
    ncp = int(round(rate * cp_ms / 1000))
    data = rng.integers(0, 4, size=(nsym, ncar))
    for c in range(0, ncar, pilot_every):
        data[:, c] = 0
    phase = rng.uniform(0, 2 * np.pi, ncar)          # random start phases keep the peaks down
    t = np.arange(-ncp, nfft) / rate
    out = []
    win = fade(nfft + ncp, rate, ms=1)
    freqs = f0 + step * np.arange(ncar)
    for s in range(nsym + 1):                        # symbol 0 is the reference
        if s > 0:
            phase = phase + data[s - 1] * np.pi / 2
        seg = np.zeros(nfft + ncp)
        for c in range(ncar):
            seg += np.cos(2 * np.pi * freqs[c] * t + phase[c])
        out.append(seg * win)
    x = np.concatenate(out)
    x *= peak / np.max(np.abs(x))
    return x, data.tolist(), freqs.tolist(), nfft, ncp


def wav16(path, x, rate, ch=1):
    x = np.clip(np.round(x * 32767), -32767, 32767).astype('<i2')
    with open(path, 'wb') as f:
        n = len(x) * 2
        f.write(b'RIFF' + (36 + n).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little'))
        f.write((1).to_bytes(2, 'little') + ch.to_bytes(2, 'little') + rate.to_bytes(4, 'little'))
        f.write((rate * 2 * ch).to_bytes(4, 'little') + (2 * ch).to_bytes(2, 'little') + (16).to_bytes(2, 'little'))
        f.write(b'data' + n.to_bytes(4, 'little') + x.tobytes())


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    parts, sections = [], []
    pos = [0]

    def add(name, label, x, info=None):
        sections.append(dict(name=name, label=label, start=pos[0] / R, dur=len(x) / R, **(info or {})))
        parts.append(x)
        pos[0] += len(x)

    def gap(sec):
        parts.append(np.zeros(int(R * sec)))
        pos[0] += int(R * sec)

    grid100 = 18000 + 100 * np.arange(36)
    grid200 = 18000 + 200 * np.arange(18)
    gap(0.5)
    add('sync1', 'Start marker', chirp(18000, 21500, 0.2))
    gap(0.2)
    add('sweep', 'Sweep 17.5-21.9 kHz', chirp(17500, 21900, 3.0), dict(f0=17500, f1=21900))
    gap(0.3)
    add('sync2', 'Marker', chirp(18000, 21500, 0.2))
    gap(0.2)
    for i, (name, grid, k, ms) in enumerate([('m1', grid100, 4, 20), ('m2', grid100, 6, 10),
                                             ('m3', grid200, 3, 10), ('m4', grid100, 8, 20)]):
        nsym = int(1600 / ms)
        x, sets = multitone(grid, k, ms, nsym, rng_seed + i)
        add(name, 'Multi-tone %d of %d, %d ms' % (k, len(grid), ms), x,
            dict(kind='multitone', grid=grid.tolist(), k=k, sym_ms=ms, sets=sets))
        gap(0.1)
    for i, (name, f0, step, ncar, ms, cp, peak, label) in enumerate([
            ('o1', 18100, 100, 32, 10, 2.5, PEAK, 'OFDM 32 carriers, 10 ms'),
            ('o2', 18200, 200, 16, 10, 2.5, PEAK, 'OFDM 16 carriers 200 Hz apart'),
            ('o3', 18100, 100, 32, 20, 5.0, PEAK, 'OFDM 32 carriers, 20 ms'),
            ('o4', 18100, 100, 32, 10, 2.5, PEAK / 2, 'OFDM 32 carriers, quiet'),
            ('o5', 18100, 100, 32, 10, 2.5, 0.9, 'OFDM 32 carriers, LOUD: listen!')]):
        nsym = int(2000 / (ms + cp))
        x, data, freqs, nfft, ncp = ofdm(f0, step, ncar, ms, cp, nsym, rng_seed + 10 + i, peak=peak)
        add(name, label, x, dict(kind='ofdm', freqs=freqs, nfft=nfft, ncp=ncp, data=data, peak=peak))
        gap(0.1)
    add('sync3', 'End marker', chirp(18000, 21500, 0.2))
    gap(0.5)
    x = np.concatenate(parts)
    wav16(os.path.join(outdir, 'turbotest.wav'), x, R)
    with open(os.path.join(outdir, 'sections.json'), 'w') as f:
        json.dump(dict(rate=R, seed=rng_seed, total=len(x) / R, sections=sections), f)

    # ---- the phone's test sound, for the handheld's microphone (48 kHz) ----
    P = 48000
    ph = [np.zeros(P // 2), chirp(1000, 4000, 0.3, rate=P, amp=0.7), np.zeros(P // 4)]
    # a slow logarithmic sweep 100 Hz - 23 kHz over 8 s
    n = 8 * P
    t = np.arange(n) / P
    f0, f1 = 100.0, 23000.0
    k = np.log(f1 / f0)
    ph.append(0.7 * np.sin(2 * np.pi * f0 * 8 / k * (np.exp(t * k / 8) - 1)) * fade(n, P))
    ph.append(np.zeros(P // 4))
    for f in [1000, 2000, 4000, 6000, 8000, 10000, 12000, 14000, 16000, 17000, 18000, 19000, 20000, 21000, 22000]:
        ph.append(0.7 * np.sin(2 * np.pi * f * np.arange(int(0.4 * P)) / P) * fade(int(0.4 * P), P))
        ph.append(np.zeros(int(0.1 * P)))
    xo, odata, ofreqs, nfft, ncp = ofdm(1500, 100, 48, 10, 2.5, 160, rng_seed + 99, rate=P, peak=0.7)
    ph.append(xo)
    ph.append(np.zeros(P // 4))
    ph.append(chirp(1000, 4000, 0.3, rate=P, amp=0.7))
    ph.append(np.zeros(P // 2))
    y = np.concatenate(ph)
    wav16(os.path.join(outdir, 'phone-test.wav'), y, P)
    with open(os.path.join(outdir, 'phone-test.json'), 'w') as f:
        json.dump(dict(rate=P, total=len(y) / P, ofdm=dict(freqs=ofreqs, nfft=nfft, ncp=ncp, data=odata)), f)
    print('turbotest.wav %.1f s, phone-test.wav %.1f s' % (len(x) / R, len(y) / P))
    for s in sections:
        print('  %5.2f s  %-5s %s' % (s['start'], s['name'], s['label']))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
