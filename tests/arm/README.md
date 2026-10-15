# What listening costs the Jornada

`run.sh` builds `cost.pas` as ARMv4 code (the same compiler and code as the handheld program, for
ARM Linux) and counts the instructions it executes under qemu. The device's speed comes from the
J720 Probe: 6,556,291 integer steps a second, each about 15 ARM instructions here, so about 98
million instructions a second. `TONE=300 ./run.sh` adds a steady 20 kHz tone.

Needs: `qemu-user`, `binutils-arm-linux-gnueabi`, and Free Pascal's RTL built for arm-linux
(`make all OS_TARGET=linux CPU_TARGET=arm` in the RTL source with the cross compiler).

15 October 2026, HPC Whisper 3.0 as released: rate converter 41 %, silent receiver 133 %, fast receiver
59 % of the processor; the device fell behind (its microphone seemed to run at 25,500 samples/s) and
froze. After the rework (Whisper Tools 3.2): 15 %, 17 %, 18 %, and the fast receiver listens only when
something fast is expected.
