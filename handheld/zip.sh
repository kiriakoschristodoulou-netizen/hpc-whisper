#!/bin/bash
# usage: ./zip.sh   ->  HPC-Whisper-11.zip with the folder HPC-Whisper (build first: ./build.sh whisper.pas)
set -e
rm -rf HPC-Whisper HPC-Whisper-11.zip
mkdir HPC-Whisper
cp whisper.exe HPC-Whisper/HPCWhisper.exe
cp README.txt HPC-Whisper/README.txt
zip -qr HPC-Whisper-11.zip HPC-Whisper
rm -rf HPC-Whisper
ls -l HPC-Whisper-11.zip
