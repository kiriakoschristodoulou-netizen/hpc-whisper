#!/bin/bash
# usage: ./zip-scan.sh   ->  Mic-Scan-10.zip with the folder Mic-Scan (build first: ./build.sh micscan.pas)
set -e
rm -rf Mic-Scan Mic-Scan-10.zip
mkdir Mic-Scan
cp micscan.exe Mic-Scan/MicScan.exe
cp MicScan-README.txt Mic-Scan/README.txt
zip -qr Mic-Scan-10.zip Mic-Scan
rm -rf Mic-Scan
ls -l Mic-Scan-10.zip
