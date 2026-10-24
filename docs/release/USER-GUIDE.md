# HPC Whisper 1.2: user guide

Type on a Windows CE handheld PC and the text appears in any app on your Android phone, carried by sound too high for most people to hear. No cable, no network, no extra hardware.

## What you need

- **A handheld:** an ARM-based Windows CE 3.0 (or later) handheld PC. Tested: **HP Jornada 720**. It will not run on MIPS or SH3 machines (for example the Jornada 680 and 690).
- **A phone:** Android 7.0 or later with a microphone. (On an iPhone or any other phone you can use the receiver page, with Copy and Share. Apple does not let keyboards use the microphone, so there is no iPhone keyboard.)
- **A quiet-ish room:** the phone and handheld within about a metre of each other. Loud background noise in the 18 to 21 kHz range (some chargers, ultrasonic devices) can disturb it.

## Install

### On the phone

1. Download `HPC-Whisper.apk` from the latest release and open it. Android will ask you to allow installing from this source, once.
2. Open the HPC Whisper app. It shows three steps; tap each:
   1. **Allow the microphone** (needed to hear the handheld; it listens only while the HPC Whisper keyboard is open).
   2. **Turn on the HPC Whisper keyboard** in the list that opens.
   3. **Switch to it** when you want to type: in any app, tap a text field, then choose the HPC Whisper keyboard from the keyboard picker.
3. Optional: **Send button and phone keys.** Turn on the HPC Whisper helper in the phone's accessibility settings. It lets the handheld press Send, Back, Home and Recent apps. It reads nothing and stores nothing.

### On the handheld

1. Download `HPC-Whisper-12.zip` from the same release and unzip it on a computer.
2. Copy the folder `HPC-Whisper` to the handheld (a storage card or the main memory both work).
3. Run `HPCWhisper.exe`. Hold the phone within a metre of the handheld's speaker.

## Use

Type on the handheld; everything goes to the phone as you type. The program's own shortcuts use **Alt**, so every Ctrl key reaches the phone.

| Key | What it does |
| --- | --- |
| Letters, Enter | Typed into the field (see "Enter key" below) |
| Arrows, Home, End, PgUp, PgDn | Move; Shift selects, Ctrl jumps a word or to the start/end |
| Backspace, Del | Delete; Ctrl deletes a word |
| Ctrl+A, C, X, V | Select all, copy, cut, paste on the phone |
| Ctrl+Z, Ctrl+Y | Undo, redo |
| Tab, Shift+Tab, Esc | As on a computer |
| Alt+S | Press Send in the app (needs the helper, or a field whose key says Send) |
| Alt+B, Alt+H, Alt+W | Back, phone Home, Recent apps (need the helper) |
| Alt+R | Send the last text again |
| Alt+N | Start a new page: the phone starts fresh |
| Alt+K, Alt+O, Alt+Q | Keys list, Settings, Quit |

The phone's keyboard also has touch edit keys (arrows, select, copy, paste, undo). Everything that arrives is kept on the phone as dated sessions (the newest 25 by default, never fewer than 10), hidden until you tap them.

## Settings on the handheld (Alt+O)

| Setting | What it does | Default |
| --- | --- | --- |
| Repeats | How many times each piece of text is sent (2 to 8). More is surer. | 6 |
| Second band for repeats | Every second send goes one kHz lower, where a weak spot at the first band does not reach it. | On |
| Volume | Loudness of the tones. | 50 % |
| Speed | Normal is the surest; Fast shortens the wait for the text to appear. | Fast |
| Band | The phone finds the band by itself; change this only if something else makes sound up there. | 19.0 to 20.5 kHz |
| Sound rate | The Jornada's own 43,200 or Windows' 44,100. Leave it unless the phone struggles. | 43,200 |
| Return channel | The phone confirms what it received, silently; then nothing is repeated needlessly. | Off |
| Enter key | New line, or "Sends the message" (Shift+Enter is always a new line). | New line |
| Test | Sends a sentence to the phone, to try it. | |
| About | Version and credits. | |

## The return channel (optional)

With **Settings, Return channel** on (handheld) and **Settings, Confirm to the handheld** on (phone), the phone answers silently after each piece of text:

- text that has arrived is not sent again, and the title bar shows **Delivered**;
- a missing piece is sent again at once;
- about every 30 seconds, when you have stopped typing, the handheld asks the phone what it holds. If the phone's copy differs anywhere, the whole page is sent again, and the keyboard corrects text it had already written if the page changed after that.

If the phone does not answer, the handheld repeats everything as set under Repeats. Both sides work without the return channel, and the return channel works with only one side switched on (it just does nothing).

## Sending a message in a chat app

Pressing Enter normally gives a new line. To send:

- press **Alt+S** (or tap Send on the handheld's screen), or
- set **Settings, Enter key** to "Sends the message": then Enter sends and Shift+Enter makes a new line.

Sending needs one of: the helper turned on in the phone's accessibility settings, or a field whose key says Send, Go or Search (the keyboard then uses that key).

## Tips

- Keep the phone within about a metre of the handheld's speaker, microphone side toward the handheld, not in a pocket or face-down on a soft surface.
- Wait for the keyboard on the phone to say what it is doing: "Waiting for a missing piece" means a piece is on its way; "Weak signal" means move the phone closer.
- For long text, give it time: the sound carries a few characters per second.
