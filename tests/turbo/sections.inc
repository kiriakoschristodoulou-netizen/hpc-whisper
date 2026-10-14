{ the sections of turbotest.wav: start (ms) and what to show; made by gen.py }
const
  NSEC = 16;
  SEC_MS: array[0..NSEC - 1] of LongInt = (500, 900, 4200, 4600, 5900, 7200, 8500, 10113, 11726, 13351, 14964, 16577, 19277, 20889, 22502, 24127);
  SEC_NAME: array[0..NSEC - 1] of UnicodeString = (
    'Start marker',
    'Sweep 17.5-21.9 kHz',
    'Marker',
    'Multi-tone 4 of 36, 20 ms',
    'Multi-tone 3 of 18, 10 ms',
    'Multi-tone 8 of 36, 20 ms',
    'OFDM 32 carriers, 10 ms',
    'OFDM 16 carriers 200 Hz apart',
    'OFDM 32 carriers, 20 ms',
    'OFDM 32 carriers, quiet',
    'OFDM 32 carriers, LOUD: listen!',
    'Fast mode: sweep 0.5-21 kHz (audible)',
    'Fast mode: 180 carriers 1-19 kHz (hiss)',
    'Fast mode: 90 carriers 200 Hz apart (hiss)',
    'Fast mode: 180 carriers, 20 ms (hiss)',
    'End marker');
  TEST_MS = 24827;
