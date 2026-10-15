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
    i := 0;
    while i < 512 do
    begin
      for k := 0 to half - 1 do
      begin
        wr := COS4K[(k * stp) and 4095];
        if sign < 0 then wi := -COS4K[((k * stp) - 1024) and 4095] else wi := COS4K[((k * stp) - 1024) and 4095];
        a := i + k; b := a + half;
        xr := (re[b] * wr - im[b] * wi) div 16384;
        xi := (re[b] * wi + im[b] * wr) div 16384;
        if halve then
        begin
          re[b] := (re[a] - xr) div 2; im[b] := (im[a] - xi) div 2;
          re[a] := (re[a] + xr) div 2; im[a] := (im[a] + xi) div 2;
        end
        else
        begin
          re[b] := re[a] - xr; im[b] := im[a] - xi;
          re[a] := re[a] + xr; im[a] := im[a] + xi;
        end;
      end;
      Inc(i, len);
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
var w, i, take, k, p, s0, keep, c0, c1, wt: Integer; acc: LongInt; f: LongWord;
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
      p := r.posF shr 24;                       { which of the 256 sub-steps }
      wt := (r.posF shr 8) and $FFFF;           { how far towards the next, of 65536 }
      s0 := r.posI - (RSM_H - 1);
      acc := 0;
      if r.up then
        for k := 0 to RSM_TAPS - 1 do
        begin
          c0 := RSM_UP[p * RSM_TAPS + k]; c1 := RSM_UP[(p + 1) * RSM_TAPS + k];
          acc := acc + r.hist[s0 + k] * (c0 + ((c1 - c0) * wt) div 65536);
        end
      else
        for k := 0 to RSM_TAPS - 1 do
        begin
          c0 := RSM_DOWN[p * RSM_TAPS + k]; c1 := RSM_DOWN[(p + 1) * RSM_TAPS + k];
          acc := acc + r.hist[s0 + k] * (c0 + ((c1 - c0) * wt) div 65536);
        end;
      acc := acc div 16384;
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
