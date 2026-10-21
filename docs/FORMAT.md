# The HPC Whisper sound format (version 2)

Everything needed to write a sender or a receiver for any device. The reference
code is `handheld/wmodem.pas` (the sender, whole numbers only), `modem.js` (the
receiver page, and a sender for tests) and
`android/app/src/main/java/net/kyriakos/whisper/Receiver.java` (the keyboard's
receiver, a line-by-line port of `modem.js`). The tests in `tests/` check all
three against each other.

## Tones

- A grid of tones 100 Hz apart, from 18,000 to 21,500 Hz (36 tones).
- A **band** is 16 neighbouring grid tones. Bands start at 18,000, 18,500,
  19,000, 19,500 or 20,000 Hz. Tone *v* (0 to 15) of a band starting at *B*
  is *B* + 100·*v* Hz.
- One tone is one **symbol** and carries 4 bits. A symbol lasts 48, 32 or
  20 ms (Slow, Normal, Fast). Symbol *k* of a frame starts at sample
  ⌊*k* · rate · ms / 1000⌋ from the start of the frame.
- The tone is a sine wave whose phase runs on without a jump from one symbol
  to the next. The frame fades in and out over 5 ms. Between frames there
  is at least 60 ms of silence.
- The handheld plays at 44,100 samples per second; the receiver may listen at
  any rate of 44,100 or more.

## Frame

1. **Preamble**, 8 symbols: `0 15 0 15 11 4 11 4`. A receiver should accept
   it with up to two of the eight drowned out.
2. **Blocks**: a header block and *B* body blocks, each a Reed-Solomon
   (15, 11) code word over GF(16), **interleaved**: symbol *t* after the
   preamble is symbol ⌊*t* / (*B*+1)⌋ of block *t* mod (*B*+1), the header
   being block 0. A burst of noise or a dropout so touches each block only
   lightly.

The **header** block's 11 nibbles:

| Nibbles | Meaning |
| --- | --- |
| 0 | format version, 2 |
| 1–2 | *n*, the number of text bytes (0 to 44) |
| 3–4 | sequence number (one more for each frame) |
| 5–6 | document id (changes when the handheld starts a new page) |
| 7–10 | *L*, the document's length in bytes |

The **body** bytes, as nibbles (high first), padded with zeros to a multiple
of 11 and cut into *B* = ⌈(*n* + 4) · 2 / 11⌉ blocks:

| Bytes | Meaning |
| --- | --- |
| 0–1 | *o*, the offset in the document where the text starts |
| 2 … *n*+1 | the text: document bytes *o* … *o*+*n*−1 (UTF-8) |
| *n*+2, *n*+3 | CRC-16 (CCITT: polynomial 0x1021, start 0xFFFF, high byte first) of *n*, sequence, document id, *L* (2 bytes), *o* (2 bytes) and the text |

Reed-Solomon code: field polynomial *x*⁴ + *x* + 1 (0x13), α = 2, generator
(*x* − α)(*x* − α²)(*x* − α³)(*x* − α⁴), systematic (the check nibbles are the
remainder of the data · *x*⁴ divided by the generator, highest power first).
A block corrects *e* wrong symbols and *f* symbols marked as unreliable when
2*e* + *f* ≤ 4.

## Meaning: a mirror of the document

Each frame says: **the document is *L* bytes long, and from offset *o* it
reads these bytes.** The receiver keeps a copy of the document: it sets the
length to *L* (forgetting anything beyond) and writes the bytes at *o*.
Bytes it has never received are missing, not wrong. A new document id means
a new page: the previous one is finished.

The handheld counts, for every byte, how many times it has gone out, and sends:

- **new text at once**, riding along the bytes that have been sent fewer than
  twice, so while you type every character goes out twice anyway;
- in pauses, the **least-sent bytes of the last 300**, again, in frames of at
  most 22 bytes (shorter frames get through more often). The 2nd send waits
  0.4 s, then 1.5, 3, 6, 10, 15 and 22 s for the 3rd to 8th;
