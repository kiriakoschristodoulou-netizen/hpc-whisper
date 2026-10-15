#!/usr/bin/env python3
"""HPC Whisper Turbo test: what the handheld's microphone heard of phone-test.wav.
usage: analyze_mic.py mictest.wav phone-test.json"""
import json, sys
import numpy as np
from scipy.signal import fftconvolve, resample
from analyze import load, chirp, find


def main(rec, info):
    I = json.load(open(info))
    x, rate = load(rec)
    print('recording: %.1f s at %d samples/s; loudest %.2f of full scale' % (len(x) / rate, rate, np.max(np.abs(x))))
    if np.max(np.abs(x)) < 0.002:
        print('Nothing was heard: the microphone may be off, or the phone too quiet.')
        return
    x = x - np.mean(x)
    print('clipped samples (the recording was too loud where these are): %d' % int(np.sum(np.abs(x) > 0.995)))
    ref = chirp(1000, 4000, 0.3, rate)
    # the same chirp also ends the test: look only where the whole test still fits after it
    span = I.get('span', I['total'] - 1.0 - 0.3)       # start marker to end marker (s)
    a, q = find(x, ref, 0, max(len(ref) + 1, len(x) - int((span - 2) * rate)))
    b, q2 = find(x, ref, a + int((span - 1) * rate), a + int((span + 1) * rate))
    # a handheld's sound chip may record slower or faster than it says: put that right
    k = span * rate / max(1, b - a)
    true_rate = rate / k
    print('start marker at %.2f s (match %.2f), end marker (match %.2f)' % (a / rate, q, q2))
    print('the handheld really records at about %.0f samples/s (it says %d)' % (true_rate, rate))
    if abs(k - 1) > 0.0005 and q2 > 0.2:
        x = resample(x, int(round(len(x) * k)))
        a = int(round(a * k))
    # layout of phone-test.wav (seconds after the start marker's beginning)
    sw = I.get('sweep', dict(start=0.3 + 0.25, f0=100.0, f1=23000.0, dur=8.0, log=True))
    noise = np.mean(x[max(0, a - int(0.4 * rate)):max(1, a - int(0.05 * rate))] ** 2) + 1e-12
    print('\nWHAT THE MICROPHONE HEARS (sweep), dB above the background in a 20 ms window')
    f0, f1, T = sw['f0'], sw['f1'], sw['dur']
    win = int(0.02 * rate)
    line = []
    for f in [200, 500, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 14000,
              16000, 18000, 19000, 20000, 21000, 22000]:
        if f >= rate / 2:
            line.append('%5.1f kHz: above this rate' % (f / 1000)); continue
        if not f0 <= f <= f1:
            continue
        tf = T * np.log(f / f0) / np.log(f1 / f0) if sw.get('log') else T * (f - f0) / (f1 - f0)
        c = a + int((sw['start'] + tf) * rate)
        seg = x[c - win // 2:c + win // 2]
        t = np.arange(len(seg)) / rate
        p = abs(np.sum(seg * np.exp(-2j * np.pi * f * t))) ** 2 / len(seg)
        line.append('%5.1f kHz: %+4.0f dB' % (f / 1000, 10 * np.log10(p / noise)))
    for i in range(0, len(line), 4):
        print('  ' + '   '.join(line[i:i + 4]))
    # the multi-carrier bursts: errors per carrier (carriers this recording rate cannot hold are left out)
    for o in I['bursts']:
        freqs, nfft48, ncp48, data = np.array(o['freqs']), o['nfft'], o['ncp'], np.array(o['data'])
        pe = o.get('pilot_every', 8)
        sc = rate / 48000
        nfft, ncp = int(round(nfft48 * sc)), int(round(ncp48 * sc))
        L = (nfft48 + ncp48) * sc
        best = None
        base = a + int(o['start'] * rate)
        t = np.arange(nfft) / rate
        E = np.exp(-2j * np.pi * np.outer(t, freqs))
        for off in list(range(-int(0.03 * rate), int(0.03 * rate), max(1, ncp // 6))):
            Z = []
            for j in range(data.shape[0] + 1):
                sf = base + off + j * L + ncp            # where the symbol really starts (not a whole sample)
                s0 = int(np.floor(sf))
                seg = x[s0:s0 + nfft]
                if len(seg) < nfft:
                    break
                # starting (sf - s0) samples early turns every carrier back by that much: undo it
                Z.append((seg @ E) * np.exp(2j * np.pi * freqs * (sf - s0) / rate))
            if len(Z) < data.shape[0] + 1:
                continue
            Z = np.array(Z)
            d = Z[1:] * np.conj(Z[:-1])
            d = d * np.exp(-1j * np.angle(d[:, ::pe].sum(axis=1)))[:, None]
            dec = np.mod(np.round(np.angle(d) / (np.pi / 2)), 4).astype(int)
            ang = np.angle(d * np.exp(-1j * data * np.pi / 2))
            err = (dec != data)
            score = err.mean() + 0.01 * np.mean(ang ** 2)      # fewest errors, then the cleanest timing
            if best is None or score < best[3]:
                best = (err.mean(), err.mean(axis=0), 10 * np.log10(1 / np.maximum(np.mean(ang ** 2, axis=0), 1e-6)), score)
        seg = x[base:base + int((data.shape[0] + 1) * L)]
        pk = np.max(np.abs(seg)) if len(seg) else 0
        print('\n' + o['label'] + ':  loudest %.0f %% of full scale%s' % (100 * pk, ', CLIPPED' if pk > 0.98 else ''))
        if best is None:
            print('  not found in the recording (it may have been cut short)'); continue
        usable = freqs < min(rate, true_rate) / 2 * 0.97
        _, per, snr, _ = best
        T = (nfft48 + ncp48) / 48000
        cap = sum(4 if v > 22 else 3 if v > 17 else 2 if v > 11 else 1 if v > 6 else 0 for v in snr[usable])
        print('  symbol errors %.1f %% over the %d carriers this rate can hold; with bits fitted to each carrier ~%.0f bit/s'
              % (100 * per[usable].mean(), usable.sum(), cap / T))
        out = []
        for lo in range(int(freqs[0] // 2000 * 2000), int(freqs[-1]) + 1, 2000):
            k = (freqs >= lo) & (freqs < lo + 2000) & usable
            if k.any():
                out.append('%2d-%2d kHz: %3.0f%% err, %3.0f dB' % (lo // 1000, lo // 1000 + 2, 100 * per[k].mean(), np.median(snr[k])))
        for i in range(0, len(out), 3):
            print('    ' + '   '.join(out[i:i + 3]))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
