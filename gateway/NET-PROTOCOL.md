# Whisper Net protocol, version 1

Internet for a handheld over the HPC Whisper sound link. Two programs:

- **Whisper Net** on the handheld (HP Jornada 720, Windows CE). It answers
  Windows' dial-up networking on the virtual serial port (PPP, as COM Probe
  1.6 proved), runs a small TCP/IP stack of its own, and sends only what
  matters over sound: "open a connection to this address", the bytes, "close",
  and name lookups.
- **Whisper Gateway** on the phone. It hears those messages, makes the real
  connections and lookups on the internet, and sends the answers back.

The sound link is slow (about 10 to 15 bytes per second each way), so nothing
that Windows' TCP needs to hear quickly (handshakes, acknowledgements,
retransmissions) crosses the air: the handheld answers it locally at once.

```
 Pocket IE ─ Windows TCP/IP ─ dial-up (PPP) ─ COMx: ═ whcom.dll ═ WSP1:
   ─ Whisper Net: PPP server, TCP/UDP stack, mux ─ link ─ sound ─╮
                                                                   │ air
   ╭───────────────────────────────────────────────────────────────╯
   ╰ Whisper Gateway: link ─ mux ─ sockets, DNS ─ internet
```

## 1. Sound

The physical layer and frame layout of `SOUND-PROTOCOL.md` (HPC Whisper,
version 2): 16 tones 100 Hz apart, one tone per symbol, phase-continuous,
5 ms fades; the preamble `0 15 0 15 11 4 11 4`; Reed-Solomon (15,11) over
GF(16) per block; header block and body blocks interleaved.

| Direction | Band | Symbol |
| --- | --- | --- |
| handheld → phone ("up") | 19.0 – 20.5 kHz | 20 ms |
| phone → handheld ("down") | 18.0 – 19.5 kHz | 20 ms |

Both can be changed in the programs' settings (the two sides must agree).
The handheld synthesises at the rate its chip really runs at (43,200).

## 2. Stream frames (frame version 3)

**Header block**, 11 nibbles:

