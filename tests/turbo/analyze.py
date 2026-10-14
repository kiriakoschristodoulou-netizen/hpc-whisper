#!/usr/bin/env python3
"""HPC Whisper Turbo test: what a recording of turbotest.wav says.

usage: analyze.py recording.wav sections.json

Finds the markers, corrects for the two devices' clocks, and reports:
- the band's response and the handheld's ghost tones (from the sweep);
- for each multi-tone section: how often each symbol's whole set of tones
  was read right, and the resulting data rate;
- for each OFDM section: errors per carrier, the signal-to-noise ratio
  per carrier, and the data rate those carriers could carry.
"""
import json, os, sys
import numpy as np
from scipy.signal import resample_poly, fftconvolve, resample
from math import comb, log2

R = 44100


def load(path):
    import wave
    with wave.open(path) as w:
        rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        x = np.frombuffer(w.readframes(n), dtype='<i2').astype(float) / 32768
    if ch > 1:
        x = x.reshape(-1, ch)[:, 0]
    return x, rate


def chirp(f0, f1, dur, rate):
    n = int(dur * rate)
    t = np.arange(n) / rate
    return np.sin(2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * dur)))


def find(x, ref, lo, hi):
    """best match of ref in x[lo:hi] (sample index)"""
    lo, hi = max(0, lo), min(len(x), hi)
    seg = x[lo:hi]
    c = np.abs(fftconvolve(seg, ref[::-1], mode='valid'))
    return lo + int(np.argmax(c)), float(np.max(c) / (np.linalg.norm(ref) * np.sqrt(np.mean(seg ** 2) * len(ref)) + 1e-12))


def peak(x, ref, lo, hi):
    """best match of ref in x[lo:hi], and how far the peak stands above the rest"""
    lo, hi = max(0, lo), min(len(x), hi)
    c = np.abs(fftconvolve(x[lo:hi], ref[::-1], mode='valid'))
    k = int(np.argmax(c))
    return lo + k, float(c[k] / (np.median(c) + 1e-12))


def tone_power(x, a, b, f, rate=R):
    t = np.arange(a, b) / rate
    z = np.sum(x[a:b] * np.exp(-2j * np.pi * f * t))
    return abs(z) ** 2


