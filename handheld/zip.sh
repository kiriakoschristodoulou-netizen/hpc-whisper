#!/bin/bash
# usage: ./zip.sh   ->  HPC-Whisper-12.zip with the folder HPC-Whisper (build first: ./build.sh whisper.pas)
set -e
rm -rf HPC-Whisper HPC-Whisper-12.zip
mkdir HPC-Whisper
cp whisper.exe HPC-Whisper/HPCWhisper.exe
cp README.txt HPC-Whisper/README.txt
cp ../LICENSE.txt HPC-Whisper/LICENSE.txt
zip -qr HPC-Whisper-12.zip HPC-Whisper
rm -rf HPC-Whisper
ls -l HPC-Whisper-12.zip
