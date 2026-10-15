{ the sections of turbotest.wav: start (ms) and what to show; made by gen2.py }
const
  NSEC = 13;
  SEC_MS: array[0..NSEC - 1] of LongInt = (500, 900, 2600, 4300, 4700, 6325, 7951, 9576, 11201, 12832, 14445, 16058, 17683);
  SEC_NAME: array[0..NSEC - 1] of UnicodeString = (
    'Start marker',
    'Sweep, full (audible)',
    'Sweep, quarter (audible)',
    'Marker',
    'Fast mode, full loudness (hiss)',
    'Fast mode, half loudness (hiss)',
    'Fast mode, quarter loudness (hiss)',
    'Fast mode, eighth loudness (hiss)',
    'Fast mode, 10 ms guard (hiss)',
    'Fast mode, short symbols (hiss)',
    'Silent: 16 carriers, 10 ms',
    'Silent: 16 carriers, 20 ms',
    'End marker');
  TEST_MS = 18383;
