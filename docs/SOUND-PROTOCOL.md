# HPC Whisper sound protocol, version 2 (with the return channel)

A complete specification for building a new sender or receiver, on any device.
It carries bytes (text, mostly) from one device's loudspeaker to another's
microphone, in near-ultrasound (18–21.5 kHz), so nobody hears it. A second,
very small frame type goes back the other way (the acknowledgement) so the
sender can stop repeating what has arrived.

Reference code in this repository (all three are checked against each other
by `tests/`):

| File | Role |
| --- | --- |
| `handheld/wmodem.pas` | sender, integer arithmetic only (Free Pascal, Windows CE ARM) |
| `handheld/ackrx.pas` | acknowledgement receiver for the sender side (integer arithmetic only) |
| `modem.js` | receiver (browser) + sender and test-signal generator, the easiest to read |
| `android/.../Receiver.java`, `Ack.java` | receiver and acknowledgement sender for Android |

This file is self-contained: with it, and the test vectors in section 12, you
can write an interoperable implementation without the code.

---

## 1. What the protocol does, in one paragraph

The sender owns a **document**: a growing byte string (what the user has typed
so far on the current page). It cannot know whether the receiver heard
anything, so it sends **frames** that each say: *"the document is L bytes long,
and from offset o it reads these n bytes"*. The receiver keeps a **mirror** of
the document and writes each frame's bytes into it. A lost frame only leaves a
gap that a later repeat fills in. Optionally the receiver answers with a
silent **acknowledgement** that says how much of the document it holds without
a gap; the sender then stops repeating that part and resends only what is
missing. Without any answer the sender simply repeats everything a fixed
number of times, so a receiver that cannot talk back still works.

Everything is **one-way and stateless per frame**: any frame can be decoded
alone, in any order, any number of times.

---

## 2. Physical layer: tones

- **Grid:** 36 tones, 100 Hz apart: `f(t) = 18000 + 100·t` Hz, `t = 0 … 35`
  (18.0 … 21.5 kHz).
- **Band:** 16 neighbouring grid tones. A band starts at 18000, 18500, 19000,
  19500 or 20000 Hz. Tone *v* (0…15) of a band starting at *B* is `B + 100·v`.
  Four bands start 500 Hz apart, so they overlap; the sender uses one band
  per frame.
- **Symbol:** one tone = one 4-bit value (a *nibble*, 0…15). Exactly one tone
  is on at any moment (frequency-shift keying with 16 tones, "16-FSK").
- **Symbol duration** ("speed"): 48 ms (Slow), 32 ms (Normal), **20 ms (Fast,
  sender default)**. Symbol *k* of a frame starts at sample
  `floor(k · rate · ms / 1000)` from the frame start.
- **Waveform:** a sine whose **phase is continuous** from one symbol to the
  next (accumulate phase: `ph += 2π·f_k/rate` every sample; never reset it).
  Fade in and out over 5 ms (linear ramp) at the frame ends.
- **Gap between frames:** at least 60 ms of silence.
- **Sample rate:** the sender may use any rate; the reference sender plays
  44,100 samples/s. Receivers should listen at 44,100 Hz or more (48 kHz is
  fine: 21.5 kHz is below Nyquist for both).
- **Amplitude:** constant; leave headroom (reference: volume setting 10–100 %).
  Amplitude carries no information.

### Raw speed

A frame with *n* text bytes has `B = ceil((n+4)·2 / 11)` body blocks and lasts

```
symbols  = 8 + 15·(B + 1)
duration = symbols · symbol_ms   (+ 60 ms gap)
```

Largest frame (n = 44, B = 9): 158 symbols → 3.2 s at 20 ms, 5.1 s at 32 ms,
7.6 s at 48 ms → about **13.8, 8.7 or 5.8 text bytes/s** while a frame is
playing, before any repeats. The sender keeps frames short (≤ 22 bytes) when
repeating, because short frames survive noise more often.

---

## 3. Frame layout

```
| preamble (8 symbols) | interleaved Reed-Solomon blocks: header + B body blocks |
```

