#!/bin/bash
# A real recording from a phone (Samsung, 3.9.0 self test): the handheld's three silent frames must be read, with no
# rate correction at all (3.9.1: the conversion is the microphone's measured rate and nothing else moves it).
cd "$(dirname "$0")"
out=$(java -cp cls W3Tool rx 0 live-390.wav 2>/dev/null | grep -c "^msg 53 24")
if [ "$out" -ge 3 ]; then echo "ok    live recording: $out silent test frames read"; else echo "FAIL  live recording: $out of 3"; exit 1; fi
java -cp cls LiveSound live-sound-390.wav 2>&1 | grep -v Picked; [ ${PIPESTATUS[0]} -eq 0 ] || exit 1
