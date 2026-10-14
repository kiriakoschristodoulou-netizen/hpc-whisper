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
    ref = chirp(1000, 4000, 0.3, rate)
    # the same chirp also ends the test: look only where the whole test still fits after it
    a, q = find(x, ref, 0, max(len(ref) + 1, len(x) - int((I['total'] - 1.2) * rate)))
    print('start marker at %.2f s (match %.2f)' % (a / rate, q))
    # layout of phone-test.wav (seconds after the start marker's beginning)
    t_sweep = 0.3 + 0.25
    noise = np.mean(x[max(0, a - int(0.4 * rate)):max(1, a - int(0.05 * rate))] ** 2) + 1e-12
    print('\nWHAT THE MICROPHONE HEARS (sweep), dB above the background in a 20 ms window')
    f0, f1, T = 100.0, 23000.0, 8.0
    k = np.log(f1 / f0)
    win = int(0.02 * rate)
    line = []
    for f in [200, 500, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 14000,
              16000, 18000, 19000, 20000, 21000, 22000]:
        if f >= rate / 2:
            line.append('%5.1f kHz: above this rate' % (f / 1000)); continue
        tf = T * np.log(f / f0) / k                       # when the sweep passes f
        c = a + int((t_sweep + tf) * rate)
        seg = x[c - win // 2:c + win // 2]
        t = np.arange(len(seg)) / rate
        p = abs(np.sum(seg * np.exp(-2j * np.pi * f * t))) ** 2 / len(seg)
        line.append('%5.1f kHz: %+4.0f dB' % (f / 1000, 10 * np.log10(p / noise)))
    for i in range(0, len(line), 4):
        print('  ' + '   '.join(line[i:i + 4]))
    # the audible multi-carrier burst: errors
    o = I['ofdm']
    freqs, nfft48, ncp48, data = np.array(o['freqs']), o['nfft'], o['ncp'], np.array(o['data'])
    t_ofdm = t_sweep + 8.0 + 0.25 + 15 * 0.5
    sc = rate / 48000
    nfft, ncp = int(round(nfft48 * sc)), int(round(ncp48 * sc))
    L = (nfft48 + ncp48) * sc
    best = None
    base = a + int(t_ofdm * rate)
    for off in range(-int(0.03 * rate), int(0.03 * rate), max(1, ncp // 6)):
        Z = []
        for j in range(data.shape[0] + 1):
            s0 = base + off + int(round(j * L)) + ncp
            seg = x[s0:s0 + nfft]
            if len(seg) < nfft:
                break
            t = np.arange(nfft) / rate
            Z.append([np.sum(seg * np.exp(-2j * np.pi * f * t)) for f in freqs])
        Z = np.array(Z)
        if len(Z) < data.shape[0] + 1:
            continue
        d = Z[1:] * np.conj(Z[:-1])
        pil = d[:, ::8].sum(axis=1)
        d = d * np.exp(-1j * np.angle(pil))[:, None]
        dec = np.mod(np.round(np.angle(d) / (np.pi / 2)), 4).astype(int)
        e = (dec != data).mean()
        if best is None or e < best:
            best = e
    if best is not None:
        print('\naudible multi-carrier burst (48 carriers, 1.5-6.2 kHz, 2 bits each): symbol errors %.1f %%' % (100 * best))
        print('  at this error rate the phone -> handheld direction could carry roughly %.0f bit/s'
              % (2 * len(freqs) / ((nfft48 + ncp48) / 48000) * max(0.0, 1 - 3 * best)))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
