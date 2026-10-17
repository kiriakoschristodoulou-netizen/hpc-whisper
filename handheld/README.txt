Whisper Tools 3.8.1
by Kyriakos Christodoulou

Type on a Windows CE handheld PC and the text goes straight into any app
on your phone, with Tab, the arrows and Ctrl+C, V, X, Z. Send files both
ways, and see the phone's screen on the handheld. It all travels as
sound: no cable, no network. Made on, and for, the HP Jornada 720.

THE PHONE
  Android: install Whisper-Tools.apk (the same version as this one) from
  https://github.com/kiriakoschristodoulou-netizen/hpc-whisper/releases
  Its home screen has a button for each tool. To type: set up the
  Keyboard, then in any app switch to the Whisper Tools keyboard. For
  files and the remote: tap Connect.

  iPhone, or any other phone: Apple does not let keyboards use the
  microphone, so there is no iPhone keyboard. Use the receiver page in
  the browser, with Copy and Share:
  https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/
  The page understands the Classic format only: on the handheld choose
  Settings, Typing format, Classic.

THE HANDHELD
  Needs an ARM processor and Windows CE 3.0 or later (tested on the HP
  Jornada 720; it will not run on MIPS or SH3 machines such as the
  Jornada 680/690). Copy this folder over and run WhisperTools.exe.

THE HOME SCREEN
  Whisper Tools opens on a home screen with a button for each tool: tap
  one, or move with the arrows and press Enter, or press its number. Just
  starting to type opens Type. Alt+1 to Alt+5 open a tool from anywhere,
  Alt+0 (or the Home button at the top left) comes back here. On Files,
  Link and Settings, Esc comes back too.

  1 Type      Type, and it goes to the phone. The line at the bottom says
              what the phone has confirmed ("All on the phone").
  2 Files     The handheld's files. Enter opens a picture (JPEG, PNG),
              a text file or a WAV sound; S sends the selected file to
              the phone (it lands in Downloads/Whisper Tools there);
              Backspace goes up a folder, I jumps to received files,
              C cancels a file on its way. Files from the phone arrive in
              \My Documents\Whisper Tools.
  3 Remote    The phone's screen, in grey. Start it on the phone (Remote,
              then Start the remote), or press Enter here to ask the phone.
              Tap the picture to tap on the phone (needs the Whisper Tools
              helper on the phone). Arrows and Page Up/Down move the view;
              Alt+Z switches between zoom and the whole screen, Alt+X
              zooms in twice as far, Alt+U refreshes.
  4 Link      The sound in and out, the phone, and the speed of each
              channel. Pair (P) checks the sound both ways and adjusts both
              devices; Test speaker (S) plays a one-second beep; Check the
              link (K) measures the fast channels (a soft hiss from each
              side for a few seconds).
  5 Settings  Typing format (Standard, or Classic for the receiver page),
              the silent channel (narrow 20.0-21.2 kHz,
              inaudible; or wide 18.2-21.2 kHz, twice as fast, some people
              hear it), files fast or silent, loudness of the fast channel,
              where received files go, the speaker's rate (the sound chip's
              own, measured, or 44,100 converted by Windows), and the
              Classic band, speed, volume.
  6 Exit

KEYS THAT GO TO THE PHONE
  Tab, Shift+Tab, Enter, Backspace, Delete, Esc, the arrows, Home, End,
  Page Up, Page Down, Ctrl+A, Ctrl+C, Ctrl+V, Ctrl+X, Ctrl+Z.
  Alt+S   press Send in the app on the phone (*)
  Alt+B   Back (*)        Alt+H   Home screen (*)    Alt+W   Recent apps (*)
  (*) these need the Whisper Tools helper, turned on once in the phone's
  accessibility settings (the app shows how). Send in a search or a
  one-line field works without it.

THE PROGRAM'S OWN SHORTCUTS (on Alt, so every Ctrl key reaches the phone)
  Alt+0 home   Alt+1..5 tools   Alt+N new page   Alt+K check the link
  Alt+Q quit

SOUND
  First time: on the Link screen press Test speaker (you should hear a
  beep), then press Pair on the phone, in a quiet room. Pairing measures
  this handheld's microphone and finds how loud it should play; both are
  kept (the Link screen shows them). Pair again in a new place, or if
  typing stops getting through. Once its microphone has been measured
  (Pair, or a minute of listening) the handheld plays at its sound chip's
  own rate, which carries the silent channel far better. While a file
  comes from the phone, the bottom line says how many pieces were heard. Typing and the
  answers are silent (above 20 kHz). Files and the remote's screen use
  the fast channels: a soft hiss while they move, quiet otherwise. Keep
  the phone within about a metre and its media volume at about half.

DIAGNOSTICS
  Whisper Tools writes everything the link does to a log: every sound it
  plays, every frame it hears or loses, files, pairing, and how busy the
  processor is. Each start writes a new file, "Whisper Tools log 1.txt"
  to "... 5.txt" in turn, in the folder for received files: set Received
  files to the memory card (Settings) and the card can simply be taken out
  and read on a computer. On the Link screen, Save what I heard (H) keeps
  the last 6 seconds the microphone heard as "Whisper Tools heard.wav" in
  the same folder. The phone keeps its own log: Link, Share diagnostics.
  After a problem, send the logs and the sound.

SOURCE
  The full source is in the source folder (Free Pascal 3.2.2 for Windows
  CE, ARM; see build.sh). The sound formats are in source\FORMAT3.md and
  source\FORMAT.md.
