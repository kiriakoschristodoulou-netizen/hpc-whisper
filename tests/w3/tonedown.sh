#!/bin/bash
# Tones down (docs/FORMAT3.md, section 9): the phone's tone frames (Java) read by the handheld's tone receiver (Pascal),
# directly and through the room into the handheld's sound chip, for several lengths, loudnesses and noises.
cd "$(dirname "$0")"
T=${TMPDIR:-/tmp}/w3td; mkdir -p $T
J="java -cp cls W3Tool"; P=./linux/w3tool
pass=0; total=0
check() { total=$((total+1)); if grep -q "^msg $2 $3 [-0-9]* [0-9]* $4\$" <<<"$5"; then pass=$((pass+1)); echo "ok    $1"; else echo "FAIL  $1: $(grep -E 'frames' <<<"$5")"; fi; }
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
done
echo "$pass of $total"
[ $pass -eq $total ]
