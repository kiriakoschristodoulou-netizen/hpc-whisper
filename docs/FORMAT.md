# The J720 Whisper sound format

Everything needed to write a sender or a receiver for any device. The reference
code is `jornada/wmodem.pas` (sender, whole numbers only) and `modem.js`
(sender for tests, and the receiver).

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
- The Jornada plays at 44,100 samples per second; the receiver may listen at
  any rate of 44,100 or more.

## Frame

1. **Preamble**, 6 symbols: `0 15 0 15 4 11`.
2. **Data**, in blocks of 15 symbols.

The data bytes are:

| Byte | Meaning |
| --- | --- |
| 0 | length *n* of the text (0 to 48) |
| 1 | sequence number (0 to 255, one more for each frame) |
| 2 … *n*+1 | the text, UTF-8 |
| *n*+2, *n*+3 | CRC-16 of bytes 0 … *n*+1 (CCITT: polynomial 0x1021, start 0xFFFF, high byte first) |

Each byte becomes two nibbles, high nibble first. The nibbles are padded with
zeros to a multiple of 11 and cut into groups of 11. Each group becomes a
15-symbol block: the 11 nibbles, then 4 check nibbles of a Reed-Solomon
(15, 11) code over GF(16):

- field polynomial *x*⁴ + *x* + 1 (0x13), α = 2
- generator (*x* − α)(*x* − α²)(*x* − α³)(*x* − α⁴)
- systematic: the check nibbles are the remainder of the data polynomial
  · *x*⁴ divided by the generator, highest power first.

A block corrects up to 2 wrong symbols. Number of blocks: ⌈(*n* + 4) · 2 / 11⌉,
so a frame is 6 + 15 · blocks symbols long (21 to 156).

## Text

Plain UTF-8. Two control characters: **8** (backspace: remove the last
character received) and **10** (new line).

## Receiving, in brief

- Measure each grid tone in 1 ms steps (a running complex sum per tone), so
  any window's strength is a difference of two sums.
- Look for the preamble in every band and speed at once: in each of its six
  symbol windows, the expected tone must be the strongest of the band's 16.
  Use the middle of each symbol (from 25 % to 90 % of it), so echoes of the
  previous symbol do not count.
- Read the first block to learn the length, then the rest; correct each
  block; check the CRC.
- If the check fails, the sender's sound may have stopped for a moment (a
  gap delays every tone after it). Try each place and length of a gap
  around the first block that needed correcting, and keep one that passes.
- The same sequence number heard again within 1.5 s is an echo: show it once.
