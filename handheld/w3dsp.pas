unit w3dsp;
{ Whole-number signal processing for format 3 on the handheld: a 512-point
  FFT, angles (CORDIC), sines, and a rate converter. }
{$mode objfpc}{$H+}
interface

const
  TURN = 65536;                       { angles are in 1/65536 of a turn }
  RSM_TAPS = 24; RSM_H = 12; RSM_PH = 256;
{$I w3tab.inc}

type
  TCpx = array[0..511] of LongInt;
  { a stream rate converter }
  TResampler = record
    up: Boolean;                      { True: the listening table, False: the sending table }
    hist: array of SmallInt;
    have: Integer;
    posI: LongInt;                    { output position in input samples (whole part, relative to hist[0]) }
    posF: LongWord;                   { and its fraction, of 2^32 }
    stepI: LongInt; stepF: LongWord;
  end;

{ Forward (sign -1) or inverse (+1) FFT. With halve, each stage halves (input up to 32767 stays in range:
  the result is the sum divided by 512). Without, the input must be small (below 2^16 / carriers). }
procedure Fft(var re, im: TCpx; sign: Integer; halve: Boolean);
function Atan2i(y, x: LongInt): Integer;          { 0 .. 65535 }
function CosI(a: Integer): Integer;               { Q14 }
function SinI(a: Integer): Integer;
function MagI(x, y: LongInt): LongInt;            { about the length of (x, y) }
function WrapA(a: LongInt): LongInt;              { to -32768 .. 32767 }

{ rates in hundredths of a hertz, e.g. 4322960 for 43,229.60 samples/s }
procedure RsInit(var r: TResampler; inRate100, outRate100: Int64; up: Boolean);
procedure RsSetRates(var r: TResampler; inRate100, outRate100: Int64);
function ISqrt(v: Int64): Int64;
function Db100(v: Int64): Integer;               { 100 x log10(v), v >= 1 }
{ converts n input samples; returns the number written to output }
function RsProcess(var r: TResampler; const inp: array of SmallInt; inOff, n: Integer; var outp: array of SmallInt; outOff: Integer): Integer;

implementation

var
  Rev: array[0..511] of Integer;

procedure InitRev;
var i, r, b: Integer;
begin
  for i := 0 to 511 do
  begin
    r := 0;
    for b := 0 to 8 do if (i and (1 shl b)) <> 0 then r := r or (1 shl (8 - b));
    Rev[i] := r;
  end;
end;

function CosI(a: Integer): Integer; begin Result := COS4K[(a shr 4) and 4095]; end;
function SinI(a: Integer): Integer; begin Result := COS4K[((a shr 4) - 1024) and 4095]; end;

procedure Fft(var re, im: TCpx; sign: Integer; halve: Boolean);
var i, j, len, half, stp, k, a, b, t: Integer; wr, wi, xr, xi: LongInt;
begin
  for i := 0 to 511 do
  begin
    j := Rev[i];
    if j > i then
    begin
      t := re[i]; re[i] := re[j]; re[j] := t;
      t := im[i]; im[i] := im[j]; im[j] := t;
    end;
  end;
  len := 2;
  while len <= 512 do
  begin
    half := len shr 1; stp := 4096 div len;
    { each twiddle once, then every butterfly that uses it }
    for k := 0 to half - 1 do
    begin
      wr := COS4K[(k * stp) and 4095];
      if sign < 0 then wi := -COS4K[((k * stp) - 1024) and 4095] else wi := COS4K[((k * stp) - 1024) and 4095];
      a := k;
      while a < 512 do
      begin
        b := a + half;
        xr := SarLongint(re[b] * wr - im[b] * wi, 14);
        xi := SarLongint(re[b] * wi + im[b] * wr, 14);
        if halve then
        begin
          re[b] := SarLongint(re[a] - xr, 1); im[b] := SarLongint(im[a] - xi, 1);
          re[a] := SarLongint(re[a] + xr, 1); im[a] := SarLongint(im[a] + xi, 1);
        end
        else
        begin
          re[b] := re[a] - xr; im[b] := im[a] - xi;
          re[a] := re[a] + xr; im[a] := im[a] + xi;
        end;
        Inc(a, len);
      end;
    end;
    len := len shl 1;
  end;
end;

