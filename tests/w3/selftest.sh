#!/bin/bash
# The self test: the handheld's pieces (Pascal, wtest.pas) and the phone's (Java, SelfTest.java) agree.
cd "$(dirname "$0")"
T=${TMPDIR:-/tmp}/w3self; rm -rf $T; mkdir -p $T
for i in 0 1 2 3 4; do ./linux/selftool tones $i 42 44100 $T/t$i.wav; done
./linux/selftool report 5 3 1 44100 $T/report.wav
./linux/selftool payload 42 10 2 $T/p.bin
[ "$(./linux/selftool check $T/p.bin)" = ok ] && echo "ok    the handheld passes its own test frame" || { echo "FAIL  the handheld's check"; exit 1; }
java -cp ${CLS:-cls} SelfToolTest $T 2>&1 | grep -v Picked
exit ${PIPESTATUS[0]}
