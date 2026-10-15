#!/usr/bin/env python3
"""HPC Whisper Turbo test 2: loudness and guard gaps.

Turbo test 1 showed both directions were spoiled by overload: the handheld's
speaker distorts at full volume, and its microphone clipped. This test plays
the same kind of sound at several loudness levels, and with longer guard gaps
(room echoes were longer than 2.5 ms), so the analysis shows the best setting.

turbotest.wav  (44100 Hz, played by the handheld at full system volume, recorded by the phone)
phone-test.wav (48000 Hz, played by the phone, recorded by the handheld); every
               part comes at four levels, so one of them suits whatever volume
               the phone is set to; it also tests the silent band 19-21 kHz
               from the phone to the handheld.

Run: python3 gen2.py outdir   (writes the two sounds, sections.json, phone-test.json, sections.inc)
"""
import json, os, sys
import numpy as np
from gen import R, chirp, ofdm, wav16, rng_seed

LEVELS = [(0.5, 'full'), (0.25, 'half'), (0.125, 'quarter'), (0.0625, 'eighth')]


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

    def carriers(name, label, f0, step, ncar, ms, cp, peak, seed, pe=10, dur=1500):
        nsym = int(dur / (ms + cp))
        x, data, freqs, nfft, ncp = ofdm(f0, step, ncar, ms, cp, nsym, seed, peak=peak, pilot_every=pe)
        add(name, label, x, dict(kind='ofdm', freqs=freqs, nfft=nfft, ncp=ncp, data=data, peak=peak,
                                 pilot_every=pe, group='fast' if f0 < 10000 else 'silent'))
        gap(0.1)

    gap(0.5)
    add('sync1', 'Start marker', chirp(18000, 21500, 0.2))
    gap(0.2)
    # the speaker's response and distortion at two loudness levels
    for name, peak, label in [('ws_full', 0.5, 'Sweep, full (audible)'), ('ws_quarter', 0.125, 'Sweep, quarter (audible)')]:
        add(name, label, chirp(500, 21000, 1.5, amp=peak), dict(kind='wsweep', f0=500, f1=21000, peak=peak))
        gap(0.2)
    add('sync2', 'Marker', chirp(18000, 21500, 0.2))
    gap(0.2)
    # the fast mode at four levels (180 carriers 1-19 kHz, 20 ms symbols, 5 ms guard)
    for i, (peak, word) in enumerate(LEVELS):
        carriers('fa_' + word, 'Fast mode, %s loudness (hiss)' % word, 1000, 100, 180, 20, 5.0, peak, rng_seed + 30 + i)
    # longer guard gap, and shorter symbols, both at quarter loudness
    carriers('fb_guard10', 'Fast mode, 10 ms guard (hiss)', 1000, 100, 180, 20, 10.0, 0.125, rng_seed + 35)
    carriers('fb_short', 'Fast mode, short symbols (hiss)', 1000, 100, 180, 10, 2.5, 0.125, rng_seed + 36)
    # the silent mode: 16 carriers 200 Hz apart, as before and with longer symbols
    carriers('s_10ms', 'Silent: 16 carriers, 10 ms', 18200, 200, 16, 10, 2.5, 0.5, rng_seed + 37, pe=8)
    carriers('s_20ms', 'Silent: 16 carriers, 20 ms', 18200, 200, 16, 20, 5.0, 0.5, rng_seed + 38, pe=8)
    add('sync3', 'End marker', chirp(18000, 21500, 0.2))
    gap(0.5)
    x = np.concatenate(parts)
    wav16(os.path.join(outdir, 'turbotest.wav'), x, R)
    with open(os.path.join(outdir, 'sections.json'), 'w') as f:
        json.dump(dict(rate=R, seed=rng_seed, version=2, total=len(x) / R, sections=sections), f)
    with open(os.path.join(outdir, 'sections.inc'), 'w') as f:
        f.write('{ the sections of turbotest.wav: start (ms) and what to show; made by gen2.py }\nconst\n')
        f.write('  NSEC = %d;\n' % len(sections))
        f.write('  SEC_MS: array[0..NSEC - 1] of LongInt = (%s);\n'
                % ', '.join(str(int(round(s['start'] * 1000))) for s in sections))
        f.write('  SEC_NAME: array[0..NSEC - 1] of UnicodeString = (\n')
        f.write(',\n'.join("    '%s'" % s['label'] for s in sections) + ');\n')
        f.write('  TEST_MS = %d;\n' % int(round(len(x) / R * 1000)))

    # ---- the phone's sound, for the handheld's microphone (48 kHz) ----
    P = 48000
    ph = [np.zeros(P // 2)]
    mark = chirp(1000, 4000, 0.3, rate=P, amp=0.7)
    ph += [mark, np.zeros(P // 4)]

    def here():                                    # seconds after the start marker began
        return sum(len(p) for p in ph) / P - 0.5

    sweep = dict(start=here(), f0=300, f1=21500, dur=2.0, peak=0.17, log=False)
    ph.append(chirp(300, 21500, 2.0, rate=P, amp=0.17))
    ph.append(np.zeros(P // 4))
    bursts = []

    def burst(label, f0, step, ncar, ms, cp, peak, seed, pe=10, dur=1500):
        nsym = int(dur / (ms + cp))
        xo, odata, ofreqs, nfft, ncp = ofdm(f0, step, ncar, ms, cp, nsym, seed, rate=P, peak=peak, pilot_every=pe)
        bursts.append(dict(label=label, start=here(), freqs=ofreqs, nfft=nfft, ncp=ncp, data=odata,
                           pilot_every=pe, peak=peak))
        ph.append(xo)
        ph.append(np.zeros(P // 10))

    # where the handheld's microphone hears well: 0.5-12 kHz, 115 carriers
    for i, (peak, word) in enumerate([(0.7, 'full'), (0.35, 'half'), (0.17, 'quarter'), (0.08, 'eighth')]):
        burst('Fast mode 0.5-12 kHz, %s loudness' % word, 500, 100, 115, 20, 5.0, peak, rng_seed + 60 + i)
    burst('Fast mode 0.5-12 kHz, 10 ms guard, quarter', 500, 100, 115, 20, 10.0, 0.17, rng_seed + 65)
    burst('Fast mode 0.5-12 kHz, short symbols, quarter', 500, 100, 115, 10, 2.5, 0.17, rng_seed + 66)
    # the silent band back to the handheld: 10 carriers 200 Hz apart, 19.0-20.8 kHz
    for i, (peak, word) in enumerate([(0.7, 'full'), (0.35, 'half'), (0.17, 'quarter')]):
        burst('Silent 19-21 kHz, %s loudness' % word, 19000, 200, 10, 20, 5.0, peak, rng_seed + 70 + i, pe=5)
    ph.append(np.zeros(P // 4))
    end_at = here()
    ph += [mark, np.zeros(P // 2)]
    y = np.concatenate(ph)
    wav16(os.path.join(outdir, 'phone-test.wav'), y, P)
    with open(os.path.join(outdir, 'phone-test.json'), 'w') as f:
        json.dump(dict(rate=P, version=2, total=len(y) / P, span=end_at, sweep=sweep, bursts=bursts), f)
    print('turbotest.wav %.1f s, phone-test.wav %.1f s' % (len(x) / R, len(y) / P))
    for s in sections:
        print('  %5.2f s  %-11s %s' % (s['start'], s['name'], s['label']))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