- every second send on a **second band**, one kHz away, so a weak spot or a
  noise at one band does not hit all the copies;
- on **Resend** (Alt+R), all of the last 300 bytes again from the start.

The default is 6 sends. In a simulation (tests/losssim.pas) where every frame
is lost with some probability, the text arrives complete in all runs at up to
10 % loss and in about 96 % of the runs at 30 % loss.

The phone types a byte only after every earlier byte is known. A hole that is
not filled within 30 seconds is shown as a mark ("·") and then given up, so
one lost piece cannot block the text behind it for ever.

## Keys

Keys travel inside the text as private-use characters U+E000 + *code* (UTF-8
`EE 80..8F xx`). The code is 10 bits: the low 8 bits name the key (arrows,
Home, End, Delete, Tab, Esc, Ctrl+A/C/X/V/Z/Y as their own codes, Send, Back,
phone Home, Recents), and 0x100 and 0x200 add Shift and Ctrl for movement and
delete keys. A key is pressed once, when the bytes before it are known.

## The return channel (acknowledgement)

The phone answers the handheld, silently, so the handheld need not repeat what has arrived.

- **Frame:** the same preamble, then one RS(15,11) block, in the band at 19000 Hz (tones 19.0 to 20.5 kHz),
  32 ms a symbol (0.75 s in all). Nibbles of the block: type (1), page number (2), P (4), G (1), hash (3).
- **P** is the number of bytes from the start of the page that the phone holds without a gap. **G** is how many
  bytes are missing right after them (0 to 15). Bytes given up on do not count as held.
- **Hash:** the low 12 bits of CRC-16 CCITT over page number, P (high, low), G (low 4 bits) and the first P bytes
  of the page. The handheld checks it against its own text, so an acknowledgement of older text (an earlier page
  or text since changed) is not believed; then it sends the last 300 bytes again.
- **When:** about 700 ms after the last frame of a group was heard and nothing else is coming, at most once a
  second; the phone ignores its own sound for that time and 150 ms more.
- **Handheld:** it listens only between its own transmissions (the chip cannot play and record at once: the speaker is closed when it is quiet and the microphone opens, and the reverse when there is something to send). After a frame it waits up to 2.6 s for the answer. Bytes below P are done and not repeated; a
  gap of G bytes at P is sent at once. After two windows in a row without an answer it behaves as before
  (every byte sent the set number of times), so phones without the return channel still work. The title bar
  shows "Delivered" when P covers the whole text.
- **Measured** (Mic Scan, Return Test): the handheld microphone decodes 19.0 to 20.5 kHz cleanly.

## Receiving, in brief

- Measure each grid tone in 1 ms steps (a running complex sum per tone), so
  any window's strength is a difference of two sums.
- Look for the preamble in every band and speed, all the time, even while
  frames are being read: in each of its eight windows, the expected tone
  should be the strongest of the band's 16, or a close second (see ghosts). Use the middle of each symbol
  (from 25 % to 90 % of it), so echoes of the previous symbol do not count.
- **Ghosts.** Some handhelds' sound chips convert the sound to their own
  rate crudely and add a "ghost" of every tone at a fixed distance. The
  HP Jornada 720 adds one 900 Hz lower: about half as strong as the tone at
  20 kHz, up to five times stronger at 21.5 kHz, where the speaker is weak.
  Since the preamble's tones are known, measure the ghosts there: for each
  distance, how strong the sound is relative to the tone, at each of the
  preamble's tones (filled in between for the others). Keep only ghosts that
  show every time and stand far above the background. Then read each symbol
  by comparing every candidate's expected pattern (the tone and its ghosts)
  with what was heard, rather than taking the loudest tone.
- Try the frame at each possible size *B*, smallest first, as soon as that
  much has been heard. A block that does not check out is tried again with
  its least certain symbols (the weakest share of their band's power) marked
  as unreliable, one to four of them.
- If no size works, the sender's sound may have stopped for a moment, which
  delays every later tone: at the sizes where the sound really ended, try
  each place and length of such a gap, and keep one that passes the CRC.