function Atan2i(y, x: LongInt): Integer;
var a, i: Integer; nx, ny: LongInt;
begin
  if (x = 0) and (y = 0) then begin Result := 0; Exit; end;
  a := 0;
  if x < 0 then begin x := -x; y := -y; a := 32768; end;
  { keep the numbers small enough for the shifts below }
  while (Abs(x) > 1 shl 28) or (Abs(y) > 1 shl 28) do begin x := x div 2; y := y div 2; end;
  x := x shl 2; y := y shl 2;
  for i := 0 to 15 do
  begin
    if y > 0 then
    begin
      nx := x + (y div (1 shl i)); ny := y - (x div (1 shl i)); a := a + ATANTAB[i];
    end
    else
    begin
      nx := x - (y div (1 shl i)); ny := y + (x div (1 shl i)); a := a - ATANTAB[i];
    end;
    x := nx; y := ny;
  end;
  Result := a and $FFFF;
end;

function MagI(x, y: LongInt): LongInt;
begin
  x := Abs(x); y := Abs(y);
  if x > y then Result := x + y div 2 - y div 8 else Result := y + x div 2 - x div 8;
end;

function WrapA(a: LongInt): LongInt;
begin
  Result := ((a + 32768) and $FFFF) - 32768;
end;

{ ---------- rate converter ---------- }

procedure RsSetRates(var r: TResampler; inRate100, outRate100: Int64);
var whole, rest: Int64;
begin
  { input samples per output sample, as a whole part and a fraction of 2^32 }
  whole := inRate100 div outRate100;
  rest := inRate100 - whole * outRate100;
  r.stepI := whole;
  r.stepF := LongWord((rest shl 32) div outRate100);
end;

procedure RsInit(var r: TResampler; inRate100, outRate100: Int64; up: Boolean);
begin
  r.up := up;
  SetLength(r.hist, 4096 + 2 * RSM_TAPS);
  r.have := 0;
  r.posI := RSM_H - 1; r.posF := 0;
  RsSetRates(r, inRate100, outRate100);
end;

function ISqrt(v: Int64): Int64;
var x, y: Int64;
begin
  if v <= 0 then begin Result := 0; Exit; end;
  x := v; y := (x + 1) div 2;
  while y < x do begin x := y; y := (x + v div x) div 2; end;
  Result := x;
end;

function Db100(v: Int64): Integer;
var e, m: Integer;
begin
  if v < 1 then v := 1;
  e := 0;
  while v >= 512 do begin v := v shr 1; Inc(e); end;
  while v < 256 do begin v := v shl 1; Dec(e); end;
  m := v - 256;                                   { v = 2^e x (256 + m), 0 <= m < 256 }
  { log2(v) = e + 8 + LOG2TAB[m] / 4096; 100 log10 = log2 x 30.103 }
  Result := (Int64((e + 8) * 4096 + LOG2TAB[m]) * 30103) div 4096000;
end;

function RsProcess(var r: TResampler; const inp: array of SmallInt; inOff, n: Integer; var outp: array of SmallInt; outOff: Integer): Integer;
var w, i, take, k, p, s0, keep: Integer; acc: LongInt; f: LongWord; hp, cp: PSmallInt;
begin
  w := 0; i := 0;
  while i < n do
  begin
    take := n - i;
    if take > Length(r.hist) - r.have then take := Length(r.hist) - r.have;
    for k := 0 to take - 1 do r.hist[r.have + k] := inp[inOff + i + k];
    Inc(r.have, take); Inc(i, take);
    while r.posI + RSM_H + 1 < r.have do
    begin
      { the nearest of the 256 sub-steps (at most 1/512 of a sample off: a phase error of
        0.006 radians at 20 kHz, far below the noise), so each tap is one multiply }
      p := (r.posF shr 23 + 1) shr 1;
      if p > RSM_PH then p := RSM_PH;          { the table has one more row, for the next sample }
      s0 := r.posI - (RSM_H - 1);
      hp := @r.hist[s0];
      if r.up then cp := @RSM_UP[p * RSM_TAPS] else cp := @RSM_DOWN[p * RSM_TAPS];
      acc := 0;
      for k := 0 to RSM_TAPS - 1 do acc := acc + LongInt(hp[k]) * cp[k];
      acc := SarLongint(acc, 14);
      if acc > 32767 then acc := 32767 else if acc < -32767 then acc := -32767;
      outp[outOff + w] := acc; Inc(w);
      f := r.posF + r.stepF;
      if f < r.posF then Inc(r.posI);           { carry }
      r.posF := f;
      Inc(r.posI, r.stepI);
    end;
    keep := r.posI - (RSM_H - 1) - 1;
    if keep > 0 then
    begin
      for k := 0 to r.have - keep - 1 do r.hist[k] := r.hist[keep + k];
      Dec(r.have, keep); Dec(r.posI, keep);
    end;
  end;
  Result := w;
end;

initialization
  InitRev;
end.
