unit wmodem;
{ HPC Whisper sound format (version 2), sending side. Must match modem.js
  and docs/FORMAT.md.

  Tones on a 100 Hz grid; a band is 16 neighbouring tones starting at
  BAND_HZ[b]. One tone per symbol = 4 bits. Frame: preamble (8 symbols),
  then a header block and the body blocks, all interleaved. Each block is a
  Reed-Solomon (15,11) code word over GF(16).

  A frame carries a piece of the document: "the document is L bytes long,
  and from offset o it reads ...". The sender (TSender) sends new text at
  once and repeats it during pauses, so a frame lost on the way only leaves
  a gap on the phone that fills in a moment later.

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
  REPAIR_IDLE_MS = 400;              { a pause this long: repeat what went out once }
  REPAIR2_IDLE_MS = 1500;            { a longer pause: a third time }
  TAIL_IDLE_MS = 3000;               { a long pause: the last words once more }
  REPAIR_MAX = 22;
  SWEEP_IDLE_MS = 5000;              { a long rest: the recent text goes over once more, }
  SWEEP_BACK = 300;                  { this far back, so any gap left on the phone fills }                   { repeats go in shorter frames: more of them get through }

type
  TFrame = record
    sym: array[0..MAXSYM - 1] of Byte;
    n: Integer;
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
    L: Integer;                      { document length, bytes (UTF-8) }
    docId: Byte;
    seq: Byte;
    sentL: Integer;                  { the length the phone was last told }
    liveFrom: Integer;               { from here on, never sent }
    repairFrom: Integer;             { from here to liveFrom: sent once only }
    repair2From: Integer;            { from here to repairFrom: sent twice only }
    tailDone: Boolean;               { the last words were sent a third time }
    sweepPos: Integer;               { the sweep over the recent text: next offset, or -1 when done }
    lastEdit: LongWord;              { tick of the last change }
  end;

procedure SnInit(var s: TSender; docId: Byte);
procedure SnNewDoc(var s: TSender);
procedure SnType(var s: TSender; c: WideChar; now: LongWord);    { add a character (UTF-8) }
procedure SnBackspace(var s: TSender; now: LongWord);           { remove the last character }
{ the next frame to send, if any; now is GetTickCount }
function SnNext(var s: TSender; now: LongWord; var f: TFrame): Boolean;

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
  s.tailDone := True;
  s.sweepPos := -1;
end;

procedure SnNewDoc(var s: TSender);
var id: Byte;
begin
  id := Byte(s.docId + 1);
  s.L := 0; s.sentL := -1; s.liveFrom := 0; s.repairFrom := 0; s.repair2From := 0;
  s.docId := id; s.tailDone := True; s.sweepPos := -1;
end;

procedure Changed(var s: TSender; now: LongWord);
begin
  if s.liveFrom > s.L then s.liveFrom := s.L;
  if s.repairFrom > s.L then s.repairFrom := s.L;
  if s.repair2From > s.L then s.repair2From := s.L;
  s.tailDone := False;
  s.sweepPos := s.L - SWEEP_BACK;
  if s.sweepPos < 0 then s.sweepPos := 0;
  s.lastEdit := now;
end;

procedure SnType(var s: TSender; c: WideChar; now: LongWord);
var u: Integer;
begin
  if s.L + 3 > DOCMAX then SnNewDoc(s);
  u := Ord(c);
  if u < $80 then begin s.doc[s.L] := u; Inc(s.L); end
  else if u < $800 then
  begin
    s.doc[s.L] := $C0 or (u shr 6); s.doc[s.L + 1] := $80 or (u and $3F); Inc(s.L, 2);
  end
  else
  begin
    s.doc[s.L] := $E0 or (u shr 12); s.doc[s.L + 1] := $80 or ((u shr 6) and $3F);
    s.doc[s.L + 2] := $80 or (u and $3F); Inc(s.L, 3);
  end;
  Changed(s, now);
end;

procedure SnBackspace(var s: TSender; now: LongWord);
begin
  if s.L = 0 then Exit;
  Dec(s.L);
  while (s.L > 0) and ((s.doc[s.L] and $C0) = $80) do Dec(s.L);   { a whole UTF-8 character }
  Changed(s, now);
end;

procedure MakeFrame(var s: TSender; o, n: Integer; var f: TFrame);
var i: Integer; tb: array[0..MAXLEN - 1] of Byte;
begin
  for i := 0 to n - 1 do tb[i] := s.doc[o + i];
  EncodeFrame(tb, n, s.seq, s.docId, s.L, o, f);
  s.seq := Byte(s.seq + 1);
  s.sentL := s.L;
end;

function SnNext(var s: TSender; now: LongWord; var f: TFrame): Boolean;
var o, n: Integer; idle: LongWord;
begin
  Result := False;
  idle := now - s.lastEdit;
  { new text (or a shorter document) goes out at once. If there is room, the
    frame starts a little earlier and repeats the text that went out only once,
    so while you type every character is sent twice anyway; when you type
    faster than the sound can carry, the repeats shrink and wait for a pause }
  if (s.liveFrom < s.L) or (s.sentL <> s.L) then
  begin
    if s.L - s.liveFrom >= MAXLEN then
    begin
      o := s.liveFrom; n := MAXLEN;
    end
    else
    begin
      o := s.repairFrom;
      if s.L - o > MAXLEN then o := s.L - MAXLEN;
      n := s.L - o;
    end;
    MakeFrame(s, o, n, f);
    if o <= s.repairFrom then s.repairFrom := s.liveFrom;     { what went out once has now gone twice }
    s.liveFrom := o + n;
    Result := True;
    Exit;
  end;
  { a pause: repeat what went out only once }
  if (s.repairFrom < s.L) and (idle >= REPAIR_IDLE_MS) then
  begin
    o := s.repairFrom; n := s.L - o;
    if n > REPAIR_MAX then n := REPAIR_MAX;
    MakeFrame(s, o, n, f);
    s.repairFrom := o + n;
    Result := True;
    Exit;
  end;
  { a longer pause: what went out twice, a third time }
  if (s.repair2From < s.repairFrom) and (idle >= REPAIR2_IDLE_MS) then
  begin
    o := s.repair2From; n := s.repairFrom - o;
    if n > REPAIR_MAX then n := REPAIR_MAX;
    MakeFrame(s, o, n, f);
    s.repair2From := o + n;
    Result := True;
    Exit;
  end;
  { a long pause: the last words once more (and an empty document is announced too) }
  if (not s.tailDone) and (idle >= TAIL_IDLE_MS) then
  begin
    o := s.L - REPAIR_MAX; if o < 0 then o := 0;
    MakeFrame(s, o, s.L - o, f);
    s.tailDone := True;
    Result := True;
    Exit;
  end;
  { a long rest: one sweep over the recent text }
  if (s.sweepPos >= 0) and (s.sweepPos < s.L) and (idle >= SWEEP_IDLE_MS) then
  begin
    o := s.sweepPos; n := s.L - o;
    if n > REPAIR_MAX then n := REPAIR_MAX;
    MakeFrame(s, o, n, f);
    s.sweepPos := o + n;
    if s.sweepPos >= s.L then s.sweepPos := -1;
    Result := True;
  end;
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
