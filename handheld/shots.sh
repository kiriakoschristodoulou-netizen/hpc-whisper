#!/bin/bash
# screenshots of the desktop build (after ./test.sh WhisperTools.pas): home, then each tool
export DISPLAY=:99
shot() { sleep 1.2; import -window root -crop 640x214+40+40 +repage "$1"; }
d=${1:-.}
shot $d/s0.png
xdotool type --delay 40 "Hello from the Jornada"; xdotool key Tab; xdotool type --delay 40 "second field"
shot $d/s1.png
for k in 2 3 4 5; do xdotool key alt+$k; shot $d/s$k.png; done
xdotool key alt+0; xdotool key Right; shot $d/s6.png