def main(rec, secfile):
    S = json.load(open(secfile))
    sec = {s['name']: s for s in S['sections']}
    x, rate = load(rec)
    if rate != R:
        g = np.gcd(rate, R)
        x = resample_poly(x, R // g, rate // g)
    # the test sound itself, to line each part of the recording up with it
    ref_wav = os.path.join(os.path.dirname(os.path.abspath(secfile)), 'turbotest.wav')
    T, _ = load(ref_wav)
    ref = chirp(18000, 21500, 0.2, R)
    want = int((sec['sync3']['start'] - sec['sync1']['start']) * R)
    a, q1 = find(x, ref, 0, max(len(ref) + 1, len(x) - want + int(0.3 * R)))
    print('start marker at %.2f s in the recording (match %.2f)' % (a / R, q1))
    if q1 < 0.3:
        print('WARNING: the start marker is weak; the results below may be meaningless.')
    # each part is found on its own (start and end), so a pause in the playback
    # or a difference between the two clocks spoils nothing
    shift = a - int(sec['sync1']['start'] * R)        # recording index minus test index
    parts, notes, scales = {}, [], []
    for s in S['sections']:
        s0, n = int(round(s['start'] * R)), int(round(s['dur'] * R))
        pad = int(0.15 * R)
        m = min(int(0.25 * R), n // 2)
        p0, qa = peak(x, T[s0:s0 + m], s0 + shift - int(0.4 * R), s0 + shift + m + int(0.4 * R))
        p1, qb = peak(x, T[s0 + n - m:s0 + n], p0 + n - m - int(0.2 * R), p0 + n + int(0.2 * R))
        late = (p1 - p0) - (n - m)
        jumped = False
        if qa < 6:
            notes.append('%s: not found clearly (%.0f)' % (s['name'], qa))
            p0 = s0 + shift
        if abs(late) > 0.002 * n + 40 and qb > 6:
            notes.append('%s: the sound paused or jumped for %+.0f ms inside this part' % (s['name'], 1000 * late / R))
            late, jumped = 0, True                      # keep the start's timing
        scale = (n - m + late) / (n - m)
        if qa > 6 and qb > 6 and not jumped and n > R:
            scales.append(scale)
        lo, hi = p0 - int(pad * scale), p0 + int((n + pad) * scale)
        seg = x[max(0, lo):hi]
        if lo < 0:
            seg = np.concatenate([np.zeros(-lo), seg])
        y = resample(seg, n + 2 * pad) if abs(scale - 1) > 1e-6 else seg[:n + 2 * pad]
        parts[s['name']] = (y, pad)
        shift = p0 - s0 + int(n * (scale - 1))
    if scales:
        print('the two clocks differ by about %+.0f ppm' % ((np.median(scales) - 1) * 1e6))
    print('gaps or jumps in the sound: ' + ('none' if not notes else ''))
    for t in notes:
        print('  ' + t)

    def part(name):
        """the recording of one part, lined up: (samples, index of the part's start)"""
        return parts[name]

    y0, pad0 = part('sync1')
    noise = np.mean(y0[:pad0 - int(0.05 * R)] ** 2) if pad0 > int(0.05 * R) else 1e-12

    # ---- sweep: response and ghosts ----
    sw = sec['sweep']
    yS, padS = part('sweep')
    print('\nBAND RESPONSE (sweep), 100 Hz steps, dB relative to the strongest; ghosts at fixed distances')
    resp, ghosts = {}, {}
    win = int(0.02 * R)
    for i in range(40, int(sw['dur'] * 50) - 40):
        tc = sw['start'] + i / 50
        f = sw['f0'] + (sw['f1'] - sw['f0']) * (tc - sw['start']) / sw['dur']
        c = padS + int(round((tc - sw['start']) * R))
        p0 = tone_power(yS, c - win // 2, c + win // 2, f)
        fb = int(round(f / 100) * 100)
        resp.setdefault(fb, []).append(p0)
        for d in range(-3000, 3001, 100):
            if d == 0 or abs(d) < 300:
                continue
            pd = tone_power(yS, c - win // 2, c + win // 2, f + d)
            ghosts.setdefault(d, []).append(pd / (p0 + 1e-20))
    top = max(np.median(v) for v in resp.values())
    line = []
    for fb in sorted(resp):
        if 17500 <= fb <= 21900 and fb % 200 == 0:
            line.append('%5.1f:%+4.0f' % (fb / 1000, 10 * np.log10(np.median(resp[fb]) / top + 1e-12)))
    for i in range(0, len(line), 6):
        print('  ' + '  '.join(line[i:i + 6]))
    gl = sorted(((10 * np.log10(np.median(v) + 1e-12), d) for d, v in ghosts.items()), reverse=True)[:5]
    print('  strongest ghosts: ' + ', '.join('%+d Hz at %+.0f dB' % (d, db) for db, d in gl))
    snr_band = 10 * np.log10(top / (noise * win + 1e-20))
    print('  tone vs background (20 ms window): %.0f dB' % snr_band)

    # ---- multi-tone ----
    print('\nMULTI-TONE (several tones at once)')
    for name in ['m1', 'm2', 'm3', 'm4']:
        s = sec[name]
        y, pad = part(name)
        grid, k, ms = np.array(s['grid']), s['k'], s['sym_ms']
        ns = int(R * ms / 1000)
        ok = 0; tone_err = 0
        for j, st in enumerate(s['sets']):
            c0 = pad + j * ns
            a1, b1 = c0 + int(ns * 0.2), c0 + int(ns * 0.95)
            p = np.array([tone_power(y, a1, b1, f) for f in grid])
            got = set(np.argsort(p)[-k:].tolist())
            want_s = set(st)
            if got == want_s:
                ok += 1
            tone_err += len(want_s - got)
        n = len(s['sets'])
        bits = log2(comb(len(grid), k))
        ser = 1 - ok / n
        print('  %-34s symbols right %5.1f %%  -> %4.1f bits per symbol, raw %5.0f bit/s, usable ~%5.0f bit/s'
              % (s['label'], 100 * ok / n, bits, bits * 1000 / ms, bits * 1000 / ms * max(0.0, 1 - 2.5 * ser)))

    # ---- OFDM ----
    print('\nOFDM (many carriers, phase coded)')
    for name in ['o1', 'o2', 'o3', 'o4', 'o5']:
        s = sec[name]
        y, pad = part(name)
        freqs, nfft, ncp = np.array(s['freqs']), s['nfft'], s['ncp']
        data = np.array(s['data'])
        nsym = data.shape[0]
        L = nfft + ncp
        best = None
        for off in range(-ncp // 2, ncp // 2 + 1, max(1, ncp // 8)):
            Z = []
            for j in range(nsym + 1):
                a1 = pad + j * L + ncp + off
                t = np.arange(nfft) / R                  # time within the symbol, as when it was made
                seg = y[a1:a1 + nfft]
                Z.append(np.array([np.sum(seg * np.exp(-2j * np.pi * f * t)) for f in freqs]))
            Z = np.array(Z)
            d = Z[1:] * np.conj(Z[:-1])
            # the pilots (every 8th carrier) show the common phase drift per symbol
            pil = d[:, ::8].sum(axis=1)
            d = d * np.exp(-1j * np.angle(pil))[:, None]
            dec = np.mod(np.round(np.angle(d) / (np.pi / 2)), 4).astype(int)
            errs = (dec != data)
            # per carrier SNR from the spread of the phase differences
            ang = np.angle(d * np.exp(-1j * data * np.pi / 2))
            evm = np.mean(ang ** 2, axis=0)
            score = errs.mean()
            if best is None or score < best[0]:
                best = (score, errs, evm, off)
        score, errs, evm, off = best
        per = errs.mean(axis=0)
        snr_c = 10 * np.log10(1 / np.maximum(evm, 1e-6))   # rough: phase noise to SNR
        good = (per < 0.02).sum()
        rate_bits = 2 * len(freqs) * 1000 / ((nfft + ncp) / R * 1000)
        print('  %-34s symbol errors %5.1f %% (%d of %d carriers nearly clean) raw %5.0f bit/s'
              % (s['label'], 100 * score, good, len(freqs), rate_bits))
        worst = np.argsort(per)[-4:][::-1]
        print('     worst carriers: ' + ', '.join('%.1f kHz %.0f%%' % (freqs[w] / 1000, 100 * per[w]) for w in worst)
              + '; median phase SNR %.0f dB' % np.median(snr_c))
        # what the carriers could carry if each used only as many bits as its SNR allows
        cap = 0
        for sn in snr_c:
            bitsc = 4 if sn > 22 else 3 if sn > 17 else 2 if sn > 11 else 1 if sn > 6 else 0
            cap += bitsc
        print('     with bits fitted to each carrier: ~%5.0f bit/s before error protection' % (cap * R / (nfft + ncp)))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
