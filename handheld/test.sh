#!/bin/bash
# usage: ./test.sh app.pas [shot.png]   -> builds for desktop Windows, runs it under Wine, takes a screenshot
J=${J720:-$HOME/j720}; F=$J/fpc/lib/fpc/3.2.2
n=${1%.pas}; shot=${2:-shot.png}
export WINEPREFIX=$J/wineprefix WINEDEBUG=-all DISPLAY=:99
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 800x400x24 >/dev/null 2>&1 & sleep 1; }
wineserver -k 2>/dev/null; sleep 0.5       # stops the previous run. Do NOT use "pkill -f name.exe".
mkdir -p w64
$F/ppcrossx64 -Twin64 -Fu"$F/units/x86_64-win64/*" -FEw64 -ow64/$n.exe -O2 $n.pas | grep -E "(Error|Fatal):" && exit 1
(nohup wine w64/$n.exe >/dev/null 2>&1 &)
# wait until the window has really been drawn (the first start of Wine is slow)
for i in $(seq 1 60); do
  sleep 0.5; import -window root /tmp/j720probe.png 2>/dev/null
  m=$(convert /tmp/j720probe.png -crop 640x214+40+40 -format "%[fx:mean]" info: 2>/dev/null)
  [ "$(echo "$m > 0.3" | bc -l 2>/dev/null)" = 1 ] && break
done
import -window root -crop 640x214+40+40 +repage $shot
echo "running; screenshot in $shot"
