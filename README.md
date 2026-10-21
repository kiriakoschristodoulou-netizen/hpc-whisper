![HPC Whisper](docs/banner.png)

# HPC Whisper

Type on a Windows CE handheld PC and the text appears in any app on your phone
(an email, a message, a note), with arrows, Shift selection, Tab and
Ctrl+A, C, X, V, Z, Y. It travels as sound too high to hear (20 to 21.5 kHz): no
cable, no network, no extra hardware. Every piece of text is sent several times,
on two bands, so it arrives even when some of the sound is lost.

Made on, and for, the HP Jornada 720. Created by Kyriakos Christodoulou.

## Get it

- **Android:** install `HPC-Whisper.apk` from the [latest release](../../releases/latest).
  Open the app and follow the three steps (microphone, turn on the keyboard,
  choose it). Then, in any app, tap a text field and switch to the HPC Whisper
  keyboard. It listens only while that keyboard is open. Everything that arrives
  is kept on the phone as dated sessions (app and date; the newest 25 by default,
  never fewer than 10), hidden until you tap them. The app has no
  internet access. Its keyboard also has touch edit keys (arrows, select,
  copy, paste, undo...).
- **The helper (optional):** turned on once in the phone's accessibility
  settings, it lets the handheld press Send (Alt+S), Back, Home and Recent apps.
- **iPhone, or any phone:** the receiver page,
  <https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/>, with Copy and Share.
  (Apple does not let keyboards use the microphone, so no iPhone keyboard.)
- **Handheld:** `HPC-Whisper-10.zip` from the same release. Copy the folder to
  the handheld and run `HPCWhisper.exe`.

- **Mic Scan** (`Mic-Scan-13.zip`, separate tool): records a test sound played by
  [scan.html](https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/scan.html) and measures how the handheld's
  microphone hears it: frequency response, automatic gain, real sampling rate, ghost tones, shortest burst.

## Which handhelds

ARM processors with Windows CE 3.0 or later. Tested: HP Jornada 720. Will not
run on MIPS or SH3 machines (Jornada 680/690 and others).

## Use

Type on the handheld. Everything goes to the phone as you type it. The program's
own shortcuts are on Alt, so every Ctrl key reaches the phone:

| Key | What |
| --- | --- |
| Arrows, Home, End, PgUp, PgDn | Move; Shift selects, Ctrl jumps a word or to the start/end |
| Bksp, Del | Delete; Ctrl deletes a word |
| Ctrl+A C X V, Ctrl+Z, Ctrl+Y | Select all, copy, cut, paste, undo, redo |
| Tab, Shift+Tab, Esc | As on a computer |
| Alt+S, Alt+B, Alt+H, Alt+W | Send, Back, phone Home, Recent apps (need the helper) |
| Alt+R | Send the last text again |
| Alt+N | A new page: the phone starts fresh |
| Alt+K, Alt+O, Alt+Q | Keys list, Settings, Quit |

Settings (defaults are the ones that worked best: 6 repeats, Fast, band 19.0 to 20.5 kHz,
sound rate 43,200): repeats (2 to 8), second band, volume, speed, band, sound rate, and an
About page. The phone finds band and speed by itself.

## How it works

[docs/FORMAT.md](docs/FORMAT.md): 16 tones 100 Hz apart per band, 4 bits per
tone, Reed-Solomon and CRC, and a mirror of the document: each frame says "the
document is L bytes, from offset o it reads...", so repeats are harmless and gaps
fill when a repeat arrives. The receiver scans every band and speed and learns the
Jornada chip's "ghost" tones. Sender, receivers and the typing logic are tested
against each other, including lost frames.

## Files

| Folder | What |
| --- | --- |
| `/` | the receiver page (GitHub Pages) |
| `android/` | the Android app: keyboard, helper (Java) |
| `handheld/` | the handheld program (Free Pascal for Windows CE, ARM) and its download |
| `docs/` | the sound format and artwork |
| `tests/` | Pascal, Java and JavaScript checked against each other, with noise, dropouts and lost frames |

The Android app is built by GitHub on every change (see `.github/workflows`).
Its signing key is in the repository on purpose, so each new build installs
over the old one.
