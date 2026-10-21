Mic Scan 1.3
by Kyriakos Christodoulou (part of HPC Whisper)

Finds out how a handheld's microphone really hears sound: which
frequencies, how loud, whether the level falls while a tone goes on
(automatic gain), the real sampling rate, ghost tones and the shortest
burst it notices.

HOW
  1. Copy this folder to the handheld and run MicScan.exe.
  2. Hold the phone with its speaker 2 to 5 cm from the handheld's
     microphone, phone volume at maximum, silent mode off.
  3. Press Enter on the handheld (it records). On the phone open
     https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/scan.html
     and tap Start. The test lasts about a minute and a half; keep quiet.
  4. When the phone says Done, press Enter on the handheld. After a few
     seconds the results appear on five pages (Left and Right arrows).
  5. S types a short report to the phone (open any text field with the
     HPC Whisper keyboard). W saves micscan-report.txt and micscan.wav
     next to the program. O measures a saved micscan.wav again.

RETURN TEST (phone to handheld)
  On the first screen press T to switch from Mic scan to Return test, then
  record as above, but open return.html on the phone instead of scan.html:
  https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/return.html
  The phone plays 12 blocks of data tones (volumes 90, 45 and 22 %, symbols
  of 48, 32 and 20 ms, four frequency bands). The results show how many
  symbols of 96 were heard wrong in each block, and the report gives margins
  and how fast the automatic gain settles. S, W and O work as before; the
  recording is saved as return.wav.
