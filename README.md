![HPC Whisper](docs/banner.png)

# HPC Whisper

Type on a Windows CE handheld PC and the text goes straight into any app on your
phone (an email in Gmail, a message, a note), carried by tones too high to hear
(18 to 21.5 kHz). No cable, no network, no extra hardware.

Made on, and for, the HP Jornada 720. Created by Kyriakos Christodoulou.

## Get it

- **Android: the HPC Whisper keyboard.** Install `HPC-Whisper.apk` from the
  [latest release](../../releases/latest), open it and follow the three setup
  steps. Then, in any app, switch to the HPC Whisper keyboard and type on the
  handheld. New text appears underlined for a moment while it may still change,
  then it is written for good. The app has no internet access.
- **iPhone, or any phone: the receiver page** in the browser,
  <https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/>, with Copy and
  Share. Tap **Listen** and allow the microphone. Add it to the home screen:
  after the first visit it works with no internet.
  *Apple does not let keyboards use the microphone at all, so an iPhone
  keyboard is impossible; on an iPhone the page is the way.*
- **Handheld:** `HPC-Whisper-12.zip` from the same release. Copy the folder
  inside it to the handheld and run `whisper.exe`. Version 1.1 or later is
  needed (the sound format changed in 1.1).

## Which handhelds

The program is built for **ARM processors** running **Windows CE 3.0 or later**
(Handheld PC 2000, and Pocket PC 2000 onwards).

| | |
| --- | --- |
| Tested | HP Jornada 720 |
| Should work | HP Jornada 728, NEC MobilePro 900/900c, other ARM handhelds with Windows CE 3.0+; ARM Pocket PCs (the layout is made for wide screens, so it is cramped in portrait) |
| Will not run | MIPS and SH3 machines: HP Jornada 680/690, NEC MobilePro 770/780/800, Casio Cassiopeia and others. The sound format is open, so a version for them can be written |
| Unknown | Handheld PC Pro (Windows CE 2.11) on ARM |

Every machine's speaker is different: if the phone reads nothing, try a lower
band, Slow, or more volume; if you can hear the tones, try a higher band or less
volume. Please report what works on yours.

## Use

Run the program on the handheld and type. The phone follows a second or two
behind; Backspace and Enter work too (Enter in a one-line field does what Enter
does there: search, send, next). On the handheld:

| Key | Setting |
| --- | --- |
| Ctrl+B | Band: 18.0–19.5 up to 20.0–21.5 kHz (default 20.0–21.5) |
| Ctrl+P | Speed: Slow, Normal, Fast (about 5, 8, 12 characters a second) |
| Ctrl+V | Volume: 10 to 100 % (default 50 %; full volume can distort into audible sound) |
| Ctrl+T | Types a test sentence |
| Ctrl+L | A new page: clears the handheld's screen; the phone starts a new paragraph |
| Ctrl+Q | Exit |

The phone finds the band and speed by itself. Keep it within about a metre.

**Lost pieces fill themselves in.** The handheld sends new text at once and
repeats it during your pauses. A piece lost to noise shows as · for a moment and
fills in when the repeat arrives. If letters still go missing, the app's
**Record 30 seconds** button saves what the phone hears, to send for diagnosis.

## Host the receiver yourself

The receiver is `index.html`, `modem.js`, `manifest.json`, `sw.js` and the
`icons/` folder. Put them on any web space that serves **https** (GitHub Pages,
Netlify, Cloudflare Pages, your own site); the microphone works only over https.
Nothing runs on the server. The same files are in the handheld download, under
`source/web`.

## How it works

16 tones 100 Hz apart, 4 bits per tone. Each frame carries a piece of the
document ("from offset o it reads ..."), protected by interleaved Reed-Solomon
blocks (weak tones are set aside and rebuilt) and a CRC-16. The phone listens
with its unprocessed microphone where the phone has one, with both microphones
where it can, and learns each handheld's sound quirks from the start of every
frame (the Jornada 720's sound chip adds a "ghost" of every tone 900 Hz lower,
sometimes louder than the tone itself). The full description, enough to write a sender or receiver for
any device, is in [docs/FORMAT.md](docs/FORMAT.md).

## Files

| Folder | What |
| --- | --- |
| `/` | the receiver page (served by GitHub Pages) |
| `android/` | the Android keyboard and its setup screen (Java) |
| `handheld/` | the handheld program (Free Pascal for Windows CE, ARM) and its download |
| `docs/` | the sound format and the artwork |
| `tests/` | the sender, page receiver and keyboard receiver checked against each other, with noise, dropouts and stalls |

The Android app is built by GitHub on every change (see `.github/workflows`).
Its signing key is kept in the repository on purpose, so each new build
installs over the old one.
