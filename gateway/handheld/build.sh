#!/bin/bash
# usage: ./build.sh name.pas   -> name.exe or name.dll for the Jornada 720
set -e
J=${J720:-$HOME/j720}; F=$J/fpc/lib/fpc/3.2.2
export PATH=$J/tc/bin:$PATH
n=${1%.pas}
mkdir -p armu
[ -f $n.rc ] && arm-wince-windres --preprocessor=cpp --preprocessor-arg=-DRC_INVOKED $n.rc -O res -o $n.res
$F/ppcrossarm -Twince -CpARMV4 -XParm-wince- -Fu"$F/units/arm-wince/*" -Fudriver -Fi../../handheld -FUarmu -O2 -Xs -XX -CX $n.pas
out=$(ls -t $n.exe $n.dll 2>/dev/null | head -1)
bad=$(arm-wince-objdump -d $out | grep -cE "[[:space:]](bx|blx)[[:space:]]" || true)
[ "$bad" = 0 ] || { echo "ERROR: $bad bx/blx instructions in $out"; exit 1; }
arm-wince-objdump -p $out | grep -E "MajorSubsystemVersion|DLL Name"
ls -l $out
