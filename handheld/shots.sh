#!/bin/bash
# screenshots of each screen of the desktop build (after ./test.sh whisper.pas)
export DISPLAY=:99
w=$(xdotool search --name "HPC Whisper" | head -1)
shot() { sleep 1.2; import -window root -crop 640x214+40+40 +repage "$1"; }
xdotool windowfocus --sync $w 2>/dev/null; xdotool windowactivate $w 2>/dev/null
xdotool type --delay 40 "Hello from the Jornada"; xdotool key Tab; xdotool type --delay 40 "second field"; xdotool key ctrl+a BackSpace
shot ${1:-.}/s1.png
for k in 2 3 4 5; do xdotool key alt+$k; shot ${1:-.}/s$k.png; done
