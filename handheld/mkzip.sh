#!/bin/bash
# usage: ./mkzip.sh 392   ->  Whisper-Tools-392.zip (the program, the readme and the source), no dots in the names
set -e
cd "$(dirname "$0")"
n=Whisper-Tools-$1
d=$(mktemp -d)/$n
mkdir -p $d/source/lib
cp WhisperTools.exe README.txt $d/
cp WhisperTools.pas WhisperTools.rc build.sh gen-tables.py sine.inc w3tab.inc whisper.ico w3core.pas w3dsp.pas w3tx.pas w3rx.pas \
   waudio.pas wtext.pas wfile.pas wscreen.pas wwav.pas wimg.pas winf.pas wmodem.pas wpair.pas wtest.pas wlog.pas wtone.pas $d/source/
cp ../docs/FORMAT3.md ../docs/FORMAT.md $d/source/
cp -r lib/pasjpeg $d/source/lib/
rm -f $n.zip
(cd $(dirname $d) && zip -qr $OLDPWD/$n.zip $n)
ls -l $n.zip
