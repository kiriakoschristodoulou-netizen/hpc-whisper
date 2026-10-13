![J720 Whisper](docs/banner.png)

# J720 Whisper

Type on an HP Jornada 720 and the text appears on your phone, carried by tones
too high to hear (18 to 21.5 kHz). No cable, no network, no extra hardware.

Created by Kyriakos Christodoulou.

## Get it

- **Phone, in Chrome:** <https://kiriakoschristodoulou-netizen.github.io/j720-whisper/>
  Tap **Listen** and allow the microphone. Add it to the home screen: after the
  first visit it works with no internet.
- **Phone, as an Android app:** `J720-Whisper.apk` from the
  [latest release](../../releases/latest). It needs no website at all.
- **Jornada:** `J720-Whisper-10.zip` from the same release. Copy the folder
  inside it to the Jornada and run `whisper.exe`.

## Use

Run the program on the Jornada and type. The phone follows a second or two
behind; Backspace and Enter work too. On the Jornada:

| Key | Setting |
| --- | --- |
| Ctrl+B | Band: 18.0–19.5 up to 20.0–21.5 kHz (default 20.0–21.5) |
| Ctrl+P | Speed: Slow, Normal, Fast (about 5, 8, 12 characters a second) |
| Ctrl+V | Volume: 10 to 100 % (default 50 %; full volume distorts into audible sound) |
| Ctrl+T | Types a test sentence |
| Ctrl+L | Clears the Jornada's screen |
| Ctrl+Q | Exit |

The phone finds the band and speed by itself. Keep it within about a metre.

## Host the receiver yourself

The receiver is three files and an icon folder: `index.html`, `modem.js`,
`manifest.json`, `sw.js` and `icons/`. Put them on any web space that serves
**https** (GitHub Pages, Netlify, Cloudflare Pages, your own site); the
microphone works only over https. Nothing runs on the server.

## How it works

16 tones 100 Hz apart, 4 bits per tone, Reed-Solomon error correction and a
CRC-16 check. The full description, enough to write a sender or receiver for
any device, is in [docs/FORMAT.md](docs/FORMAT.md).

## Files

| Folder | What |
| --- | --- |
| `/` | the receiver page (served by GitHub Pages) |
| `android/` | the Android app: the same page inside the app |
| `jornada/` | the Jornada program (Free Pascal for Windows CE) and its download |
| `docs/` | the sound format and the artwork |

The Android app is built by GitHub on every change (see `.github/workflows`).
Its signing key is kept in the repository on purpose, so each new build
installs over the old one.