### 3.1 Preamble

Fixed 8 symbols (tone numbers within the band): `0 15 0 15 11 4 11 4`.
Used to find the frame, its band, its speed and its exact start. A receiver
should accept it with up to two of the eight symbols drowned out.

### 3.2 Header block (block 0): 11 nibbles of data

| Nibbles | Meaning |
| --- | --- |
| 0 | format version = **2** (nibble value 2) |
| 1–2 | *n*, number of text bytes in this frame, 0…44 (high nibble first) |
| 3–4 | sequence number, 8 bits (+1 per frame, wraps at 256) |
| 5–6 | document id, 8 bits (changes whenever a new page starts) |
| 7–10 | *L*, the document's total length in bytes, 16 bits (high nibble first) |

### 3.3 Body: bytes → nibbles → blocks

Body bytes, in order:

| Bytes | Meaning |
| --- | --- |
| 0–1 | *o*, offset in the document of the first text byte (16 bits, high first) |
| 2 … n+1 | the text: document bytes *o … o+n−1* (UTF-8 for text) |
| n+2, n+3 | CRC-16 (high byte first), see 3.4 |

Turn each byte into two nibbles (high first). Pad with zero nibbles up to a
multiple of 11. Cut into *B = ceil((n+4)·2 / 11)* groups of 11 nibbles: the
data of body blocks 1…B.

### 3.4 CRC-16

CCITT: polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR,
processed MSB first. Computed over these bytes, in order:

```
n, seq, doc, L_high, L_low, o_high, o_low, text[0..n-1]
```

(`n`, `seq`, `doc` as single bytes; `seq` and `doc` are the same 8-bit values
that appear in the header.) A frame is accepted **only if the CRC matches**:
Reed-Solomon corrects symbols, the CRC guards against a wrong correction.

### 3.5 Reed-Solomon code

Each block is one RS(15,11) code word over GF(16): 11 data nibbles + 4 check
nibbles = 15 nibbles = 15 symbols.

- Field GF(2⁴), primitive polynomial **x⁴ + x + 1 (0x13)**, α = 2.
  `EXP = 1,2,4,8,3,6,12,11,5,10,7,14,15,13,9` (then repeats), `LOG` its inverse.
- Generator: g(x) = (x − α)(x − α²)(x − α³)(x − α⁴).
  Expanded (highest power first): `GEN = [1, 13, 12, 8, 7]`.
- **Systematic**: the 15-nibble word is the 11 data nibbles followed by the 4
  check nibbles, which are the remainder of `data(x)·x⁴ ÷ g(x)`, highest
  power first. Reference encoder (nibbles as ints, `mul` = GF multiply):

```js
function rsEncode(d) {                 // d: 11 nibbles
  const r = d.concat([0, 0, 0, 0]);
  for (let i = 0; i < 11; i++) {
    const c = r[i];
    if (c) for (let j = 1; j < 5; j++) r[i + j] ^= mul(GEN[j], c);   // GEN = [1,13,12,8,7]
  }
  return d.concat(r.slice(11));
}
```

- A block corrects *e* wrong symbols plus *f* erasures (symbols the receiver
  marks "unreliable") as long as **2e + f ≤ 4**. Syndromes are
  `S_i = word(α^i)`, i = 1…4. Decoders in `modem.js` (`rsDecode`, with
  erasures) and `handheld/ackrx.pas` (`RsDecode15`) are the references.

### 3.6 Interleaving

The header block and the B body blocks are **interleaved**: there are
K = B + 1 blocks; after the preamble, symbol position *t* (0-based) carries
symbol `floor(t / K)` of block `t mod K` (block 0 is the header). Total
symbols after the preamble: 15·K. A burst of noise or a dropout therefore
hits each block only a little and RS can repair it.

