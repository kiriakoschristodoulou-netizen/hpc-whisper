#!/bin/sh
# Pascal handheld <-> Java phone frames through a simulated room.
# usage: cross.sh   (run from gateway/tests; needs lx/wavtool and the Java classes in $CLS)
CLS=${CLS:-/home/claude/gwbuild}
T=${TMPDIR:-/tmp}/wncross; mkdir -p $T
fail=0
for seed in 1 2 3 4 5 6; do
  for noise in 100 500; do
    nf=$((seed % 3 + 1))
    # handheld -> phone: Pascal makes (43.2 kHz, up band 19000), Java hears
    ./lx/wavtool make $T/up.wav 43200 19000 $nf $seed $T/up.exp
    java -cp $CLS CrossTest read $T/up.wav 43200 19000 $T/up.got $noise >/dev/null
    if cmp -s $T/up.exp $T/up.got; then echo "PASS handheld->phone seed $seed noise $noise ($nf frames)"; else echo "FAIL handheld->phone seed $seed noise $noise"; diff $T/up.exp $T/up.got | head -4; fail=1; fi
    # phone -> handheld: Java makes (48 kHz, down band 18000), Pascal hears at 43.2 kHz
    java -cp $CLS CrossTest make $T/dn.wav $T/dn.exp $nf $seed $noise
    ./lx/wavtool read $T/dn.wav 43200 18000 $T/dn.got
    if cmp -s $T/dn.exp $T/dn.got; then echo "PASS phone->handheld seed $seed noise $noise ($nf frames)"; else echo "FAIL phone->handheld seed $seed noise $noise"; diff $T/dn.exp $T/dn.got | head -4; fail=1; fi
  done
done
exit $fail
