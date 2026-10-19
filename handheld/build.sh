#!/bin/bash
# usage: ./build.sh app.pas     ->  app.exe for the Jornada 720
set -e
J=${J720:-$HOME/j720}                     # where the toolchain was installed
F=$J/fpc/lib/fpc/3.2.2
export PATH=$J/tc/bin:$PATH
n=${1%.pas}
mkdir -p units-arm
[ -f $n.rc ] && arm-wince-windres --preprocessor=cpp --preprocessor-arg=-DRC_INVOKED $n.rc -O res -o $n.res
$F/ppcrossarm -Twince -CpARMV4 -XParm-wince- -Fu$F/units/arm-wince/rtl -FUunits-arm -O2 -Xs -XX -CX $n.pas
# the StrongARM has no Thumb: these instructions must not appear
bad=$(arm-wince-objdump -d $n.exe | grep -cE "[[:space:]](bx|blx)[[:space:]]" || true)
[ "$bad" = 0 ] || { echo "ERROR: $bad bx/blx instructions, will crash on the Jornada"; exit 1; }
arm-wince-objdump -p $n.exe | grep -E "MajorSubsystemVersion|DLL Name"
ls -l $n.exe
