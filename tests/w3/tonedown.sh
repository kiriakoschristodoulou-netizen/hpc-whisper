#!/bin/bash
# Tones down (docs/FORMAT3.md, section 9): the phone's tone frames (Java) read by the handheld's tone receiver (Pascal),
# directly and through the room into the handheld's sound chip, for several lengths, loudnesses and noises, and with the
# microphone's rate wrong by up to 2 %: the pilot at the start of a frame measures how far, to better than 0.02 %.
cd "$(dirname "$0")"
T=${TMPDIR:-/tmp}/w3td; mkdir -p $T
J="java -cp cls W3Tool"; P=./linux/w3tool
pass=0; total=0
check() { total=$((total+1)); if grep -q "^msg $2 $3 [-0-9]* [0-9]* $4\$" <<<"$5"; then pass=$((pass+1)); echo "ok    $1"; else echo "FAIL  $1: $(grep -E 'frames' <<<"$5")"; fi; }
# eps: the measured stretch against what it should be (the assumed rate over the real one, in ppm)
epscheck() { total=$((total+1)); got=$(grep -o 'eps -\?[0-9]*' <<<"$2" | awk '{print $2}'); ok=$(python3 -c "print(1 if abs($got-($1))<=200 else 0)"); if [ "$ok" = 1 ]; then pass=$((pass+1)); echo "ok    $3: measured $got ppm (wanted $1)"; else echo "FAIL  $3: measured $got ppm, wanted $1"; fi; }
for len in 1 4 24 60; do
  head -c $len /dev/urandom > $T/pl.bin
  hex=$(od -An -v -tx1 $T/pl.bin | tr -d ' \n')
  for lv in 0.5 0.1; do
    $J ttx 2 $T/pl.bin $T/a.wav 51200 $lv 2>/dev/null
    check "len $len level $lv direct" 2 $len "$hex" "$($P trx 0 $T/a.wav 5120000)"
    $J ttx 2 $T/pl.bin $T/b.wav 48000 $lv 2>/dev/null
    for nz in 0.002 0.02; do
      $J down $T/b.wav $T/c.wav $nz 2>/dev/null
      check "len $len level $lv noise $nz room" 2 $len "$hex" "$($P trx 0 $T/c.wav 4322960)"
    done
  done
  # the rate the handheld uses is wrong: 44,100 for a chip of 43,229.6 (+2.01 %), and two others
  $J ttx 2 $T/pl.bin $T/b.wav 48000 0.3 2>/dev/null; $J down $T/b.wav $T/c.wav 0.005 2>/dev/null
  for rate in 4410000 4366000 4250000; do
    out="$($P trx 0 $T/c.wav $rate)"
    check "len $len assumed rate $rate" 2 $len "$hex" "$out"
    epscheck "$(python3 -c "print(round($rate/4322960*1e6-1e6))")" "$out" "len $len assumed rate $rate"
  done
done
# the microphone's constant offset (850 of 32,768 on the Jornada) and a loud 2 kHz beep (Pair's marker) must neither
# hide a frame nor pass for a pilot
head -c 24 /dev/urandom > $T/pl.bin; hex=$(od -An -v -tx1 $T/pl.bin | tr -d ' \n')
$J ttx 2 $T/pl.bin $T/b.wav 48000 0.2 2>/dev/null; $J down $T/b.wav $T/c.wav 0.005 2>/dev/null
python3 - $T/c.wav $T/d.wav $T/e.wav <<'P'
import sys, wave, math, array
w = wave.open(sys.argv[1]); r = w.getframerate(); d = array.array('h'); d.frombytes(w.readframes(w.getnframes()))
def clip(v): return -32768 if v < -32768 else 32767 if v > 32767 else int(v)
def put(f, x):
    o = wave.open(f, 'wb'); o.setnchannels(1); o.setsampwidth(2); o.setframerate(r); o.writeframes(array.array('h', [clip(v) for v in x]).tobytes()); o.close()
put(sys.argv[2], [v + 850 for v in d])
def beep(i):
    t = i / r
    return 14000 * math.sin(2 * math.pi * 2000 * t) if 0.3 < t < 0.9 else 0       # before the frame
put(sys.argv[3], [v + beep(i) + 850 for i, v in enumerate(d)])
P
check "offset of 850" 2 24 "$hex" "$($P trx 0 $T/d.wav 4322960)"
check "offset of 850 and a loud 2 kHz beep before it" 2 24 "$hex" "$($P trx 0 $T/e.wav 4322960)"
# a recording of a real room (the self test of 3.9.0 and 3.9.1): no pilot, no frame
for f in live-390.wav live-sound-390.wav live-heard-391.wav; do
  total=$((total+1)); out="$($P trx 0 $f 4410000)"
  if grep -q "frames 0 fails 0 .*starts 0 " <<<"$out"; then pass=$((pass+1)); echo "ok    $f: nothing taken for a tone frame"; else echo "FAIL  $f: $(grep frames <<<"$out")"; fi
done
echo "$pass of $total"
[ $pass -eq $total ]
