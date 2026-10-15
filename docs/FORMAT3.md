# The HPC Whisper sound format, version 3

Version 3 carries typing, files and a remote over four sound channels. It
replaces neither the version 2 format (`FORMAT.md`) nor its receivers: a
phone running HPC Whisper 3 still reads version 2, so an older handheld
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
rate it claims: the HP Jornada 720 says 44,100 when recording but delivers
about 43,230 to 43,310 samples per second (1.8 % fewer).

- **Symbol**: 512 samples (10 ms) plus a cyclic prefix of 128 samples
  (2.5 ms), 640 samples (12.5 ms) in all. Carrier *b* is at *b* × 100 Hz.
- **Carriers** are switched on or off and phase-shifted per symbol. A carrier
  carries bits in how much its phase turns from one symbol to the next
  (differential phase-shift keying), so the room's effect on its phase
  cancels out.
- Each symbol is extended by 26 samples (0.5 ms) past its end and fades in and out (raised
  cosine) inside its cyclic prefix and that extension, which overlaps the
  next symbol's prefix. The 512 samples a receiver reads are untouched.

### Channels

| Channel | Direction | Carriers (bins) | Count | Pilots (indices) | Default bits |
| --- | --- | --- | --- | --- | --- |
| SU narrow (default) | handheld → phone | even bins 200–212 (20.0–21.2 kHz) | 7 | 0, 6 | 2 |
| SU wide | handheld → phone | even bins 182–212 (18.2–21.2 kHz) | 16 | 0, 15 | 2 |
| SD | phone → handheld | even bins 194–208 (19.4–20.8 kHz) | 8 | 0, 7 | 2 |
| FU | handheld → phone | bins 10–189 (1.0–18.9 kHz) | 180 | every 10th, and the last | 1 |
| FD | phone → handheld | bins 5–119 (0.5–11.9 kHz) | 115 | every 10th, and the last | 1 |

Silent carriers are 200 Hz apart so that a handheld's ghost tones (the
Jornada 720 adds one 900 Hz below every tone) fall between them. SU narrow
stays at 20 kHz and above, inaudible at 50 % volume; SU wide is faster and may
be faintly audible to some. SD sits where the Jornada's microphone hears
best above 19 kHz (test 2); it overlaps SU, so the two sides take turns
(section 5).

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

Symbols are scaled so that their RMS level is a third of the chosen peak and
then clipped at that peak. Defaults: silent channels 0.5 of full scale on the
handheld (HPC Whisper's 50 %), fast channels 0.125 (quarter loudness, test 2).

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
| 0x10 | FILE_OFFER | file id (2), size (4), packets (2), kind (1), name (UTF-8) | FD or FU |
| 0x11 | FILE_DATA | file id (2), packet (2), data (up to 1,024) | FD or FU |
| 0x12 | FILE_NEED | file id (2), flags (1), then missing packets (2 each, up to 32) | the other direction |
| 0x13 | FILE_CANCEL | file id (2) | either |
| 0x20 | SCREEN | update (2), flags (1), then a zlib stream of tiles | FD |
| 0x21 | INPUT | kind (1), then by kind (below) | SU |
| 0x30 | TRAIN | 24 symbols of fixed pattern, no RS (below) | the channel trained |
| 0x31 | MAP | channel (1), map number (1), carriers (1), 2 bits per carrier | the other direction |
| 0x32 | HELLO | version (1), can-hear (1), can-play (1) | either |

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

**INPUT kinds**: 1 tap (x, y as 2 bytes each, in the remote picture's
pixels), 2 long press (x, y), 3 swipe (x1, y1, x2, y2), 4 view (mode, zoom x,
zoom y, 2 bytes each), 5 refresh, 6 remote start, 7 remote stop.

**FILE_NEED flags**: bit 0 "all received", bit 1 "send the offer again".

**TRAIN**: after the header, 24 symbols in which every carrier, pilots
included, turns by the 2-bit value `P[(3c + 11s) mod 256]` (quarter turns) in symbol *s*.
The receiver measures each carrier's phase error and replies with a MAP:
phase signal-to-noise of at least 23 dB → 3 bits, 16 dB → 2, 10 dB → 1,
less → 0.

**SCREEN tiles** (in the zlib stream): repeated records of x (1), y (1) in
16-pixel tile units, then 128 bytes of 4-bit grey pixels, two per byte, rows
top to bottom. A record with x = 255 ends the stream; y then gives the
picture's width in tiles and the next byte its height.

## 4. Link check

1. Each side says HELLO on its silent channel when it starts.
2. To use a fast channel, the sender sends TRAIN; the receiver answers with
   MAP on its own silent channel; from then on the sender uses that map.
3. When too many frames fail, the receiver sends a new MAP, or map 0.

## 5. Taking turns

SU and SD share a band, and a device hears its own sound loudly. So:

- A device does not listen while it plays, nor for 50 ms after.
- The phone answers (TEXT_ACK, FILE_NEED, MAP) only after 150 ms without
  hearing the handheld.
- A file sender sends 16 packets, then waits up to 1.5 s for FILE_NEED before
  going on.
