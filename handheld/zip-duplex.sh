#!/bin/bash
# usage: ./zip-duplex.sh  ->  Duplex-Test-10.zip with the folder Duplex-Test (build first: ./build.sh duplex.pas)
set -e
rm -rf Duplex-Test Duplex-Test-10.zip
mkdir Duplex-Test
cp duplex.exe Duplex-Test/DuplexTest.exe
cp Duplex-README.txt Duplex-Test/README.txt
zip -qr Duplex-Test-10.zip Duplex-Test
rm -rf Duplex-Test
ls -l Duplex-Test-10.zip
