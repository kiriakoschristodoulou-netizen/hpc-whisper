{ the sections of turbotest.wav: start (ms) and what to show; made by gen.py }
const
  NSEC = 13;
  SEC_MS: array[0..NSEC - 1] of LongInt = (500, 900, 4200, 4600, 6300, 8000, 9700, 11400, 13511, 15623, 17747, 19858, 21970);
  SEC_NAME: array[0..NSEC - 1] of UnicodeString = (
    'Start marker',
    'Sweep 17.5-21.9 kHz',
    'Marker',
    'Multi-tone 4 of 36, 20 ms',
    'Multi-tone 6 of 36, 10 ms',
    'Multi-tone 3 of 18, 10 ms',
    'Multi-tone 8 of 36, 20 ms',
    'OFDM 32 carriers, 10 ms',
    'OFDM 16 carriers 200 Hz apart',
    'OFDM 32 carriers, 20 ms',
    'OFDM 32 carriers, quiet',
    'OFDM 32 carriers, LOUD: listen!',
    'End marker');
  TEST_MS = 22670;
