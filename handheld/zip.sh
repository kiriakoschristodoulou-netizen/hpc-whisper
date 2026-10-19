#!/bin/bash
# usage: ./zip.sh   ->  HPC-Whisper-40.zip with the folder HPC-Whisper (build first: ./build.sh whisper.pas)
set -e
rm -rf HPC-Whisper HPC-Whisper-40.zip
mkdir HPC-Whisper
cp whisper.exe HPC-Whisper/HPCWhisper.exe
cp README.txt HPC-Whisper/README.txt
zip -qr HPC-Whisper-40.zip HPC-Whisper
rm -rf HPC-Whisper
ls -l HPC-Whisper-40.zip
