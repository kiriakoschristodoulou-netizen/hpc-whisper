#!/bin/bash
# The handheld's modem (Pascal) and the phone's (Java) read each other's frames, directly and through a simulated room.
cd "$(dirname "$0")"
T=${TMPDIR:-/tmp}/w3cross; mkdir -p $T
J="java -cp cls W3Tool"; P=./linux/w3tool
pass=0; total=0
check() { # name expected-hex output
  total=$((total+1))
  if [ -n "$2" ] && grep -q "^msg 1 [0-9]* [-0-9]* [0-9]* $2\$" <<<"$3"; then pass=$((pass+1)); echo "ok    $1"; else echo "FAIL  $1: $(grep -E 'frames' <<<"$3")"; fi
}
for ch in 0 1 2 3 4; do
  len=$([ $ch -le 2 ] && echo 40 || echo 900)
  head -c $len /dev/urandom > $T/pl.bin
  hex=$(od -An -v -tx1 $T/pl.bin | tr -d ' \n')
  # Pascal -> Pascal at the modem rate
  $P tx $ch 1 $T/pl.bin $T/a.wav 51
  check "ch$ch handheld -> handheld, direct" "$hex" "$($P rx $ch $T/a.wav 5120000)"
  # Pascal -> Java, direct (44,100)
  $P tx $ch 1 $T/pl.bin $T/b.wav
  check "ch$ch handheld -> phone, direct" "$hex" "$($J rx $ch $T/b.wav 2>/dev/null)"
  # Java -> Pascal, direct (48,000 -> resampled)
  $J tx $ch 1 $T/pl.bin $T/c.wav 51200 2>/dev/null
  check "ch$ch phone -> handheld, direct" "$hex" "$($P rx $ch $T/c.wav 5120000)"
  if [ $ch -le 1 ] || [ $ch -eq 3 ]; then
    # handheld -> phone through the chip and the room
    $J up $T/b.wav $T/d.wav 0.002 2>/dev/null
    check "ch$ch handheld -> phone, room" "$hex" "$($J rx $ch $T/d.wav 2>/dev/null)"
  else
    # phone -> handheld through the room into an ADC at 43,229.6 that says 44,100
    $J tx $ch 1 $T/pl.bin $T/e.wav 48000 2>/dev/null
    $J down $T/e.wav $T/f.wav 0.002 2>/dev/null
    check "ch$ch phone -> handheld, room" "$hex" "$($P rx $ch $T/f.wav 4322960)"
  fi
done
echo "$pass of $total"
[ $pass -eq $total ]