```js
function encodeFrame(f) {              // f = {seq, doc, L, o, bytes}
  const n = f.bytes.length;
  const head = [2, n>>4, n&15, (f.seq>>4)&15, f.seq&15, (f.doc>>4)&15, f.doc&15,
                (f.L>>12)&15, (f.L>>8)&15, (f.L>>4)&15, f.L&15];
  const all  = [n, f.seq&255, f.doc&255, (f.L>>8)&255, f.L&255, (f.o>>8)&255, f.o&255, ...f.bytes];
  const crc  = crc16(all);
  const body = nibbles([(f.o>>8)&255, f.o&255, ...f.bytes, crc>>8, crc&255]);
  const B = Math.ceil((n+4)*2/11);
  while (body.length < B*11) body.push(0);
  const words = [rsEncode(head)];
  for (let k = 0; k < B; k++) words.push(rsEncode(body.slice(k*11, k*11+11)));
  const K = B + 1, sym = [0,15,0,15,11,4,11,4];
  for (let t = 0; t < K*15; t++) sym.push(words[t % K][Math.floor(t / K)]);
  return sym;                          // tone numbers 0..15 of the chosen band
}
```

Limits: n ≤ 44 per frame; document length L ≤ 65,535 bytes; offsets 16 bit.

---

## 4. Meaning: the mirror

Each frame says: *the document is L bytes long; from offset o it reads these
bytes.* A receiver keeps `bytes[]`, `known[]` and the current `doc` id and `L`:

1. If the frame's `doc` differs from the stored one: **a new page.** The old
   document is finished; clear everything (`known` all false), set `doc`.
2. Set `L := frame.L`. If it got shorter, forget bytes beyond the new length
   (the sender pressed Backspace / replaced text).
3. For i in 0 … n−1 with `o+i < L`: `bytes[o+i] := text[i]`, `known := true`.
   (Overwrite even if known: the sender may have edited those bytes.)

Bytes never received are **missing** (known = false), not wrong. Receiving the
same frame twice is harmless. Duplicate frames with the same `seq` heard by
two microphones are harmless too.

