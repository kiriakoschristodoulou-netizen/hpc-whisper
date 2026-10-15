Whisper Tools 3.2 (formerly HPC Whisper)
by Kyriakos Christodoulou

Type on a Windows CE handheld PC and the text goes straight into any app
on your phone, with Tab, the arrows and Ctrl+C, V, X, Z. Send files both
ways, and see the phone's screen on the handheld. It all travels as
sound: no cable, no network. Made on, and for, the HP Jornada 720.

THE PHONE
  Android: install Whisper-Tools.apk (version 3.2 or later) from
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
              channel. Check the link (Alt+K) measures the fast channels
              (a soft hiss from each side for a few seconds).
  5 Settings  Typing format (Format 3, or Classic for older phone apps and
              the receiver page), the silent channel (narrow 20.0-21.2 kHz,
              inaudible; or wide 18.2-21.2 kHz, twice as fast, some people
              hear it), files fast or silent, loudness of the fast channel,
              where received files go, and the Classic band, speed, volume.
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
  Typing is silent (above 20 kHz). Files and the remote's screen use the
  fast channels: a soft hiss while they move, quiet otherwise. Keep the
  phone within about a metre and its media volume at about half.

WHAT IS NEW IN 3.2
  The first device test found the handheld's processor could not keep up
  with listening (it froze, and heard nothing). Listening now takes about
  a third of the processor instead of more than twice all of it; the fast
  receiver listens only when a file, the remote or a link check is coming;
  if the processor ever falls behind, sound is skipped instead of the
  program freezing. The silent channel is louder, a steady tone (some
  phones make one at 20 kHz) no longer blinds the receivers, and the start
  of a frame is found more surely. To receive a file from the phone, the
  Files screen no longer needs to be open: the phone announces it.

WHAT IS NEW IN 3.1
  The new name, Whisper Tools, and a home screen with a button for each
  tool. Received files now go to \My Documents\Whisper Tools.

WHAT IS NEW IN 3.0
  A new sound format (docs/FORMAT3.md): about 25 times faster typing, the
  phone confirms what has arrived, all keys, files both ways, the picture
  remote, and a link check. Classic keeps the version 1 tones for older
  phone apps and the receiver page.

SOURCE
  The full source is in the source folder (Free Pascal 3.2.2 for Windows
  CE, ARM; see build.sh). The sound formats are in source\FORMAT3.md and
  source\FORMAT.md.
