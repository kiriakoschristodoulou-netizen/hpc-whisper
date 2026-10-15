# Turbo test

Measures how much more the inaudible band can carry on real hardware.

- `gen2.py outdir` makes Turbo test 2 (loudness levels and guard gaps, both directions, and the
  silent band from the phone back to the handheld); the handheld program 2.0 is built with its `sections.inc`.
- `gen.py outdir` makes Turbo test 1: `turbotest.wav`, `sections.json`, `phone-test.wav`, `phone-test.json`
  (fixed seeds, so the same files every time).
- Both the silent band (18-21.5 kHz) and a fast audible mode (1-19 kHz, many carriers) are measured.
- `turbotest.pas` is the handheld program: play test, microphone test, speed test.
  `./build.sh turbotest.pas` for the handheld, `./test.sh turbotest.pas` under Wine.
  `sections.inc` is the part table from `sections.json`.
- `analyze.py recording.wav outdir/sections.json` reads the phone's recording of the play test
  (`turbotest.wav` must be next to `sections.json`). Each part is lined up on its own, so pauses
  in the playback are reported rather than spoiling the rest.
- `analyze_mic.py mictest.wav outdir/phone-test.json` reads the handheld's microphone test.
- `simulate.py turbotest.wav out.wav [native_rate] [noise] [echo]` makes a pretend recording
  (the Jornada's ghost tones, echoes, the phone's clock) to check the analyzers.
