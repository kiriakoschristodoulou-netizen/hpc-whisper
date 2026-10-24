# HPC Whisper release notes

## 1.2

- **Return channel (optional):** the phone confirms silently what it has received, so the handheld stops repeating what has arrived, sends missing pieces at once, and shows "Delivered". Handheld: Settings, Return channel. Phone: Settings, Confirm to the handheld. Both off by default.
- **Whole-page check:** with the return channel on, the handheld checks every 30 s (when you have stopped typing) that the phone holds the whole page; a difference anywhere sends the whole page again.
- **Field correction:** the keyboard compares what it has written into the field with the page and corrects text that changed after it was written.
- **Enter key (handheld setting):** Enter can send the message (Shift+Enter is a new line). Alt+S still sends.
- Microphone and speaker are opened at the same sample rate on the handheld, so the return channel works on the Jornada 720.
- Settings screen: ten rows, explanation next to the Back button.
- A complete description of the sound format for anyone who wants to build their own sender or receiver: `docs/SOUND-PROTOCOL.md`.

## 1.1

First version of the return channel (superseded by 1.2).

## 1.0

First public version: type on the handheld, text appears in any app on the phone, repeated several times on two bands. Android keyboard with touch edit keys and an optional helper; receiver web page for any other phone.

## Separate tools

- **Mic Scan 1.3:** measures how a handheld's microphone hears sound (frequency response, automatic gain, true sampling rate, ghost tones) and whether it can decode data from the phone (Return Test).
- **Duplex Test 1.0:** tests whether a handheld's sound chip can play and record at the same time.
