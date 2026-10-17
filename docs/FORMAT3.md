# The Whisper Tools sound format, version 3

Version 3 carries typing, files and a remote over four sound channels. It
replaces neither the version 2 format (`FORMAT.md`) nor its receivers: a
phone running Whisper Tools still reads version 2, so an older handheld
program keeps working.

Reference code: `android/app/src/main/java/net/kyriakos/whisper/w3/` (Java,
the phone) and `handheld/w3*.pas` (Pascal, whole numbers only, the handheld).
The tests in `tests/w3/` check each against the other through simulated rooms
and through real recordings.

## 1. The modem

All sound is made and read at a **modem rate of 51,200 samples per second**,
whatever rate the device itself uses: a sender makes its symbols at 51,200
and converts them to its own rate; a receiver converts what it hears to
51,200. The conversion uses the device's **real** rate, measured, not the
rate it claims: a handheld may claim 44,100 when recording and deliver a
little less (the HP Jornada 720 tested delivered 1.8 % fewer). Each device's
rate is its own, so it is never assumed: section 7 says how it is found.

- **Symbol**: 512 samples (10 ms) plus a cyclic prefix of 128 samples
  (2.5 ms), 640 samples (12.5 ms) in all. Carrier *b* is at *b* × 100 Hz.
- **Carriers** are switched on or off and phase-shifted per symbol. A carrier
  carries bits in how much its phase turns from one symbol to the next
  (differential phase-shift keying), so the room's effect on its phase
  cancels out.
- Each symbol is extended by 48 samples (0.94 ms) past its end and fades in and out (raised
  cosine) inside its cyclic prefix and that extension, which overlaps the
  next symbol's prefix. The 512 samples a receiver reads are untouched.

### Channels

| Channel | Direction | Carriers (bins) | Count | Pilots (indices) | Default bits |
| --- | --- | --- | --- | --- | --- |
| SU narrow (default) | handheld → phone | even bins 200–212 (20.0–21.2 kHz) | 7 | 0, 6 | 1 |
| SU wide | handheld → phone | even bins 182–212 (18.2–21.2 kHz) | 16 | 0, 15 | 1 |
| SD | phone → handheld | even bins 200–212 (20.0–21.2 kHz) | 7 | 0, 6 | 1 |
| FU | handheld → phone | bins 10–189 (1.0–18.9 kHz) | 180 | every 10th, and the last | 1 |
| FD | phone → handheld | bins 5–119 (0.5–11.9 kHz) | 115 | every 10th, and the last | 1 |

Silent carriers are 200 Hz apart so that a handheld's ghost tones (the
Jornada 720 adds one 900 Hz below every tone) fall between them. SU narrow
stays at 20 kHz and above, inaudible at 50 % volume; SU wide is faster and may
be faintly audible to some. SD uses the same carriers as SU narrow, also at
20 kHz and above, so the two sides take turns (section 5).

**Scrambling** (section 2) starts at W[0] for frames up (SU, FU) and at
W[2048] for frames down (SD, FD). A frame, or its echo, therefore never reads
as one from the other direction, although SU and SD share their carriers.

**Pilots** never turn (their phase step is always 0). The receiver uses
them to remove what all carriers share: a common phase step and a step that
grows with frequency (a timing drift).

### Bits per carrier: the map

Every channel has a **map**: for each carrier, 0 (off), 1, 2 or 3 bits.
Pilots are always on. The default map is the "Default bits" column. A link
check (section 4) replaces it with a measured map, numbered 1 to 31; map 0 is
always the default map. Phase steps, Gray coded:

| Bits | Value → phase step, in units of 2π / 2^bits |
| --- | --- |
| 1 | 0 → 0, 1 → 1 |
| 2 | 00 → 0, 01 → 1, 11 → 2, 10 → 3 |
| 3 | 000 → 0, 001 → 1, 011 → 2, 010 → 3, 110 → 4, 111 → 5, 101 → 6, 100 → 7 |

Within a symbol, bits fill the carriers in order of frequency, the first bit
of a value being its highest.

### Loudness

