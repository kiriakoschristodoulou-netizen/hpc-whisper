# Format 3 modem tests

- `cross.sh`: the handheld's modem (Pascal, `handheld/w3*.pas`, built for Linux as `linux/w3tool`)
  and the phone's (Java, `android/.../w3`) read each other's frames, directly and through a
  simulated room (the Jornada's ghost tones, echoes, noise, the phone's clock, and the Jornada's
  microphone delivering 43,229.6 samples/s while saying 44,100).
- `PosScan.java CH`: frames started at 57 different sample positions (timing must not depend on luck).
- `LongTest.java`: frames of 1-2 KB (up to 940 symbols): the drift follower over long frames.
- `Sim.java`: every channel with a link check (TRAIN, then a measured bit map) at three noise levels.
- `RsTest.java`, `Loop.java`, `RsmTest.java`: error correction, a clean loop, the rate converter.
- `TextTest.java` with `texttool.pas`: the handheld types text with keys (Tab, Ctrl+C, Backspace after a
  key, Send); the phone's TextLink rebuilds it, finds the keys, and its answer confirms everything.
- `FileTest.java` and `filetest.pas`: file transfer, sender and receiver, over links losing up to 40 % of
  packets and 30 % of answers, and with no answers at all (the same cases in Java and in Pascal).
- `ScreenTest.java`: the remote's screen in each view, sent as tiles and rebuilt exactly; a small change
  costs a few hundred bytes.
- `ScreenDump.java` and `AdpcmTest.java` with `mediatest.pas`: the handheld decodes the phone's SCREEN
  messages pixel for pixel, and its WAV player decodes the phone's ADPCM (checked against ffmpeg too).

Build and run: see the "Format 3" step in `.github/workflows/android.yml` (every push runs them).
The handheld's tables (`handheld/w3tab.inc`) are made by `handheld/gen-tables.py`.