| Nibbles | Meaning |
| --- | --- |
| 0 | version = **3** (the typer's frames are 2, acknowledgements 1) |
| 1–2 | flags (2 high bits) and n, the number of data bytes (6 low bits, 0…53) |
| 3–6 | ACK: the offset of the next byte this side expects from the other (16 bits) |
| 7–10 | OFF: the offset of this frame's first data byte in this side's stream (16 bits) |

Flags: `0x80` **TURN** (the last frame of the sender's turn: the other side
may speak), `0x40` **SYNC** (the sender has just started: see 3.3).

**Body**: the n data bytes, then CRC-16 (CCITT, start 0xFFFF, high byte first)
over `flags|n, ACK high, ACK low, OFF high, OFF low, data`. As nibbles (high
first), padded with zeros to a multiple of 11, `B = ceil((n + 2) · 2 / 11)`
blocks (1 to 10). A frame is `8 + 15 · (B + 1)` symbols: 0.76 s empty, 3.46 s
with 53 bytes at 20 ms.

## 3. The link

Each direction is an endless **byte stream**. Offsets count bytes from the
start of the stream, modulo 65,536 (compared with signed 16-bit differences;
far less than 32,768 bytes are ever in flight).

### 3.1 Sending

A side keeps the bytes it has sent but not yet seen acknowledged, from
`base` (the other side's last ACK) to `end`. In its turn it sends frames
starting **at base** (everything unacknowledged again: the last turn's frames
may have been lost), at most `MAXFR` frames (3) of at most 53 bytes, new bytes
after the old. Each frame carries the side's current ACK. The last frame has
TURN. With nothing to send it sends one empty frame (TURN, its ACK).

### 3.2 Receiving

A frame with `OFF ≤ next < OFF + n` gives the bytes from `next` on; `next`
moves to `OFF + n`. Older bytes are dropped, later ones (a gap) are dropped
too: they will come again from `base`. Every frame's ACK moves the receiver's
own `base` forward (when `base < ACK ≤ end`).

### 3.3 Start

A side that has just started sends SYNC in its frames until it has heard a
frame from the other side. A frame with SYNC tells the receiver to forget the
other direction's stream (`next` := the frame's OFF) and every connection
(4.2): the other side has restarted.

### 3.4 Turns

The handheld cannot play and record at once, so the two sides take turns.
The handheld leads.

- **Handheld:** closes the microphone, opens the output, 100 ms of silence,
  its frames (60 ms apart), 150 ms of silence, closes the output, opens the
  microphone. Then it listens: until a frame with TURN has been read and
  300 ms have passed; or, when nothing at all was heard, for 2.5 s; or, once
  something was heard but no TURN came, until the band has been quiet for
  1.2 s (at most 15 s). Then its turn again. When neither side has anything
  to send, its turns are spaced out (1, 2, 4, then every 6 s); any data
  brings them back to at once.
- **Phone:** speaks only after a handheld frame with TURN (500 ms after its
  end), or after handheld frames without one followed by 1.2 s of quiet.
  Before its frames: a 150 ms tone at 19.8 kHz (wakes its amplifier and
  settles the handheld's microphone gain), 50 ms of quiet. It ignores its own
  microphone while it plays and for 150 ms after.

## 4. The mux: what the streams carry

Messages, back to back in the stream. All numbers big-endian.

### 4.1 Up (handheld → phone)

| Type | Message | Fields |
| --- | --- | --- |
| 0x01 | OPEN | id (1), IPv4 address (4), port (2): open a TCP connection |
| 0x02 | DATA | id (1), length (1, 1–255), bytes |
| 0x03 | CLOSE | id (1): the handheld will send no more (its program closed) |
| 0x04 | ABORT | id (1): forget the connection at once |
| 0x05 | DNS | query id (1), length (1), name (ASCII): look up IPv4 addresses |
| 0x06 | UDP | id (1), IPv4 address (4), port (2), length (1), bytes: send a datagram, return the replies (5 s) |
| 0x07 | HELLO | version (1) = 1 |

### 4.2 Down (phone → handheld)

| Type | Message | Fields |
| --- | --- | --- |
| 0x81 | OPENED | id (1): the connection is up |
| 0x82 | DATA | id (1), length (1, 1–255), bytes |
| 0x83 | CLOSE | id (1): the other end closed (after its data) |
| 0x84 | FAIL | id (1), reason (1): 1 refused, 2 no route or timeout, 3 reset |
| 0x85 | DNS_ANSWER | query id (1), count (1, 0–4), IPv4 addresses (4 each) |
| 0x86 | UDP_REPLY | id (1), length (1), bytes (from the address the datagram went to) |
| 0x87 | HELLO | version (1) = 1 |

Connection ids are chosen by the handheld (1–63) and reused only after
CLOSE both ways, ABORT or FAIL. The phone sends a connection's data in turns
fairly with the others, DNS answers first.

## 5. The handheld's own network

| | |
| --- | --- |
| Handheld (given by IPCP) | 192.168.55.2 |
| Whisper Net (gateway, DNS) | 192.168.55.1 |

- **TCP** to any address: answered locally at once (SYN-ACK), so Windows
  never waits for the sound; OPEN goes up. If FAIL comes back, the connection
  is reset. Data from Windows is acknowledged as it is taken into a buffer
  (4 KB per connection); the window Windows sees is the free part of it.
- **DNS** (UDP port 53 to any address): A questions go up as DNS messages;
  answers are kept for 10 minutes. AAAA and other questions get an empty
  answer at once.
- **Other UDP** (NTP and the like): UDP messages. Broadcasts and NetBIOS are
  dropped.
- **ICMP echo** to 192.168.55.1 is answered locally.
