unit wmodem;
{ J720 Whisper sound format, sending side. Must match web/modem.js.

  Tones on a 100 Hz grid; a band is 16 neighbouring tones starting at
  BAND_HZ[b]. One tone per symbol = 4 bits. Frame: preamble (6 symbols),
  then blocks of 15 symbols, each a Reed-Solomon (15,11) code word over
  GF(16). Data bytes: [length, sequence, text..., CRC-16], high nibble first.

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
  MAXLEN = 48;                       { text bytes in one frame }
  MAXSYM = 6 + 10 * 15;
  PREAMBLE: array[0..5] of Byte = (0, 15, 0, 15, 4, 11);

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
function BlocksFor(len: Integer): Integer;
procedure EncodeFrame(const text: array of Byte; len, seq: Integer; var f: TFrame);
function FrameMs(const f: TFrame; speed: Integer): Integer;

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

function BlocksFor(len: Integer): Integer;
begin
  Result := ((len + 4) * 2 + 10) div 11;
end;

procedure EncodeFrame(const text: array of Byte; len, seq: Integer; var f: TFrame);
var by: array[0..MAXLEN + 3] of Byte; nib: array[0..10 * 11 - 1] of Byte;
    i, nb, nn: Integer; blk, cw: array[0..14] of Byte; c: Word;
begin
  if len > MAXLEN then len := MAXLEN;
  by[0] := len; by[1] := Byte(seq);
  for i := 0 to len - 1 do by[2 + i] := text[i];
  c := Crc16(by, len + 2);
  by[len + 2] := c shr 8; by[len + 3] := c and 255;
  nb := BlocksFor(len);
  for i := 0 to High(nib) do nib[i] := 0;
  nn := 0;
  for i := 0 to len + 3 do
  begin
    nib[nn] := by[i] shr 4; nib[nn + 1] := by[i] and 15; Inc(nn, 2);
  end;
  f.n := 0;
  for i := 0 to 5 do begin f.sym[f.n] := PREAMBLE[i]; Inc(f.n); end;
  for nn := 0 to nb - 1 do
  begin
    for i := 0 to 10 do blk[i] := nib[nn * 11 + i];
    RsEncode(blk, cw);
    for i := 0 to 14 do begin f.sym[f.n] := cw[i]; Inc(f.n); end;
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
