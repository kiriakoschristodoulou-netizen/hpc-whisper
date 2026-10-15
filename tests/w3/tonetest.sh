#!/bin/bash
# A steady 20 kHz tone (some phones make one) must not blind the silent receivers: frames with a tone
# 20 and 30 dB below them, plus noise, read by the handheld's and the phone's receivers. (A tone as loud
# as a carrier, right on it, spoils that carrier: that would need the tone subtracted.)
cd "$(dirname "$0")"
T=${TMPDIR:-/tmp}/w3tone; mkdir -p $T
P=./linux/w3tool; J="java -cp cls W3Tool"
pass=0; total=0
for ch in 0 1 2; do
  for db in -30 -20; do
    head -c 40 /dev/urandom > $T/pl.bin
    hex=$(od -An -v -tx1 $T/pl.bin | tr -d ' \n')
    # five frames a second apart, then the tone and noise over all of it
    python3 - "$ch" "$db" "$T" <<'PY'
import sys, wave, subprocess, numpy as np
ch, db, T = sys.argv[1], float(sys.argv[2]), sys.argv[3]
subprocess.run(['./linux/w3tool','tx',ch,'1',T+'/pl.bin',T+'/f.wav','51'],check=True)
w=wave.open(T+'/f.wav'); r=w.getframerate(); f=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(float)
x=np.zeros(r*6)
for k in range(5): x[int(r*(0.5+k))+np.arange(len(f))]+=f
rms=f.std(); i=np.arange(len(x))
x+=np.sqrt(2)*rms*10**(db/20)*np.sin(2*np.pi*19999.8*i/r+0.3)
x+=np.random.default_rng(1).normal(0,rms*0.05,len(x))
o=wave.open(T+'/t.wav','wb'); o.setnchannels(1); o.setsampwidth(2); o.setframerate(r); o.writeframes(np.clip(x,-32767,32767).astype(np.int16).tobytes())
PY
    for side in handheld phone; do
      if [ $side = handheld ]; then out=$($P rx $ch $T/t.wav 5120000); else out=$($J rx $ch $T/t.wav 2>/dev/null); fi
      n=$(grep -c "^msg 1 [0-9]* [-0-9]* [0-9]* $hex\$" <<<"$out")
      total=$((total+1)); [ "$n" -ge 4 ] && pass=$((pass+1))
      printf "%-5s ch%s tone %+3s dB: %s read %s of 5  (%s)\n" "$([ "$n" -ge 4 ] && echo ok || echo FAIL)" $ch $db $side $n "$(grep frames <<<"$out")"
    done
  done
done
echo "$pass of $total"
[ $pass = $total ]
