unit wmodem;
{ HPC Whisper sound format (version 2), sending side. Must match modem.js
  and docs/FORMAT.md.

  Tones on a 100 Hz grid; a band is 16 neighbouring tones starting at
  BAND_HZ[b]. One tone per symbol = 4 bits. Frame: preamble (8 symbols),
  then a header block and the body blocks, all interleaved. Each block is a
  Reed-Solomon (15,11) code word over GF(16).

  A frame carries a piece of the document: "the document is L bytes long,
  and from offset o it reads ...". The sender (TSender) counts how many times
  every byte has gone out: new text goes at once (with the last bytes that
  went out only once), and in every pause the text is sent again, the least
  sent first, spaced further and further apart, until each byte has gone out
  as often as the repeats setting says. Odd and even sends can use different
  bands. A frame lost on the way only leaves a gap on the phone that fills in
  a moment later.

  Keys that are not letters (arrows, Tab, Ctrl+C...) go into the document as
  characters from Unicode's private area, U+E000 + code (docs/FORMAT.md).

  The tone maker works in whole numbers only (the StrongARM has no floating
  point): a phase counter and a 4096-step sine table. }
{$mode objfpc}{$H+}
interface

const
  NBANDS = 5;
  BAND_HZ: array[0..NBANDS - 1] of Integer = (18000, 18500, 19000, 19500, 20000);
  NSPEEDS = 3;
  SPEED_MS: array[0..NSPEEDS - 1] of Integer = (48, 32, 20);
  SPEED_NAME: array[0..NSPEEDS - 1] of string = ('Slow', 'Normal', 'Fast');
  STEP_HZ = 100;
  MAXLEN = 44;                       { text bytes in one frame }
  MAXSYM = 8 + 15 + 9 * 15;
  PREAMBLE: array[0..7] of Byte = (0, 15, 0, 15, 11, 4, 11, 4);
  FORMAT_VERSION = 2;
  DOCMAX = 16000;                    { bytes in one document; then a new one starts }
  LIVE_MAX = 12;                     { while typing, frames stay short: less lag }
  REPAIR_MAX = 22;                   { repeats go in shorter frames: more of them get through }
  RECENT_BACK = 300;                 { only this much of the end of the document is sent again }
  MAX_SENDS = 8;                     { the most times a byte can be asked to go out }
  DEFAULT_SENDS = 6;
  ACK_WAIT_MS = 2600;                { after a frame, the repeats wait this long for the phone's acknowledgement }
  CHECK_MS = 30000;                  { an idle, fully acknowledged page is checked with the phone this often (an empty frame asks for an acknowledgement) }
  ACK_IGNORE_MS = 3000;              { after text that was acknowledged is changed, older acknowledgements are not believed }
  { how long the text must have been left alone before it goes out for the 2nd, 3rd... time }
  SEND_AFTER_MS: array[1..MAX_SENDS - 1] of LongWord = (400, 1500, 3000, 6000, 10000, 15000, 22000);

  { keys (docs/FORMAT.md): U+E000 + code; Shift and Ctrl add $100 and $200 to the movement and delete keys }
  KEY_BASE = $E000;
  KEY_SHIFT = $100; KEY_CTRL = $200;
  K_BACKSPACE = $08; K_TAB = $09; K_SHIFT_TAB = $0A; K_ESC = $1B; K_PGUP = $21; K_PGDN = $22;
  K_END = $23; K_HOME = $24; K_LEFT = $25; K_UP = $26; K_RIGHT = $27; K_DOWN = $28; K_DELETE = $2E;
  K_SELALL = $41; K_COPY = $43; K_PASTE = $56; K_CUT = $58; K_REDO = $59; K_UNDO = $5A;
  K_SEND = $80; K_BACK = $81; K_HOMESCREEN = $82; K_RECENTS = $83;

type
  TFrame = record
    sym: array[0..MAXSYM - 1] of Byte;
    n: Integer;
    alt: Boolean;                    { this send goes on the second band }
    off, len, docL: Integer;         { what the frame says: bytes off..off+len of a document of docL bytes }
  end;

  { the tone maker: plays one frame, then silence }
  TToneMaker = record
    rate: Integer;
    band, speed, volume: Integer;    { band and speed index; volume 0..100 }
    frame: TFrame;
    playing: Boolean;
    pos: LongInt;                    { samples since the frame started }
    k: Integer;                      { current symbol }
    nextAt: LongInt;                 { sample where symbol k+1 starts }
    endAt: LongInt;                  { sample where the frame ends }
    phase, stp: LongWord;
    quiet: LongInt;                  { silent samples still to come after a frame }
  end;

function Crc16(const b: array of Byte; n: Integer): Word;
procedure RsEncode(const d: array of Byte; var c: array of Byte);   { 11 nibbles -> 15 }
function BodyBlocks(len: Integer): Integer;
procedure EncodeFrame(const text: array of Byte; len, seq, doc, docLen, offset: Integer; var f: TFrame);
function FrameMs(const f: TFrame; speed: Integer): Integer;

type
  { the document and what still has to go out }
  TSender = record
    doc: array[0..DOCMAX - 1] of Byte;
    sends: array[0..DOCMAX - 1] of Byte;   { how many times each byte has gone out }
    L: Integer;                      { document length, bytes (UTF-8) }
    docId: Byte;
    seq: Byte;
    sentL: Integer;                  { the length the phone was last told }
    liveFrom: Integer;               { from here on, never sent }
    keyEnd: Integer;                 { just after the last key: Backspace cannot go back past it }
    target: Integer;                 { every byte goes out this many times }
    lastEdit: LongWord;              { tick of the last change }
    { the return channel: the phone says "bytes 0 .. P-1 are all here" }
    acked: Integer;                  { bytes below this need no more sending }
    ackIgnore: LongWord;             { acknowledgements are not believed before this tick }
    repFrom, repLen: Integer;        { a gap the phone asked for: sent at once }
    lastEnd: LongWord;               { tick when the last frame finished }
    waitAck: Boolean;                { a frame has finished and the acknowledgement may still come }
    noAck: Integer;                  { windows in a row that passed without one; from 2 on the repeats stop waiting }
    heard: Boolean;                  { an acknowledgement has been heard at least once }
    mismatch: Integer;               { acknowledgements in a row that did not fit the text }
    repairAll: Boolean;              { the phone's copy does not fit: the whole page goes out again, not only the end }
    lastCheck: LongWord;             { when the last periodic check frame was sent }
    hbMiss: Integer;                 { check frames in a row that were not answered (they stop after a while) }
  end;

procedure SnInit(var s: TSender; docId: Byte);
procedure SnNewDoc(var s: TSender);
procedure SnType(var s: TSender; c: WideChar; now: LongWord);    { add a character (UTF-8) }
procedure SnKey(var s: TSender; code: Integer; now: LongWord);   { add a key (a code from the K_ list, plus KEY_SHIFT/KEY_CTRL) }
procedure SnBackspace(var s: TSender; now: LongWord);           { remove the last typed character; or, if none was typed since the last key, add the key Backspace }
procedure SnDeleteWord(var s: TSender; now: LongWord);          { Ctrl+Backspace: the same, a word at a time }
procedure SnResend(var s: TSender; now: LongWord);              { send the end of the document again, as if it was new }
procedure SnFrameDone(var s: TSender; now: LongWord);           { the sound of a frame has ended }
procedure SnAck(var s: TSender; now: LongWord; doc, P, G, hash: Integer);   { the phone's acknowledgement (ackrx) }
function AckHash(doc, P, G: Integer; const bytes: array of Byte): Integer;   { 12 bits: what the acknowledgement says about the text }
function SnDelivered(const s: TSender): Boolean;                { every byte is known to the phone }
{ the next frame to send, if any; now is GetTickCount }
function SnNext(var s: TSender; now: LongWord; var f: TFrame): Boolean;
function SnWaiting(const s: TSender): Integer;                  { bytes typed that have not gone out even once }
{ how many times the end of the document (the last RECENT_BACK bytes) has gone out, at least; 0 when something is waiting }
function SnSent(const s: TSender): Integer;

procedure TmInit(var t: TToneMaker; rate: Integer);
procedure TmStart(var t: TToneMaker; const f: TFrame);
{ fills n samples; returns True while a frame (or its silent tail) is still going }
function TmFill(var t: TToneMaker; var buf: array of SmallInt; n: Integer): Boolean;

implementation

const
  TAB_BITS = 12; TAB_N = 1 shl TAB_BITS;
  Sine: array[0..TAB_N - 1] of SmallInt = (
{$I sine.inc}
  );

var
  GEXP: array[0..29] of Byte;
  GLOG: array[0..15] of Byte;
  GEN: array[0..4] of Byte;

function GMul(a, b: Byte): Byte;
begin
  if (a = 0) or (b = 0) then Result := 0 else Result := GEXP[GLOG[a] + GLOG[b]];
end;

procedure InitGF;
var i, j, x: Integer; r: array[0..4] of Byte; g: array[0..4] of Byte; gl: Integer;
begin
  x := 1;
  for i := 0 to 14 do
  begin
    GEXP[i] := x; GLOG[x] := i;
    x := x shl 1;
    if (x and 16) <> 0 then x := x xor $13;
  end;
  for i := 15 to 29 do GEXP[i] := GEXP[i - 15];
  { generator (x - a^1)(x - a^2)(x - a^3)(x - a^4), highest power first }
  g[0] := 1; gl := 1;
  for i := 1 to 4 do
  begin
    for j := 0 to 4 do r[j] := 0;
    for j := 0 to gl - 1 do
    begin
      r[j] := r[j] xor g[j];
      r[j + 1] := r[j + 1] xor GMul(g[j], GEXP[i]);
    end;
    Inc(gl);
    for j := 0 to gl - 1 do g[j] := r[j];
  end;
  for j := 0 to 4 do GEN[j] := g[j];
end;

function Crc16(const b: array of Byte; n: Integer): Word;        { CCITT, start $FFFF }
var i, k: Integer; c: Word;
begin
  c := $FFFF;
  for i := 0 to n - 1 do
  begin
    c := c xor (Word(b[i]) shl 8);
    for k := 1 to 8 do
      if (c and $8000) <> 0 then c := Word((c shl 1) xor $1021) else c := Word(c shl 1);
  end;
  Result := c;
end;

procedure RsEncode(const d: array of Byte; var c: array of Byte);
var r: array[0..14] of Byte; i, j: Integer; m: Byte;
begin
  for i := 0 to 10 do r[i] := d[i];
  for i := 11 to 14 do r[i] := 0;
  for i := 0 to 10 do
  begin
    m := r[i];
    if m <> 0 then
      for j := 1 to 4 do r[i + j] := r[i + j] xor GMul(GEN[j], m);
  end;
  for i := 0 to 10 do c[i] := d[i];
  for i := 11 to 14 do c[i] := r[i];
end;

function BodyBlocks(len: Integer): Integer;
begin
  Result := ((len + 4) * 2 + 10) div 11;
end;

procedure EncodeFrame(const text: array of Byte; len, seq, doc, docLen, offset: Integer; var f: TFrame);
var all: array[0..MAXLEN + 8] of Byte; nib: array[0..9 * 11 - 1] of Byte;
    i, nb, nn, t, K: Integer; blk, cw: array[0..14] of Byte; words: array[0..9, 0..14] of Byte; c: Word;
begin
  if len > MAXLEN then len := MAXLEN;
  { the bytes the check covers: n, seq, doc, L, o, text }
  all[0] := len; all[1] := Byte(seq); all[2] := Byte(doc);
  all[3] := (docLen shr 8) and 255; all[4] := docLen and 255;
  all[5] := (offset shr 8) and 255; all[6] := offset and 255;
  for i := 0 to len - 1 do all[7 + i] := text[i];
  c := Crc16(all, len + 7);
  f.n := 0;
  for i := 0 to High(PREAMBLE) do begin f.sym[f.n] := PREAMBLE[i]; Inc(f.n); end;
  { header block: version, n, seq, doc, L }
  blk[0] := FORMAT_VERSION;
  blk[1] := len shr 4; blk[2] := len and 15;
  blk[3] := Byte(seq) shr 4; blk[4] := Byte(seq) and 15;
  blk[5] := Byte(doc) shr 4; blk[6] := Byte(doc) and 15;
  blk[7] := (docLen shr 12) and 15; blk[8] := (docLen shr 8) and 15;
  blk[9] := (docLen shr 4) and 15; blk[10] := docLen and 15;
  RsEncode(blk, cw);
  for i := 0 to 14 do words[0, i] := cw[i];
  { body: o, text, CRC; as nibbles, padded, in blocks }
  for i := 0 to High(nib) do nib[i] := 0;
  nn := 0;
  for i := 5 to len + 6 do begin nib[nn] := all[i] shr 4; nib[nn + 1] := all[i] and 15; Inc(nn, 2); end;
  nib[nn] := c shr 12; nib[nn + 1] := (c shr 8) and 15; nib[nn + 2] := (c shr 4) and 15; nib[nn + 3] := c and 15;
  nb := BodyBlocks(len);
  for nn := 0 to nb - 1 do
  begin
    for i := 0 to 10 do blk[i] := nib[nn * 11 + i];
    RsEncode(blk, cw);
    for i := 0 to 14 do words[nn + 1, i] := cw[i];
  end;
  { all blocks interleaved, the header being block 0: a burst of noise or a
    dropout only touches a symbol or two of each block }
  K := nb + 1;
  for t := 0 to K * 15 - 1 do
  begin
    f.sym[f.n] := words[t mod K, t div K];
    Inc(f.n);
  end;
end;

{ ---------- the document sender ---------- }

procedure SnInit(var s: TSender; docId: Byte);
begin
  FillChar(s, SizeOf(s), 0);
  s.docId := docId;
  if s.docId >= $FD then s.docId := 0;
  s.sentL := -1;
  s.target := DEFAULT_SENDS;
  s.acked := 0; s.repLen := 0; s.waitAck := False; s.noAck := 0; s.heard := False; s.mismatch := 0; s.repairAll := False; s.lastCheck := 0;
end;

procedure SnNewDoc(var s: TSender);
var id: Byte;
begin
  id := Byte(s.docId + 1);
  if id >= $FD then id := 0;
  s.L := 0; s.sentL := -1; s.liveFrom := 0; s.keyEnd := 0;
  s.docId := id;
  s.acked := 0; s.repLen := 0; s.waitAck := False; s.mismatch := 0; s.repairAll := False;
end;

procedure Changed(var s: TSender; now: LongWord);
begin
  if s.liveFrom > s.L then s.liveFrom := s.L;
  if s.keyEnd > s.L then s.keyEnd := s.L;
  if s.acked > s.L then begin s.acked := s.L; s.ackIgnore := now + ACK_IGNORE_MS; end;
  if s.repFrom + s.repLen > s.L then begin s.repLen := 0; end;
  s.lastEdit := now;
end;

procedure PutChar(var s: TSender; u: Integer);
var n, i: Integer;
begin
  if u < $80 then begin s.doc[s.L] := u; n := 1; end
  else if u < $800 then
  begin
    s.doc[s.L] := $C0 or (u shr 6); s.doc[s.L + 1] := $80 or (u and $3F); n := 2;
  end
  else
  begin
    s.doc[s.L] := $E0 or (u shr 12); s.doc[s.L + 1] := $80 or ((u shr 6) and $3F);
    s.doc[s.L + 2] := $80 or (u and $3F); n := 3;
  end;
  for i := 0 to n - 1 do s.sends[s.L + i] := 0;
  Inc(s.L, n);
end;

procedure SnType(var s: TSender; c: WideChar; now: LongWord);
begin
  if s.L + 3 > DOCMAX then SnNewDoc(s);
  PutChar(s, Ord(c));
  Changed(s, now);
end;

procedure SnKey(var s: TSender; code: Integer; now: LongWord);
begin
  if s.L + 3 > DOCMAX then SnNewDoc(s);
  PutChar(s, KEY_BASE + code);
  s.keyEnd := s.L;
  Changed(s, now);
end;

procedure SnBackspace(var s: TSender; now: LongWord);
begin
  if s.L <= s.keyEnd then
  begin
    { nothing typed since the last key (or at all): the phone deletes in its own field }
    SnKey(s, K_BACKSPACE, now);
    Exit;
  end;
  Dec(s.L);
  while (s.L > s.keyEnd) and ((s.doc[s.L] and $C0) = $80) do Dec(s.L);   { a whole UTF-8 character }
  Changed(s, now);
end;

procedure SnDeleteWord(var s: TSender; now: LongWord);
begin
  if s.L <= s.keyEnd then
  begin
    SnKey(s, K_BACKSPACE or KEY_CTRL, now);
    Exit;
  end;
  { spaces and line ends first, then the letters of the word }
  while (s.L > s.keyEnd) and ((s.doc[s.L - 1] = 32) or (s.doc[s.L - 1] = 10)) do Dec(s.L);
  while (s.L > s.keyEnd) and (s.doc[s.L - 1] <> 32) and (s.doc[s.L - 1] <> 10) do Dec(s.L);
  Changed(s, now);
end;

procedure SnResend(var s: TSender; now: LongWord);
var lo, i: Integer;
begin
  lo := s.L - RECENT_BACK;
  if lo < 0 then lo := 0;
  for i := lo to s.L - 1 do s.sends[i] := 0;
  if s.liveFrom > lo then s.liveFrom := lo;
  s.sentL := -1;
  if s.acked > lo then s.acked := lo;
  s.repLen := 0;
  s.ackIgnore := now + ACK_IGNORE_MS;
  s.lastEdit := now;
end;

procedure SnFrameDone(var s: TSender; now: LongWord);
begin
  s.lastEnd := now;
  s.waitAck := True;
end;

function AckHash(doc, P, G: Integer; const bytes: array of Byte): Integer;
var c: Word; i: Integer;
  procedure Feed(b: Integer);
  var j: Integer;
  begin
    c := c xor (Word(b and 255) shl 8);
    for j := 1 to 8 do
      if (c and $8000) <> 0 then c := Word((c shl 1) xor $1021) else c := Word(c shl 1);
  end;
begin
  c := $FFFF;
  Feed(doc); Feed(P shr 8); Feed(P and 255); Feed(G and 15);
  for i := 0 to P - 1 do Feed(bytes[i]);
  Result := c and $FFF;
end;

procedure SnAck(var s: TSender; now: LongWord; doc, P, G, hash: Integer);
var i, lo, m: Integer;
begin
  if doc <> s.docId then Exit;
  s.hbMiss := 0;
  if (s.ackIgnore <> 0) and (LongInt(now - s.ackIgnore) < 0) then Exit;
  { it must say something true about OUR text: otherwise the phone holds older text, or the frame was misread }
  if (P > s.L) or (AckHash(doc, P, G, s.doc) <> hash) then
  begin
    s.heard := True; s.noAck := 0; s.waitAck := False;
    if s.mismatch < 200 then
    begin
      Inc(s.mismatch);
      if s.mismatch >= 2 then
      begin
        { two in a row: the difference may be anywhere in the page: all of it goes out again }
        m := 255;
        for i := 0 to s.L - 1 do if s.sends[i] < m then m := s.sends[i];
        if (not s.repairAll) or (m >= s.target) then     { not while such a round is still going out }
        begin
          s.repairAll := True;
          for i := 0 to s.L - 1 do s.sends[i] := 1;
        end;
        s.acked := 0;
        Exit;
      end;
      lo := s.L - RECENT_BACK; if lo < 0 then lo := 0;
      for i := lo to s.L - 1 do if (s.target > 1) and (s.sends[i] > s.target - 1) then s.sends[i] := s.target - 1;
      if s.acked > lo then s.acked := lo;
    end;
    Exit;
  end;
  s.mismatch := 0;
  s.repairAll := False;
  s.heard := True;
  s.noAck := 0;
  s.waitAck := False;
  if P > s.acked then s.acked := P;
  if (G > 0) and (P < s.L) then
  begin
    s.repFrom := P;
    s.repLen := G;
    if s.repFrom + s.repLen > s.L then s.repLen := s.L - s.repFrom;
  end
  else s.repLen := 0;
end;

function SnDelivered(const s: TSender): Boolean;
begin
  Result := (s.L > 0) and (s.acked >= s.L);
end;

function SnWaiting(const s: TSender): Integer;
begin
  Result := s.L - s.liveFrom;
end;

function SnSent(const s: TSender): Integer;
var i, lo, m: Integer;
begin
  if (s.L = 0) or (s.L - s.liveFrom > 0) then begin Result := 0; Exit; end;
  lo := s.L - RECENT_BACK;
  if lo < 0 then lo := 0;
  m := MAX_SENDS;
  for i := lo to s.L - 1 do if s.sends[i] < m then m := s.sends[i];
  Result := m;
end;

procedure MakeFrame(var s: TSender; o, n: Integer; alt: Boolean; var f: TFrame);
var i: Integer; tb: array[0..MAXLEN - 1] of Byte;
begin
  for i := 0 to n - 1 do
  begin
    tb[i] := s.doc[o + i];
    if s.sends[o + i] < 255 then Inc(s.sends[o + i]);
  end;
  EncodeFrame(tb, n, s.seq, s.docId, s.L, o, f);
  f.alt := alt;
  f.off := o; f.len := n; f.docL := s.L;
  s.seq := Byte(s.seq + 1);
  s.sentL := s.L;
end;

{ Nothing else to send and the page has been left alone: an empty frame asks the phone to say what it holds, now and
  then (CHECK_MS; sooner while its copy does not fit). Only when the phone has answered before. }
function Heartbeat(var s: TSender; now: LongWord; var f: TFrame): Boolean;
var chk: LongWord;
begin
  Result := False;
  if (not s.heard) or (s.hbMiss >= 20) or (s.L = 0) then Exit;
  chk := CHECK_MS;
  if s.mismatch > 0 then chk := ACK_WAIT_MS + 1500;
  if (LongInt(now - s.lastEdit) < LongInt(chk)) or (LongInt(now - s.lastCheck) < LongInt(chk)) then Exit;
  s.lastCheck := now;
  Inc(s.hbMiss);
  MakeFrame(s, s.L, 0, False, f);
  Result := True;
end;

function SnNext(var s: TSender; now: LongWord; var f: TFrame): Boolean;
var o, n, i, lo, m: Integer; idle: LongWord;
begin
  Result := False;
  idle := now - s.lastEdit;
  { new text (or a shorter document) goes out at once. If there is room, the
    frame starts a little earlier and repeats the text that went out only once,
    so while you type every character is sent twice anyway; when you type
    faster than the sound can carry, the repeats shrink and wait for a pause }
  if (s.liveFrom < s.L) or (s.sentL <> s.L) then
  begin
    if s.L - s.liveFrom >= LIVE_MAX then
    begin
      { much is waiting (fast typing): only new text, as much as fits }
      o := s.liveFrom; n := s.L - o;
      if n > MAXLEN then n := MAXLEN;
    end
    else
    begin
      { a short frame (they arrive sooner): the new text, and older text that went out once, up to LIVE_MAX }
      o := s.L - LIVE_MAX;
      if o < 0 then o := 0;
      while (o < s.liveFrom) and (s.sends[o] >= 2) do Inc(o);
      n := s.L - o;
    end;
    MakeFrame(s, o, n, False, f);
    if o + n > s.liveFrom then s.liveFrom := o + n;
    Result := True;
    Exit;
  end;
  { a gap the phone asked for goes out at once }
  if (s.repLen > 0) and (s.repFrom < s.L) then
  begin
    o := s.repFrom; n := s.repLen;
    if n > REPAIR_MAX then n := REPAIR_MAX;
    MakeFrame(s, o, n, Odd(s.sends[o]), f);
    s.repFrom := o + n; Dec(s.repLen, n);
    Result := True;
    Exit;
  end;
  { after a frame the repeats wait for the acknowledgement (2 windows in a row without one: the phone does not
    answer, and they stop waiting) }
  if s.waitAck and (LongInt(now - s.lastEnd) >= ACK_WAIT_MS) then
  begin
    s.waitAck := False;
    if s.L > s.acked then Inc(s.noAck);
  end;
  if s.waitAck and (s.noAck < 2) and (s.acked < s.L) then Exit;
  { a pause: the text that has gone out the fewest times goes out again, if it has been left alone long
    enough for that many sends (the 2nd after 0.4 s, the 3rd after 1.5 s, ...) }
  lo := s.L - RECENT_BACK;
  if lo < 0 then lo := 0;
  if s.repairAll then lo := 0;
  if lo < s.acked then lo := s.acked;
  if lo >= s.L then begin Result := Heartbeat(s, now, f); Exit; end;
  m := 255;
  for i := lo to s.L - 1 do if s.sends[i] < m then m := s.sends[i];
  if (m >= 1) and (m < s.target) and (m < MAX_SENDS) and (idle >= SEND_AFTER_MS[m]) then
  begin
    o := lo;
    while s.sends[o] <> m do Inc(o);
    n := 1;
    while (o + n < s.L) and (n < REPAIR_MAX) and (s.sends[o + n] <= m + 1) do Inc(n);
    MakeFrame(s, o, n, not Odd(m + 1), f);              { the 2nd, 4th... send on the second band }
    Result := True;
  end
  else Result := Heartbeat(s, now, f);
end;

function FrameMs(const f: TFrame; speed: Integer): Integer;
begin
  Result := f.n * SPEED_MS[speed];
end;

{ ---------- the tone maker ---------- }

function StepFor(hz, rate: Integer): LongWord;
begin
  Result := LongWord((Int64(hz) shl 32) div rate);
end;

function SymStart(const t: TToneMaker; k: Integer): LongInt;      { first sample of symbol k }
begin
  Result := LongInt(Int64(k) * t.rate * SPEED_MS[t.speed] div 1000);
end;

procedure TmInit(var t: TToneMaker; rate: Integer);
begin
  FillChar(t, SizeOf(t), 0);
  t.rate := rate;
  t.band := NBANDS - 1; t.speed := 1; t.volume := 50;
end;

procedure TmStart(var t: TToneMaker; const f: TFrame);
begin
  t.frame := f;
  t.playing := True;
  t.pos := 0; t.k := 0;
  t.nextAt := SymStart(t, 1);
  t.endAt := SymStart(t, f.n);
  t.phase := 0;
  t.stp := StepFor(BAND_HZ[t.band] + f.sym[0] * STEP_HZ, t.rate);
  t.quiet := t.rate div 16;                       { about 60 ms of silence after each frame }
end;

function TmFill(var t: TToneMaker; var buf: array of SmallInt; n: Integer): Boolean;
var i: Integer; env, fade, vol: LongInt; s: LongInt;
begin
  fade := t.rate div 200;                         { 5 ms soft start and end }
  vol := t.volume * 1024 div 100;
  for i := 0 to n - 1 do
  begin
    if t.playing then
    begin
      if t.pos >= t.nextAt then
      begin
        Inc(t.k);
        if t.k < t.frame.n then
        begin
          t.stp := StepFor(BAND_HZ[t.band] + t.frame.sym[t.k] * STEP_HZ, t.rate);
          t.nextAt := SymStart(t, t.k + 1);
        end;
      end;
      if t.pos >= t.endAt then
      begin
        t.playing := False;
        buf[i] := 0;
        Continue;
      end;
      env := 1024;
      if t.pos < fade then env := t.pos * 1024 div fade
      else if t.endAt - t.pos < fade then env := (t.endAt - t.pos) * 1024 div fade;
      s := Sine[t.phase shr (32 - TAB_BITS)];
      buf[i] := SmallInt((s * env div 1024) * vol div 1024);
      t.phase := t.phase + t.stp;
      Inc(t.pos);
    end
    else
    begin
      buf[i] := 0;
      if t.quiet > 0 then Dec(t.quiet);
    end;
  end;
  Result := t.playing or (t.quiet > 0);
end;

initialization
  InitGF;
end.
