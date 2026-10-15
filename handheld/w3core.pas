unit w3core;
{ HPC Whisper format 3: channels, fixed sequences, Reed-Solomon over GF(256),
  header and payload coding, bit maps. Must match docs/FORMAT3.md and the
  phone's Java code (android/.../w3). Whole numbers only. }
{$mode objfpc}{$H+}
interface

const
  MRATE = 51200; NFFT = 512; NCP = 128; NSYM = NFFT + NCP; NFADE = 26;
  CH_SU = 0; CH_SUW = 1; CH_SD = 2; CH_FU = 3; CH_FD = 4; NCHAN = 5;
  MAXCAR = 180;
  HDR_LEN = 3; HDR_CHECK = 6; HDR_CODED = HDR_LEN + HDR_CHECK;
  MAXMSG = 2047;
  MAXCODED = 2600;
  T_TEXT = $01; T_TEXT_ACK = $02; T_FILE_OFFER = $10; T_FILE_DATA = $11; T_FILE_NEED = $12;
  T_FILE_CANCEL = $13; T_SCREEN = $20; T_INPUT = $21; T_TRAIN = $30; T_MAP = $31; T_HELLO = $32;
  TRAIN_SYMBOLS = 24;

type
  TChannel = record
    id, n: Integer;
    bins: array[0..MAXCAR - 1] of Integer;
    pilot: array[0..MAXCAR - 1] of Boolean;
    defBits: Integer;
    silent: Boolean;
    syncStep: Integer;        { S uses bins that are multiples of this }
    level: Integer;           { default peak, of 32767 }
  end;
  TBitMap = record
    ch: Integer;
    number: Integer;
    bits: array[0..MAXCAR - 1] of Byte;
  end;
  TBytes = array of Byte;

var
  Chans: array[0..NCHAN - 1] of TChannel;
  PSeq: array[0..255] of Byte;
  WSeq: array[0..4095] of Byte;

function SPhase(c: Integer): Integer;
function RPhase(c: Integer): Integer;
function TrainStep(c, s: Integer): Integer;
procedure Scramble(var b: array of Byte; n: Integer);
function Crc16(const b: array of Byte; off, n: Integer): Word;

procedure RsEncode(var cw: array of Byte; off, k, p: Integer);              { check bytes after the k data bytes }
function RsDecode(var cw: array of Byte; off, n, p: Integer): Integer;       { errors fixed, or -1 }

procedure StdMap(ch: Integer; var m: TBitMap);
function MapBits(const m: TBitMap): Integer;                                  { bits per symbol }
procedure MapFromSnr(ch, number: Integer; const snrDb10: array of Integer; var m: TBitMap);   { tenths of dB }
function MapToMsg(const m: TBitMap; var b: array of Byte): Integer;
function MapFromMsg(const b: array of Byte; n: Integer; var m: TBitMap): Boolean;

procedure HeaderEncode(typ, len, map: Integer; var h: array of Byte);
function HeaderDecode(var h: array of Byte; out typ, len, map: Integer): Boolean;
function CodedLength(msgLen: Integer): Integer;
procedure PayloadEncode(const msg: array of Byte; msgLen: Integer; var coded: array of Byte);
function PayloadDecode(var coded: array of Byte; msgLen: Integer; var msg: array of Byte; out fixed: Integer): Boolean;

implementation

var
  GExp: array[0..511] of Byte;
  GLog: array[0..255] of Integer;
  Gen: array[0..32, 0..32] of Byte;      { generator for p check bytes, highest power first }
  GenOk: array[0..32] of Boolean;

function GMul(a, b: Integer): Integer; inline;
begin
  if (a = 0) or (b = 0) then Result := 0 else Result := GExp[GLog[a] + GLog[b]];
end;

function GDiv(a, b: Integer): Integer; inline;
begin
  if a = 0 then Result := 0 else Result := GExp[GLog[a] + 255 - GLog[b]];
end;

procedure MakeChan(id, from, upto, step: Integer; isSilent: Boolean);
var i, n: Integer;
begin
  { no "with" here: inside one, a parameter named like a field is hidden by it }
  n := (upto - from) div step + 1;
  Chans[id].id := id;
  Chans[id].n := n;
  Chans[id].silent := isSilent;
  for i := 0 to n - 1 do begin Chans[id].bins[i] := from + i * step; Chans[id].pilot[i] := False; end;
  if isSilent then begin Chans[id].pilot[0] := True; Chans[id].pilot[n - 1] := True; end
  else
  begin
    i := 0;
    while i < n do begin Chans[id].pilot[i] := True; Inc(i, 10); end;
    Chans[id].pilot[n - 1] := True;
  end;
  if isSilent then Chans[id].defBits := 2 else Chans[id].defBits := 1;
  Chans[id].syncStep := 2 * step;
  if isSilent then Chans[id].level := 16384 else Chans[id].level := 4096;
end;

procedure InitAll;
var i, j, x: Integer;
begin
  MakeChan(CH_SU, 200, 212, 2, True);
  MakeChan(CH_SUW, 182, 212, 2, True);
  MakeChan(CH_SD, 194, 208, 2, True);
  MakeChan(CH_FU, 10, 189, 1, False);
  MakeChan(CH_FD, 5, 119, 1, False);
  x := 11;
  for i := 0 to 255 do begin PSeq[i] := (x shr 9) and 3; x := (x * 25173 + 13849) and $FFFF; end;
  x := $1D0F;
  for i := 0 to 4095 do begin WSeq[i] := (x shr 8) and 255; x := (x * 25173 + 13849) and $FFFF; end;
  x := 1;
  for i := 0 to 254 do
  begin
    GExp[i] := x; GLog[x] := i;
    x := x shl 1;
    if (x and $100) <> 0 then x := x xor $11D;
  end;
  for i := 255 to 511 do GExp[i] := GExp[i - 255];
  GLog[0] := 0;
  for i := 0 to 32 do GenOk[i] := False;
  j := 0;
  if j = 0 then ;
end;

function SPhase(c: Integer): Integer; begin Result := PSeq[(c * 7) and 255]; end;
function RPhase(c: Integer): Integer; begin Result := PSeq[(c * 7 + 101) and 255]; end;
function TrainStep(c, s: Integer): Integer; begin Result := PSeq[(c * 3 + s * 11) and 255]; end;

procedure Scramble(var b: array of Byte; n: Integer);
var i: Integer;
begin
  for i := 0 to n - 1 do b[i] := b[i] xor WSeq[i and 4095];
end;

function Crc16(const b: array of Byte; off, n: Integer): Word;
var i, k: Integer; c: LongWord;
begin
  c := $FFFF;
  for i := 0 to n - 1 do
  begin
    c := c xor (LongWord(b[off + i]) shl 8);
    for k := 1 to 8 do
      if (c and $8000) <> 0 then c := ((c shl 1) xor $1021) and $FFFF else c := (c shl 1) and $FFFF;
  end;
  Result := c;
end;

procedure MakeGen(p: Integer);
var g, r: array[0..33] of Byte; gl, i, j: Integer;
begin
  g[0] := 1; gl := 1;
  for i := 0 to p - 1 do
  begin
    for j := 0 to gl do r[j] := 0;
    for j := 0 to gl - 1 do
    begin
      r[j] := r[j] xor g[j];
      r[j + 1] := r[j + 1] xor GMul(g[j], GExp[i]);
    end;
    Inc(gl);
    for j := 0 to gl - 1 do g[j] := r[j];
  end;
  for j := 0 to p do Gen[p, j] := g[j];
  GenOk[p] := True;
end;

procedure RsEncode(var cw: array of Byte; off, k, p: Integer);
var r: array[0..31] of Byte; i, j, f: Integer;
begin
  if not GenOk[p] then MakeGen(p);
  for j := 0 to p - 1 do r[j] := 0;
  for i := 0 to k - 1 do
  begin
    f := cw[off + i] xor r[0];
    for j := 0 to p - 2 do r[j] := r[j + 1];
    r[p - 1] := 0;
    if f <> 0 then for j := 0 to p - 1 do r[j] := r[j] xor GMul(Gen[p, j + 1], f);
  end;
  for j := 0 to p - 1 do cw[off + k + j] := r[j];
end;

function Syndromes(const cw: array of Byte; off, n, p: Integer; var s: array of Integer): Boolean;   { True = all zero }
var i, j, v, a: Integer;
begin
  Result := True;
  for i := 0 to p - 1 do
  begin
    v := 0; a := GExp[i];
    for j := 0 to n - 1 do v := GMul(v, a) xor cw[off + j];
    s[i] := v;
    if v <> 0 then Result := False;
  end;
end;

function RsDecode(var cw: array of Byte; off, n, p: Integer): Integer;
var s, lam, b, t, om: array[0..33] of Integer;
    L, m, bb, r, i, j, d, coef, found, pw, xinv, v, xp, o, dl, e: Integer;
begin
  Result := -1;
  if Syndromes(cw, off, n, p, s) then begin Result := 0; Exit; end;
  for i := 0 to p do begin lam[i] := 0; b[i] := 0; end;
  lam[0] := 1; b[0] := 1; L := 0; m := 1; bb := 1;
  for r := 0 to p - 1 do
  begin
    d := s[r];
    for i := 1 to L do d := d xor GMul(lam[i], s[r - i]);
    if d = 0 then begin Inc(m); Continue; end;
    for i := 0 to p do t[i] := lam[i];
    coef := GDiv(d, bb);
    i := 0;
    while i + m <= p do begin lam[i + m] := lam[i + m] xor GMul(coef, b[i]); Inc(i); end;
    if 2 * L <= r then
    begin
      L := r + 1 - L;
      for i := 0 to p do b[i] := t[i];
      bb := d; m := 1;
    end
    else Inc(m);
  end;
  if 2 * L > p then Exit;
  for i := 0 to p - 1 do
  begin
    v := 0;
    for j := 0 to i do if j <= L then v := v xor GMul(lam[j], s[i - j]);
    om[i] := v;
  end;
  found := 0;
  for j := 0 to n - 1 do
  begin
    pw := n - 1 - j;
    xinv := GExp[(255 - pw mod 255) mod 255];
    v := 0; xp := 1;
    for i := 0 to L do begin v := v xor GMul(lam[i], xp); xp := GMul(xp, xinv); end;
    if v <> 0 then Continue;
    o := 0; xp := 1;
    for i := 0 to p - 1 do begin o := o xor GMul(om[i], xp); xp := GMul(xp, xinv); end;
    dl := 0; xp := 1;
    i := 1;
    while i <= L do begin dl := dl xor GMul(lam[i], xp); xp := GMul(xp, GMul(xinv, xinv)); Inc(i, 2); end;
    if dl = 0 then Exit;
    e := GMul(GExp[pw mod 255], GDiv(o, dl));
    cw[off + j] := cw[off + j] xor e;
    Inc(found);
  end;
  if found <> L then Exit;
  if not Syndromes(cw, off, n, p, s) then Exit;
  Result := found;
end;

{ ---------- maps ---------- }

procedure StdMap(ch: Integer; var m: TBitMap);
var c: Integer;
begin
  m.ch := ch; m.number := 0;
  for c := 0 to MAXCAR - 1 do m.bits[c] := 0;
  for c := 0 to Chans[ch].n - 1 do
    if not Chans[ch].pilot[c] then m.bits[c] := Chans[ch].defBits;
end;

function MapBits(const m: TBitMap): Integer;
var c: Integer;
begin
  Result := 0;
  for c := 0 to Chans[m.ch].n - 1 do if not Chans[m.ch].pilot[c] then Inc(Result, m.bits[c]);
end;

procedure MapFromSnr(ch, number: Integer; const snrDb10: array of Integer; var m: TBitMap);
var c, s: Integer;
begin
  m.ch := ch; m.number := number;
  for c := 0 to MAXCAR - 1 do m.bits[c] := 0;
  for c := 0 to Chans[ch].n - 1 do
  begin
    if Chans[ch].pilot[c] then Continue;
    s := snrDb10[c];
    if s >= 230 then m.bits[c] := 3 else if s >= 160 then m.bits[c] := 2 else if s >= 100 then m.bits[c] := 1;
  end;
end;

function MapToMsg(const m: TBitMap; var b: array of Byte): Integer;
var n, c: Integer;
begin
  n := Chans[m.ch].n;
  Result := 3 + (n + 3) div 4;
  for c := 0 to Result - 1 do b[c] := 0;
  b[0] := m.ch; b[1] := m.number; b[2] := n;
  for c := 0 to n - 1 do b[3 + c div 4] := b[3 + c div 4] or ((m.bits[c] and 3) shl (6 - 2 * (c mod 4)));
end;

function MapFromMsg(const b: array of Byte; n: Integer; var m: TBitMap): Boolean;
var c, k: Integer;
begin
  Result := False;
  if (n < 3) or (b[0] >= NCHAN) then Exit;
  k := b[2];
  if (k <> Chans[b[0]].n) or (n < 3 + (k + 3) div 4) then Exit;
  m.ch := b[0]; m.number := b[1] and 31;
  for c := 0 to MAXCAR - 1 do m.bits[c] := 0;
  for c := 0 to k - 1 do
    if not Chans[m.ch].pilot[c] then m.bits[c] := (b[3 + c div 4] shr (6 - 2 * (c mod 4))) and 3;
  Result := True;
end;

{ ---------- coding ---------- }

procedure HeaderEncode(typ, len, map: Integer; var h: array of Byte);
begin
  h[0] := typ; h[1] := len and 255; h[2] := ((len shr 8) and 7) or (map shl 3);
  RsEncode(h, 0, HDR_LEN, HDR_CHECK);
end;

function HeaderDecode(var h: array of Byte; out typ, len, map: Integer): Boolean;
begin
  Result := RsDecode(h, 0, HDR_CODED, HDR_CHECK) >= 0;
  typ := h[0]; len := h[1] or ((h[2] and 7) shl 8); map := h[2] shr 3;
end;

function CheckFor(k: Integer): Integer;
begin
  Result := 2 * ((k + 7) div 8);
  if Result < 8 then Result := 8;
  if Result > 32 then Result := 32;
end;

procedure Sizes(n: Integer; out nb: Integer; var k: array of Integer);
var b: Integer;
begin
  nb := (n + 222) div 223;
  for b := 0 to nb - 1 do
  begin
    k[b] := n div nb;
    if b < n mod nb then Inc(k[b]);
  end;
end;

function CodedLength(msgLen: Integer): Integer;
var k: array[0..15] of Integer; nb, b: Integer;
begin
  Sizes(msgLen + 2, nb, k);
  Result := 0;
  for b := 0 to nb - 1 do Inc(Result, k[b] + CheckFor(k[b]));
end;

procedure PayloadEncode(const msg: array of Byte; msgLen: Integer; var coded: array of Byte);
var all: array[0..MAXMSG + 2] of Byte; cw: array[0..15, 0..254] of Byte;
    k, cl: array[0..15] of Integer; nb, b, i, at, o, j, longest: Integer; c: Word;
begin
  for i := 0 to msgLen - 1 do all[i] := msg[i];
  c := Crc16(msg, 0, msgLen);
  all[msgLen] := c shr 8; all[msgLen + 1] := c and 255;
  Sizes(msgLen + 2, nb, k);
  at := 0; longest := 0;
  for b := 0 to nb - 1 do
  begin
    for i := 0 to k[b] - 1 do cw[b, i] := all[at + i];
    RsEncode(cw[b], 0, k[b], CheckFor(k[b]));
    Inc(at, k[b]);
    cl[b] := k[b] + CheckFor(k[b]);
    if cl[b] > longest then longest := cl[b];
  end;
  o := 0;
  for j := 0 to longest - 1 do
    for b := 0 to nb - 1 do
      if j < cl[b] then begin coded[o] := cw[b, j]; Inc(o); end;
end;

function PayloadDecode(var coded: array of Byte; msgLen: Integer; var msg: array of Byte; out fixed: Integer): Boolean;
var all: array[0..MAXMSG + 2] of Byte; cw: array[0..15, 0..254] of Byte;
    k, cl: array[0..15] of Integer; nb, b, i, at, o, j, longest, r: Integer; c: Word;
begin
  Result := False; fixed := 0;
  Sizes(msgLen + 2, nb, k);
  longest := 0;
  for b := 0 to nb - 1 do
  begin
    cl[b] := k[b] + CheckFor(k[b]);
    if cl[b] > longest then longest := cl[b];
  end;
  o := 0;
  for j := 0 to longest - 1 do
    for b := 0 to nb - 1 do
      if j < cl[b] then begin cw[b, j] := coded[o]; Inc(o); end;
  at := 0;
  for b := 0 to nb - 1 do
  begin
    r := RsDecode(cw[b], 0, cl[b], CheckFor(k[b]));
    if r < 0 then Exit;
    Inc(fixed, r);
    for i := 0 to k[b] - 1 do all[at + i] := cw[b, i];
    Inc(at, k[b]);
  end;
  c := Crc16(all, 0, msgLen);
  if (all[msgLen] <> (c shr 8)) or (all[msgLen + 1] <> (c and 255)) then Exit;
  for i := 0 to msgLen - 1 do msg[i] := all[i];
  Result := True;
end;

initialization
  InitAll;
end.