**Silent channels** are scaled so that the frame's peak is the chosen level,
and are never clipped: clipping a sound near 20 kHz makes harmonics that fold
back to 6–12 kHz, where they are heard (device test, 16 October 2026). Up to
3 kHz below its band, a silent frame stays at least 55 dB under its own band,
as sent at the device's rate (`tests/w3/AudibleTest`, both programs). Defaults:
on the handheld the step its loudness ladder chose (section 7), 14,500 of
32,767 until then; on the phone the level its loudness check
chose (section 7), 0.45 until then.

**Fast channels** (a soft hiss by design) are scaled so that their RMS level
is a third of the chosen peak and then clipped at that peak: 0.125 of full
scale by default (quarter loudness, test 2).

## 2. A frame

1. **S, the sync symbol.** Only every second carrier of the channel (bins
   that are multiples of twice the carrier spacing: even bins for the fast
   channels, multiples of 4 for the silent ones), √2 times as strong, with
   fixed phases. Its 512 samples repeat after 256 (fast) or 128 (silent)
   samples, which no other symbol does: the receiver looks for that.
2. **R, the reference symbol.** All the channel's carriers, fixed phases. It
   confirms the frame, sets the timing exactly (the peak of the room's
   response measured on it), and is the starting phase for the differential
   symbols that follow.
3. **Header**: 3 bytes plus 6 Reed–Solomon check bytes, always sent with
   map 0.
4. **Payload**: the message bytes and a CRC-16, Reed–Solomon coded, sent
   with the map the header names.
5. At least 25 ms of silence before the next frame.

