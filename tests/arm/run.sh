#!/bin/bash
# builds cost.pas for ARMv4 Linux and counts executed instructions under qemu: the Jornada's load for
# listening. TENTHS (default 3) of a second of sound; TONE adds a steady 20 kHz tone of that size.
cd "$(dirname "$0")"
F=/root/j720/fpc/lib/fpc/3.2.2/ppcrossarm
mkdir -p u
$F -Tlinux -CpARMV4 -CaEABI -CfSOFT -XParm-linux-gnueabi- -Fu/root/j720/fpcsrc/rtl/units/arm-linux -Fu../../handheld -Fi../../handheld -FUu -O2 -ocost cost.pas | grep -E "(Error|Fatal):"
ins() { qemu-arm -one-insn-per-tb -d nochain,exec -D /dev/stdout ./cost "$@" | grep -c "^Trace"; }
T=${TENTHS:-3}; TONE=${TONE:-0}
s9=$(ins 9 0 0); s0=$(ins 0 0 0)
b0=$(ins 0 $T $TONE); b1=$(ins 1 $T $TONE); b2=$(ins 2 $T $TONE); b3=$(ins 3 $T $TONE)
python3 - <<P
ips=($s9-$s0)/1e6*6556291; s=$T/10
for name,a,b in [("rate converter",$b0,$b1),("silent receiver",$b1,$b2),("fast receiver",$b1,$b3)]:
    print(f"{name:16s} {(b-a)/s/1e6:6.1f} M instructions a second = {100*(b-a)/s/ips:5.0f}% of the Jornada")
print(f"(the Jornada does about {ips/1e6:.0f} M instructions a second: the probe's integer step is {($s9-$s0)/1e6:.1f} instructions)")
P