**What a receiver should do with it** (the Android keyboard's behaviour):
act only on the **contiguous known prefix**. Type/emit byte *i* only after
bytes 0…i−1 are all known. A gap that stays unfilled for **30 seconds** is
given up (shown as a mark, then skipped) so one lost piece cannot block the
text behind it forever. If the document gets shorter, the receiver reconciles
with what it already emitted (e.g. sends Backspaces).

### Keys inside the text

Non-text keys travel in the document as private-use characters: U+E000 + code,
encoded as UTF-8 (`EE 80..8F xx`). The code is 10 bits: the low 8 bits name
the key (arrows, Home, End, Delete, Tab, Esc, Ctrl+A/C/X/V/Z/Y, Send, Back,
phone Home, Recents), `0x100` adds Shift and `0x200` adds Ctrl for movement and
delete keys. A key is "pressed" once, when all bytes before it are known. An
app that only wants plain text can ignore this section and treat U+E000–U+E3FF
as control codes.

---

## 5. Sender policy (what the reference sender does)

The sender counts, **for every byte of the document, how many times it has
gone out**.

- **New text goes out at once.** Bytes that have been sent fewer than twice
  ride along in the frame, so while the user types every character goes out
  twice anyway.
- **In pauses it repeats** the least-sent bytes among the **last 300 bytes**
  (`RECENT_BACK`), in frames of **at most 22 bytes** (short frames get through
  more often). The delay before the *k*-th send of a byte: the 2nd after
  0.4 s, then 1.5, 3, 6, 10, 15, 22 s for the 3rd…8th.
- **Default: 6 sends** per byte (setting range 2–8).
- **Second band:** every second send uses another band, 1 kHz away from the
  first (the reference defaults are first band 19.0 kHz (19.0–20.5 kHz) and second band 18.0 kHz;
  any band 1 kHz away works). A weak
  spot or noise on one band then doesn't hit all copies.
- **Resend** (user action): all of the last 300 bytes again from the start.
- A **new page** gets a new `doc` id (increment mod 256) and `L` restarts at 0.
- `seq` increments for every frame sent (wraps at 256).

Simulated (every frame lost at random): complete delivery in all runs up to
10 % loss, about 96 % at 30 % loss (with 6 sends).

---

## 6. Receiver algorithm (practical guidance)

Any method that satisfies the framing above is fine. This is the proven one
(`modem.js` → `Receiver`, ported in `Receiver.java`):

1. **Measure each of the 36 grid tones every 1 ms** (`rate/1000` samples):
   keep a running complex sum per tone (multiply the sample by a rotating
   phasor at that tone's frequency; advance the phasor by multiplication and
   renormalise now and then). Store per-tone prefix sums (12 s of history).
   The power of any tone over any window is then the difference of two sums,
   so searching is cheap. Remove the DC component first.
2. **Search for the preamble continuously**, in each band (5) and speed (3)
   and over start offsets, even while another frame is being read. In each of
   its 8 symbol windows the expected tone should be the strongest of the band's
   16, or a close second. Measure each symbol from **25 % to 90 %** of its
   duration (the start of a symbol still contains echo of the previous one).
   Score = how well the 8 windows match; keep the best candidate per band/speed
   until it stops improving (about one symbol), then decode.
3. **Ghosts.** Some sound chips resample crudely and add a faint copy of every
   tone at a fixed distance (the HP Jornada 720 adds one 900 Hz *lower*: half
   as strong as the main tone at 20 kHz, up to five times stronger at
   21.5 kHz where the speaker is weak). The preamble's tones are known, so
   measure the ghosts there (strength relative to the tone, per distance, per
   tone; interpolate in between), keep only those that show every time and
   stand far above the background, then decide each symbol by comparing every
   candidate's expected pattern (tone + ghosts) with what was heard, rather
   than just taking the loudest tone.
4. **Decode:** try the frame at each possible size *B* (1…10), smallest first,
   as soon as `8 + 15·(B+1)` symbols have been heard. Read symbols, de-interleave
   into blocks, RS-decode every block. A block that fails is retried with its
   least certain symbols (smallest share of their band's power) marked as
   erasures, one to four of them. Check the **CRC**; accept only on a match
   (and `version == 2`, `n ≤ 44`, `n` consistent with `B`).
5. **Dropouts.** If no size works, the sender's sound may have stopped for a
   moment (a USB/audio hiccup), which delays every later tone: at the sizes
   where the sound actually ended, try each place and length of such a gap
   and keep the one that passes the CRC.
6. **Dedup:** the same frame is often decoded twice (two microphones, or two
   candidate offsets): ignore a frame whose start sample is the same as one
   already accepted.
7. **Do not use automatic gain control, noise suppression or echo cancellation**
   on the microphone: they eat ultrasonic tones. On Android use
   `AudioSource.UNPROCESSED` if the phone supports it, else `VOICE_RECOGNITION`;
   record stereo if possible and run a receiver per channel. On the web,
   `getUserMedia` with `echoCancellation`, `noiseSuppression`, `autoGainControl`
   all `false`, and a sample rate of 44.1 or 48 kHz.

### Practical facts measured on real hardware

- The HP Jornada 720's sound chip actually runs at about **43,200 Hz** while
  Windows says 44,100: every tone comes out ~2 % low (still inside the 100 Hz
  grid; a receiver can ignore it, a sender can compensate by synthesising at
  43,200).
- The Jornada's microphone is flat from 0.5 to 13.25 kHz and works up to about
  20.5 kHz with strong automatic gain (settles in 100–250 ms when the signal is
  strong, climbs slowly when weak): the **first symbols of a frame after
  silence may be weak**. The preamble is what the receiver uses to calibrate;
  keep ≥ 60 ms of silence, and for the return channel send a sound shortly
  before so the gain is settled.
- On that microphone 19.0–20.5 kHz decoded cleanly; 17.0–18.5 kHz was poor.

---

## 7. The return channel (acknowledgement)

A small frame the receiver ("phone") sends back so the sender ("handheld")
knows what arrived.

### 7.1 Physical frame

- **Same preamble** (`0 15 0 15 11 4 11 4`), then **one** RS(15,11) block
  (not interleaved: there is only one).
- **Band:** 19000 Hz (tones 19.0 … 20.5 kHz). Symbol **32 ms**.
- Length: 8 + 15 = **23 symbols = 736 ms** (+ 40 ms of fades/padding = 0.78 s).
- Waveform as in section 2 (continuous phase, 5 ms ramps, 20 ms of silence
  before and after). The reference phone plays it on the media stream at 48 kHz,
  amplitude 0.8.

### 7.2 The 11 data nibbles

| Nibbles | Meaning |
| --- | --- |
| 0 | frame type = **1** (acknowledgement) |
| 1–2 | document id (8 bits) |
| 3–6 | **P**, 16 bits: bytes from the start of the document held **without a gap** |
| 7 | **G**, 4 bits: bytes **missing** immediately after P (0…15; 15 means "15 or more"); 0 if everything up to *L* is held |
| 8–10 | **hash**, 12 bits |

Note: nibble 0 = type 1 versus 2 for data frames, so a data receiver never
mistakes an acknowledgement for a data frame (its CRC cannot match either).

### 7.3 Computing P, G and the hash (receiver)

```
P = length of the contiguous run of known bytes starting at offset 0
G = number of consecutive missing bytes starting at P (capped at 15), 0 if P == L
hash = CRC16-CCITT(  doc, P>>8, P&255, G&15, bytes[0] … bytes[P-1] ) & 0xFFF
        (same CRC as 3.4, start 0xFFFF; the 4 + P input bytes are fed in this order)
```

Bytes **given up on** (skipped after 30 s) do **not** count as held, so the
sender keeps trying to fill them. Do not send an acknowledgement while the
receiver holds no document (`L = 0` or no frame yet).

### 7.4 What the sender does with it

On an acknowledgement with `doc == its current document id` and not within
3 s after the sender itself edited already-acknowledged text:

1. **Verify:** `P ≤ L_sender` and the hash equals the hash of the *sender's*
   own first P bytes (same formula). If not (the phone holds older text, an
   earlier page, or the frame was misread) → do **not** believe it: lower the
   send counts of the last 300 bytes so they are sent again, allow it up to
   5 times in a row, and treat as "no useful answer".
2. **Believe:** `acked = max(acked, P)`. Bytes below `acked` need no more
   sending (stop repeating them). If `G > 0` and `P < L`, **send the gap
   `[P, P+G)` again at once** (frame length ≤ G).
3. If `acked == L`: the document is **delivered** (the UI shows "Delivered").
4. When the sender edits (Backspace) text below `acked`, it lowers `acked` to
   the new length and ignores acknowledgements for 3 s (`ACK_IGNORE_MS`), since
   the phone's answer may describe the old text.

### 7.5 Timing

- **Receiver:** send an acknowledgement about **700 ms after the last frame of
  a group** was heard and nothing else is arriving (no frame, no unreadable
  frame since); at most once per second; never while its own sound is
  playing. Mute its own receiver during playback plus **150 ms**, because its
  microphone hears its own speaker.
- **Sender:** after each frame ends, wait up to **2.6 s** (`ACK_WAIT_MS`) for
  an acknowledgement before sending repeats (new text is still sent at once).
  After **two windows in a row without one**, stop waiting and repeat on the
  old schedule (a receiver that cannot or does not answer). Any acknowledgement
  that arrives resets this.
- The sender's microphone must be open while it plays (the Jornada's sound
  driver may not allow this; then it falls back as above).

Simulated gain (10 % frame loss, 100 runs): 64 frames and ~132 s instead of
104 frames and ~256 s; with every acknowledgement lost the sender still
completes (107 frames).

---

## 8. Versioning and compatibility

- Data frames carry `version = 2` in header nibble 0. Ignore other values.
- The acknowledgement uses type 1 in nibble 0 in its own band (19 kHz) and is
  silent to a data receiver; old receivers (no acknowledgement) keep working
  because the sender falls back after two missed windows.
- To use another frequency range, change `GRID_START` (and the band starts).
  Nothing else depends on it, but the ghost and microphone findings above
  were measured at 18–21.5 kHz; re-measure for audible ranges.

---

## 9. Minimal sender, step by step

1. Hold the document as bytes; a `doc` id (0–255), `seq` counter, send counts.
2. To send a piece: `encodeFrame({seq, doc, L, o, bytes})` → symbols →
   `synth` (continuous-phase sine per symbol at `band + 100·sym` Hz,
   5 ms fades) → play, then ≥ 60 ms silence; `seq++`.
3. Schedule repeats per section 5; if you listen for acknowledgements, apply
   section 7.4.

```js
function synth(symbols, rate, band, speed /*s*/, amp) {
  const n0 = Math.round(rate*0.02), nSym = Math.round(symbols.length*speed*rate);
  const out = new Float32Array(nSym + 2*n0), fade = Math.round(rate*0.005);
  let ph = 0;
  for (let i = 0; i < nSym; i++) {
    const k = Math.min(symbols.length-1, Math.floor(i/(speed*rate)));
    ph += 2*Math.PI*(band + symbols[k]*100)/rate;
    let e = 1; if (i < fade) e = i/fade; else if (i > nSym-fade) e = (nSym-i)/fade;
    out[n0+i] = amp*e*Math.sin(ph);
  }
  return out;
}
```

## 10. Minimal receiver, step by step

1. Capture raw microphone audio (no processing) at ≥ 44.1 kHz.
2. Run the tone measurement and preamble search of section 6.
3. For each candidate, decode (6.4), check CRC, de-duplicate.
4. Apply the frame to the mirror (section 4); emit text from the contiguous
   prefix; give up gaps after 30 s.
5. Optionally, ~700 ms after the last frame, send the acknowledgement (section 7).

## 11. Where it breaks (design limits)

- Document length ≤ 65,535 bytes per page; ≤ 44 bytes per frame.
- A page is one document; for a new page change the `doc` id.
- No encryption or authentication: anyone with a microphone nearby can read
  the text. Add your own layer if you need secrecy.
- The sender must not edit text the receiver has already emitted without
  accepting that the receiver can only reconcile by backspacing (section 4).

## 12. Test vectors (from `modem.js`)

Tone numbers within the band (0…15); for a frame at band *B*, the frequency
is `B + 100·value`.

**RS(15,11)** – data `0 1 2 3 4 5 6 7 8 9 10` → check nibbles `12 14 8 3`:
word `0 1 2 3 4 5 6 7 8 9 10 12 14 8 3`.

**Data frame**, text `Hello`, `seq = 1`, `doc = 7`, `L = 5`, `o = 0`
(n = 5, B = 2, K = 3, 53 symbols; CRC-16 = `0xCD83` over bytes
`05 01 07 00 05 00 00 48 65 6C 6C 6F`):

```
0 15 0 15 11 4 11 4  2 0 12 0 0 6 5 0 15 0 0 12 1 4 13 0 8 8 7 6 3 0 5 0 0 6 0 0 12 0 5 6 0 9 15 0 0 15 14 14 11 4 12 11 0
```

**Empty frame** (n = 0, seq = 2, doc = 7, L = 5, o = 0; B = 1, 38 symbols):

```
0 15 0 15 11 4 11 4  2 0 0 0 0 0 0 0 2 15 0 6 7 10 0 10 0 0 0 0 5 0 3 15 0 10 5 5 9 1
```

**Acknowledgement** for document 7 when the receiver holds `Hello`
completely (P = 5, G = 0): hash = 2984 (`0xBA8`):

```
0 15 0 15 11 4 11 4  1 0 7 0 0 0 5 0 11 10 8 4 8 4 7
```
(play at band 19000 Hz, 32 ms per symbol)

Run `node tests/test_ack_java.js`, `node tests/test_frames.js` and the other
tests in `tests/` to check an implementation against the reference: each
generates frames with `modem.js`, passes noisy audio through the receiver
under test and compares the decoded text.
