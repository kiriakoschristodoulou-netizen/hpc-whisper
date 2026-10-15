# Format 3 modem tests

- `cross.sh`: the handheld's modem (Pascal, `handheld/w3*.pas`, built for Linux as `linux/w3tool`)
  and the phone's (Java, `android/.../w3`) read each other's frames, directly and through a
  simulated room (the Jornada's ghost tones, echoes, noise, the phone's clock, and the Jornada's
  microphone delivering 43,229.6 samples/s while saying 44,100).
- `PosScan.java CH`: frames started at 57 different sample positions (timing must not depend on luck).
- `LongTest.java`: frames of 1-2 KB (up to 940 symbols): the drift follower over long frames.
- `Sim.java`: every channel with a link check (TRAIN, then a measured bit map) at three noise levels.
- `RsTest.java`, `Loop.java`, `RsmTest.java`: error correction, a clean loop, the rate converter.

Build: `javac -d cls ../../android/app/src/main/java/net/kyriakos/whisper/w3/*.java *.java` and
`fpc -O2 -Fu../../handheld -Fi../../handheld -FUlinux -olinux/w3tool w3tool.pas`.
The handheld's tables (`handheld/w3tab.inc`) are made by `handheld/gen-tables.py`.