Fixed phases, in quarter turns: S on carrier *c* (counting all the
channel's carriers from the lowest) `P[(7c) mod 256]`, R `P[(7c + 101) mod 256]`,
where `P[i] = (x_i >> 9) & 3`, `x_(i+1) = (25173·x_i + 13849) mod 65536`,
`x_0 = 11`.

**Scrambling.** The coded header bytes, and separately the coded payload
bytes, are XORed with `W[i] = (y_i >> 8) & 255`, `y_(i+1) = (25173·y_i +
13849) mod 65536`, `y_0 = 0x1D0F`, before they are sent. Without it,
repetitive data could line all the carriers' phases up into one loud click.

### Header

| Byte | Meaning |
| --- | --- |
| 0 | message type (section 3) |
| 1 | payload length, low 8 bits |
| 2 | bits 0–2: payload length, high 3 bits; bits 3–7: map number |

Payload length is at most 2,047 bytes. The 3 bytes are followed by 6 check
bytes (RS over GF(256), below), corrected before use.

### Payload coding

The message bytes are followed by their CRC-16 (CCITT: polynomial 0x1021,
start 0xFFFF, high byte first). These *n* bytes are cut into
`B = ceil(n / 223)` blocks of nearly equal size (the first `n mod B` blocks
one byte longer). A block of *k* bytes gets *p* check bytes,
`p = min(32, max(8, 2·ceil(k / 8)))`. The coded blocks are then
**interleaved by bytes**: byte *j* of every block in turn (block 0's byte 0,
block 1's byte 0, …, block 0's byte 1, …), a block that has run out being
skipped. A burst of noise so damages a little of each block.

Reed–Solomon: GF(256) with the polynomial 0x11D, α = 2, generator
`(x − α^0)(x − α^1)…(x − α^(p−1))`, systematic, check bytes last. A block
corrects *e* errors when 2*e* ≤ *p*.

The coded bytes go out as bits, highest first, filling the data carriers of
each symbol in order (with the map in use); the last symbol is filled up with
zeros.

## 3. Messages

| Type | Name | Payload | Sent on |
| --- | --- | --- | --- |
| 0x01 | TEXT | doc id (1), seq (1), L (2), o (2), bytes | SU |
| 0x02 | TEXT_ACK | doc id (1), known (2), L (2) | SD |
| 0x10 | FILE_OFFER | file id (2), size (4), packets (2), kind (1), name (UTF-8) | FD; FU or SU |
| 0x11 | FILE_DATA | file id (2), packet (2), data (up to 1,024) | FD; FU or SU |
| 0x34 | PAIR_REPORT | see section 7 (38 bytes) | FU (handheld), FD (phone) |
| 0x12 | FILE_NEED | file id (2), flags (1), have (2), then missing packets (2 each, up to 32) | the other side's silent channel |
| 0x13 | FILE_CANCEL | file id (2) | either |
| 0x20 | SCREEN | update (2), flags (1), then a zlib stream of tiles | FD |
| 0x21 | INPUT | kind (1), then by kind (below) | SU (kinds 6 and 7 also SD) |
| 0x30 | TRAIN | 24 symbols of fixed pattern, no RS (below) | the channel trained |
| 0x31 | MAP | channel (1), map number (1), carriers (1), 2 bits per carrier | the other direction |
| 0x32 | HELLO | version (1), can-hear (1), can-play (1) (bit *n* = channel *n*), flags (1): bit 0 = an answer | either |
| 0x33 | CHECK | channel (1): please send TRAIN on it | the other direction |

All numbers are big-endian. TEXT follows the version 2 meaning: "the
document is L bytes long; from o it reads …" (see `FORMAT.md`).

**Keys inside the text.** Keys other than letters travel in the document as
characters from Unicode's private area, U+E000 + code:

| Code | Key | Code | Key |
| --- | --- | --- | --- |
| 0x08 | Backspace (on the phone's text) | 0x25 | Left |
| 0x09 | Tab | 0x26 | Up |
| 0x0A | Shift+Tab | 0x27 | Right |
| 0x1B | Esc | 0x28 | Down |
| 0x21 | Page Up | 0x2E | Delete |
| 0x22 | Page Down | 0x41 | Ctrl+A (select all) |
| 0x23 | End | 0x43 | Ctrl+C |
| 0x24 | Home | 0x56 | Ctrl+V |
| 0x58 | Ctrl+X | 0x5A | Ctrl+Z |
| 0x80 | press Send (accessibility helper) | 0x81 | Back |
| 0x82 | Home screen | 0x83 | Recent apps |

The phone writes the text before a key for good, then performs the key. The
handheld never takes back a key: Backspace with nothing typed after the last
key sends key 0x08, which deletes on the phone.

**TEXT_ACK** tells the handheld that the phone holds bytes 0 to *known* − 1
of document L. The handheld stops repeating them.

**INPUT kinds** (positions in the remote picture's pixels, 2 bytes each):
1 tap (x, y); 2 long press (x, y); 3 swipe (x1, y1, x2, y2); 4 view (mode
(1): 0 the whole screen, a portrait screen turned sideways with its top on
the left, 1 zoom (the phone's width fills the picture), 2 zoom twice as
large; then the handheld's picture width and height); 5 refresh (send every
tile again); 6 remote on (from the handheld: please start; from the phone:
it has started); 7 remote off; 8 scroll (dx, dy, signed, in picture pixels);
9 key (1 byte: a key code from the table above, such as Send or Back).

**FILE_NEED**: the receiver holds every packet below *have* except those
listed (the first 32 missing ones). Flags: bit 0 "all received", bit 1 "send
the offer again" (a packet arrived for a file whose offer was not heard).

**TRAIN**: after the header, 24 symbols in which every carrier, pilots
included, turns by the 2-bit value `P[(3c + 11s) mod 256]` (quarter turns) in symbol *s*.
The receiver measures each carrier's phase error and replies with a MAP:
phase signal-to-noise of at least 23 dB → 3 bits, 16 dB → 2, 10 dB → 1,
less → 0.

**SCREEN** flags: bit 0 the last message of this update, bit 1 the
picture's size or view changed (the handheld clears it first). **Tiles** (in the zlib stream): repeated records of x (1), y (1) in
16-pixel tile units, then 128 bytes of 4-bit grey pixels, two per byte, rows
top to bottom. A record with x = 255 ends the stream; y then gives the
picture's width in tiles and the next byte its height.

## 4. Link check

1. Each side says HELLO on its silent channel when it starts; a side that
   hears HELLO forgets the maps it was given (the other side has just
   started and knows none) and answers with its own HELLO, marked as an
   answer (an answer is not answered and resets nothing).
2. To use a fast channel, the sender sends TRAIN; the receiver answers with
   MAP on its own silent channel; from then on the sender uses that map. A
   side can ask for this with CHECK. Maps are kept only while the programs
   run.
3. When too many frames fail, the receiver sends a new MAP, or map 0.

## 5. Taking turns

SU and SD share a band, and a device hears its own sound loudly. So:

- A device does not listen while its own silent sound is heard: the phone
  ignores its microphone from when its sound really comes out (the sound
  card's timestamps) until 60 ms after it ends, and listens before and after. The handheld does not listen while it plays at all: its sound chip
  (the Jornada 720's) cannot play and record at once, so it closes the
  microphone, opens the output, plays, adds 150 ms of silence, closes the
  output and opens the microphone again.
- Every transmission after more than 300 ms of quiet starts with a 150 ms
  lead-in: a 21.7 kHz tone at about −28 dB, faded in and out. Speakers that
  were idle fade in their first sound; the lead-in takes that loss, not the
  frame's sync symbol. The phone also keeps its output stream playing silence
  between frames (a buffer of about 100 ms, kept full), and always plays on
  its own speaker, even when Bluetooth or a computer is set to play the
  phone's sound. The phone keeps
  listening while it plays on FD (another band), so taps and answers from
  the handheld reach it during a file or the remote's screen.
- After each TEXT frame the handheld listens for 1.5 s (from when its
  microphone is open again) before it sends anything else but an answer;
  the window ends early when the phone's answer arrives.
- The phone answers (TEXT_ACK, FILE_NEED, MAP) so that its answer sounds
  about 0.3 s after the handheld's frame ended: it waits 260 ms less its own
  sound delay (measured from the sound card's timestamps; at least 30 ms),
  and never while a frame from the handheld is still coming in. With a lead-in
  and a 275 ms answer, this fits the handheld's window for any phone whose
  sound comes out within about 0.65 s (`tests/w3/TurnTest`).
- A file sender sends 16 packets, then waits up to 1.5 s for FILE_NEED before
  going on.

## 6. Files

**Kinds** (FILE_OFFER, low 7 bits): 0 other, 1 picture, 2 sound, 3 text, 4
document. Bit 7: the data is a zlib stream; the receiver unpacks it and saves
the result under the name given. *size* is the size of the data as sent.

**Sending.** The sender sends the offer, then packets of 1,024 bytes (the
last shorter), 16 at a time: first those the receiver asked for again, then
new ones. After each 16 it waits up to 1.5 s for FILE_NEED.

- FILE_NEED with bit 0: done.
- Otherwise every packet below *have* that is not listed is confirmed; listed
  ones go again; packets sent at or after *have* (lost at the end of a
  batch) go again too, unless the list is full (32), when the next answer
  covers them.
- No answer after a batch, when answers have come before: the offer goes
  again, as a question ("what do you still need?"); after 6 such questions
  without an answer the transfer stops.
- No answer ever (a receiver that cannot send): every batch starts with the
  offer, and when all packets have gone, all go once more; then the file
  counts as sent, unconfirmed.

**Receiving.** The receiver answers with FILE_NEED once the sender has been
quiet for 250 ms after an offer or a packet. It keeps a finished transfer for
2 minutes, to answer the sender's questions.

**Channels.** The phone sends files on FD, and each offer on SD as well: the handheld's processor
has no time to listen on FD all the time, so it turns that receiver on when it hears an offer (or
while its Files or Remote screen is open, or during a link check). The handheld sends on FU (a soft
hiss, the default) or on its silent channel (slow). Answers go on the
receiver's silent channel.

**Conversions** (the phone, before sending): pictures to JPEG fitted to 640 ×
240 (or 320 wide, or 640 wide at full height); PDF pages to 640-wide PNG
pictures in 16 greys, one file a page; sound (and a video's sound) to WAV,
IMA ADPCM 4-bit mono at 8,000 or 22,050 samples/s; video to five JPEG still
pictures; text and other files compressed with zlib when that saves at least
10 %.

## 7. Pairing

A check of the plain sound path, independent of frames, so it works even when
no frame gets through. Either side starts it (Pair on its Link screen).

**The test sound** (3,190 ms, made at any rate; amplitudes of 32,767):

| From (ms) | Length | Sound |
| --- | --- | --- |
| 0 | 150 | lead-in, 21.7 kHz, 1,000 |
| 150 | 250 | marker A, 2 kHz, 9,000 |
| 400 | 100 | silence |
| 500 | 32 × 70 | steps, 6,000 each: 500, 1,000, 1,500, 2,000, 3,000 … 17,000 (every 1,000), 17,500, 18,000, 18,500, 19,000, 19,400, 19,800, 20,200, 20,400, 20,600, 20,800, 21,000, 21,200, 21,500 Hz |
| 2,740 | 100 | silence |
| 2,840 | 250 | marker B, 2 kHz, 9,000 |
| 3,090 | 100 | silence |

Every tone fades in and out over 5 ms.

**Hearing it.** The listener watches 2 kHz in 10 ms blocks; 150 ms above ten
times the background is marker A. For 4.5 s after that (the phone: 8 s, see below) it takes no other
marker (marker B and the 2 kHz step would otherwise look like new starts). 3.4 s later it reads its recording from
0.7 s before A, finds both markers exactly (5 ms Goertzel blocks, runs of at
least 120 ms above a quarter of the peak), and takes *scale* = (B − A) / 2.69 s:
the ratio of the listener's real sample rate to the rate it believes. Each step is measured over its
middle 50 ms at f / scale and compared with the same frequency in the
background just before the sound: the signal-to-noise ratio in dB.

**Loudness check (the phone, when pairing is started on it).** Before its
test sound the phone plays, with its microphone listening: 400 ms of
silence, then a TRAIN frame on SD at each of the peaks 0.9, 0.65, 0.45, 0.3,
0.2 and 0.13, with 250 ms between them. For each it measures what rises
between 1 and 17 kHz above the room (its microphone is next to its speaker,
and hears side-sounds far better than a person). It finds the loudest burst
that raised nothing by 3 dB or more, and uses the next quieter level; if none
was clean, or the bursts were not found, 0.13. (`tests/w3/LevelTest`.)

**The turns.** The starter plays its sound and listens for up to 10 s. A side
that hears a test sound while idle answers with its own. Once a side has both
measured the other and played, it sends PAIR_REPORT.

**PAIR_REPORT** (0x34): version (1) = 1, steps (1) = 32, then 32 bytes of
dB + 20 (0 to 255), scale × 10,000 (2), the peak in % of full scale (1),
clipped (1, 0 or 1), the loudness step chosen + 1 (1, 0 = none), how clean
that step arrived in dB + 20 (1): 40 bytes in all.

**Decisions.**

- The handheld measures the phone's silent band (20.0–21.2 kHz) below 12 dB:
  it keeps its fast down receiver on (the phone will answer there).
- The phone is told its silent band (20.0–21.2 kHz) reaches the handheld at
  below 12 dB, while 0.5–12 kHz is at least 15 dB: it sends on FD whatever it
  would send on SD.
- The handheld is told its silent band (20.2–21.2 kHz) reaches the phone at
  below 15 dB, while 1–12 kHz is at least 15 dB: it types on FU.

The decisions are kept until the next pairing.

**The loudness ladder (the handheld, after its test sound).** 150 ms after
its test sound the handheld plays a TRAIN frame on SU narrow at each of the
peaks 29,000, 20,500, 14,500, 10,250, 7,250 and 5,100 (3 dB apart), with
150 ms between them; its whole turn is 6.65 s. It cannot judge them itself
(its microphone is closed while it plays). The phone reads the recording from
0.3 s before the end of the test sound, finds the six bursts in the silent
band, and lets its own receiver read each TRAIN frame: the average SNR of the
data carriers, which counts the room's noise and the speaker's distortion
alike. From the quietest step it read, it goes one step louder only while
that step reads at least 2.5 dB better (less means the speaker already bends),
and stops at 22 dB; then, while the chosen step raises the audible range
(1–17 kHz) by 3 dB or more over the room, it takes the next quieter one. The
choice goes back in PAIR_REPORT; the handheld keeps it as its silent
loudness, also after it is closed. A phone that starts pairing waits until it
has read the handheld's ladder before it reports. (`tests/w3/LadderTest`.)

**The handheld's microphone rate.** Until it is known, the handheld uses the
rate its sound card claims. While listening it measures the rate from whole
buffers delivered (a stretch of at least 8 s; a result more than 5 % from the
claim is ignored). Pairing measures it exactly (*scale*, between 0.95 and
1.05). The rate found is kept, also after the program is closed; once known, a
later measurement that differs by more than 1 % is shown on the Link screen
but not used.

**Markers on the phone.** For 8 s after marker A the phone takes no other
marker (the handheld's ladder would otherwise look like a new start).
