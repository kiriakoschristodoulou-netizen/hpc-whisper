unit w3tx;
{ Format 3 frames made on the handheld: at the modem rate (51,200), then
  converted to the rate the sound card plays at (TxRate: 44,100, or the rate
  the sound chip really runs at, when the card takes it). Whole numbers only. }
{$mode objfpc}{$H+}
interface

uses w3core, w3dsp;

type
  TSamples = array of SmallInt;

var
  { the rate frames are made at: what the speaker is opened with }
  TxRate: Integer = 44100;

{ A frame at TxRate samples/s. level: peak of 32767 (0 = the channel's default). }
function MakeFrame(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;
function MakeTrain(ch, level: Integer): TSamples;
{ the same at the modem rate (tests) }
function MakeFrame51(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;

implementation

type
  TBitReader = record
    b: array of Byte;
    pos: Integer;
  end;

function Take(var r: TBitReader; n: Integer): Integer;
var i, bit: Integer;
begin
  Result := 0;
  for i := 1 to n do
  begin
    if r.pos < Length(r.b) * 8 then bit := (r.b[r.pos shr 3] shr (7 - (r.pos and 7))) and 1 else bit := 0;
    Result := (Result shl 1) or bit;
    Inc(r.pos);
  end;
end;

function GrayIndex(g: Integer): Integer; begin Result := g xor (g shr 1) xor (g shr 2); end;

function Build(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;
const CAR_AMP = 512;
var C: TChannel; std: TBitMap; hr, pr: TBitReader;
    hdr: array[0..HDR_CODED - 1] of Byte;
    hb, pb, hsym, psym, nsy, s, cc, nb, p, i, k, base, total, from: Integer;
    ph: array[0..MAXCAR - 1] of Integer;
    step: Integer; head: Boolean;
    re, im: TCpx; acc: array of LongInt; e: Int64; g: Int64; gq: Int64; v: Int64; amp: Integer;
begin
  C := Chans[ch];
  StdMap(ch, std);
  HeaderEncode(typ, msgLen, map.number, hdr);
  Scramble(hdr, HDR_CODED, ch);
  SetLength(hr.b, HDR_CODED);
  for i := 0 to HDR_CODED - 1 do hr.b[i] := hdr[i];
  hr.pos := 0;
  if typ <> T_TRAIN then
  begin
    SetLength(pr.b, CodedLength(msgLen));
    PayloadEncode(msg, msgLen, pr.b);
    Scramble(pr.b, Length(pr.b), ch);
  end
  else SetLength(pr.b, 0);
  pr.pos := 0;
  hb := MapBits(std); pb := MapBits(map);
  hsym := (HDR_CODED * 8 + hb - 1) div hb;
  if typ = T_TRAIN then psym := TRAIN_SYMBOLS
  else
  begin
    if pb < 1 then pb := 1;
    psym := (Length(pr.b) * 8 + pb - 1) div pb;
  end;
  nsy := 2 + hsym + psym;
  total := nsy * NSYM + NFADE;
  SetLength(acc, total);
  for i := 0 to total - 1 do acc[i] := 0;
  for cc := 0 to C.n - 1 do ph[cc] := 0;
  for s := 0 to nsy - 1 do
  begin
    for i := 0 to 511 do begin re[i] := 0; im[i] := 0; end;
    head := s < 2 + hsym;
    for cc := 0 to C.n - 1 do
    begin
      { the silent channels have few carriers: build them 8 times larger, so that rounding in whole
        numbers stays far below hearing (512 left noise only 50 dB under the carriers) }
      if C.silent then amp := CAR_AMP * 8 else amp := CAR_AMP;
      if s = 0 then
      begin
        if (C.bins[cc] mod C.syncStep) <> 0 then Continue;
        p := 2 * SPhase(cc);
        if C.silent then amp := 724 * 8 else amp := 724; { S uses half the carriers: as much power as the others }
      end
      else if s = 1 then begin p := 2 * RPhase(cc); ph[cc] := p; end
      else
      begin
        if (not head) and (typ = T_TRAIN) then step := 2 * TrainStep(cc, s - 2 - hsym)
        else if C.pilot[cc] then step := 0
        else
        begin
          if head then nb := std.bits[cc] else nb := map.bits[cc];
          if nb = 0 then Continue;
          if head then step := GrayIndex(Take(hr, nb)) * (8 shr nb)
          else step := GrayIndex(Take(pr, nb)) * (8 shr nb);
        end;
        ph[cc] := (ph[cc] + step) and 7;
        p := ph[cc];
      end;
      re[C.bins[cc]] := amp * CosI(p * 8192) div 16384;
      im[C.bins[cc]] := amp * SinI(p * 8192) div 16384;
    end;
    Fft(re, im, 1, False);
    base := s * NSYM + NCP;
    for k := -NCP to NFFT + NFADE - 1 do
    begin
      v := re[((k mod NFFT) + NFFT) mod NFFT];
      if k < -NCP + NFADE then v := v * FADETAB[k + NCP] div 32767
      else if k >= NFFT then v := v * (32767 - FADETAB[k - NFFT]) div 32767;   { the exact complement of the next symbol's fade-in }
      acc[base + k] := acc[base + k] + v;
    end;
  end;
  { loudness. Silent channels: the peak at the level, never clipped (clipping a sound near 20 kHz makes
    harmonics that fold back to 6-12 kHz, where they are heard: device test, 16 October 2026).
    Fast channels (a soft hiss anyway): RMS a third of the peak, then clip at the peak. }
  if level <= 0 then level := C.level;
  from := 2 * NSYM;
  e := 0;
  if C.silent then
  begin
    g := 1;
    for i := 0 to total - 1 do if Abs(acc[i]) > g then g := Abs(acc[i]);
    gq := (Int64(level) * 65536) div g;
  end
  else
  begin
    for i := from to total - 1 do e := e + Int64(acc[i]) * acc[i];
    if total - from > 0 then g := ISqrt(e div (total - from)) else g := 1;
    if g < 1 then g := 1;
    gq := (Int64(level) * 65536) div (3 * g);
  end;
  SetLength(Result, total);
  for i := 0 to total - 1 do
  begin
    v := (Int64(acc[i]) * gq) div 65536;
    if v > level then v := level else if v < -level then v := -level;
    Result[i] := v;
  end;
end;

function MakeFrame51(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;
begin
  Result := Build(ch, map, typ, msg, msgLen, level);
end;

{ 51,200 to 44,100 is always 512 : 441, so the filter's sub-steps repeat every 441 samples out: their
  441 rows are made once (between the table's nearest sub-steps), and each sample out is then one
  multiply per tap, at the exact sub-step. (The nearest sub-step alone left noise 54 dB under a silent
  frame, in the band people hear; working between two on every sample cost a fifth more time.) }
var
  Tx44: array of SmallInt;                   { 441 rows of RSM_TAPS }

procedure MakeTx44;
var f, k, p0, w, c0, c1: Integer;
begin
  SetLength(Tx44, 441 * RSM_TAPS);
  for f := 0 to 440 do
  begin
    { the sub-step f / 441 of a sample, in 256ths, and the rest in 256ths of that }
    p0 := (f * 256) div 441;
    w := ((f * 256 * 256) div 441) and 255;
    for k := 0 to RSM_TAPS - 1 do
    begin
      c0 := RSM_DOWN[p0 * RSM_TAPS + k]; c1 := RSM_DOWN[(p0 + 1) * RSM_TAPS + k];
      Tx44[f * RSM_TAPS + k] := c0 + ((c1 - c0) * w) div 256;
    end;
  end;
end;

function To44(const x: TSamples): TSamples;
var n, j, i, f, k: Integer; acc: LongInt; pad: TSamples; cp: PSmallInt;
begin
  if Length(Tx44) = 0 then MakeTx44;
  SetLength(pad, Length(x) + 2 * RSM_TAPS);
  for i := 0 to High(pad) do pad[i] := 0;
  for i := 0 to High(x) do pad[i + RSM_H - 1] := x[i];     { centred: sample j out sits at sample j * 512 / 441 in }
  n := Int64(Length(x) + RSM_TAPS div 2) * 441 div 512;
  SetLength(Result, n);
  i := 0; f := 0;                                           { the sample before, and the sub-step (of 441) }
  for j := 0 to n - 1 do
  begin
    cp := @Tx44[f * RSM_TAPS];
    acc := 0;
    for k := 0 to RSM_TAPS - 1 do acc := acc + LongInt(pad[i + k]) * cp[k];
    acc := SarLongint(acc, 14);
    if acc > 32767 then acc := 32767 else if acc < -32767 then acc := -32767;
    Result[j] := acc;
    { the next sample out is 512/441 samples on: no division (the processor has none) }
    Inc(f, 512);
    while f >= 441 do begin Dec(f, 441); Inc(i); end;
  end;
end;

{ 51,200 to any other rate (the sound chip's own, such as 43,203): the next sample out lies 51,200 / rate
  samples on, kept as a whole number and a fraction of 2^32. The filter is taken at the nearest of 1,024
  sub-steps, made once between the table's 256 (the timing then errs by at most 1/2048 of a sample: noise
  58 dB down at 21 kHz), so each sample out costs what one at 44,100 does. }
var
  TxFine: array of SmallInt;                 { 1,024 rows of RSM_TAPS }

procedure MakeTxFine;
var f, k, p0, w, c0, c1: Integer;
begin
  SetLength(TxFine, 1024 * RSM_TAPS);
  for f := 0 to 1023 do
  begin
    p0 := f shr 2; w := (f and 3) * 64;
    for k := 0 to RSM_TAPS - 1 do
    begin
      c0 := RSM_DOWN[p0 * RSM_TAPS + k]; c1 := RSM_DOWN[(p0 + 1) * RSM_TAPS + k];
      TxFine[f * RSM_TAPS + k] := c0 + ((c1 - c0) * w) div 256;
    end;
  end;
end;

function ToRate(const x: TSamples; rate: Integer): TSamples;
var n, j, i, k, stepI: Integer; acc: LongInt; pad: TSamples; stepF, f: LongWord; cp: PSmallInt; nf: Int64;
begin
  if Length(TxFine) = 0 then MakeTxFine;
  SetLength(pad, Length(x) + 2 * RSM_TAPS);
  for i := 0 to High(pad) do pad[i] := 0;
  for i := 0 to High(x) do pad[i + RSM_H - 1] := x[i];
  n := Int64(Length(x) + RSM_TAPS div 2) * rate div MRATE;
  SetLength(Result, n);
  stepI := MRATE div rate;
  stepF := LongWord((Int64(MRATE mod rate) shl 32) div rate);
  i := 0; f := 0;
  for j := 0 to n - 1 do
  begin
    { the nearest of 1,024 sub-steps (rounded; the last rounds up into the next sample's first) }
    k := ((f shr 21) + 1) shr 1;
    if k = 1024 then cp := @TxFine[0] else cp := @TxFine[k * RSM_TAPS];
    acc := 0;
    if k = 1024 then for k := 0 to RSM_TAPS - 1 do acc := acc + LongInt(pad[i + 1 + k]) * cp[k]
    else for k := 0 to RSM_TAPS - 1 do acc := acc + LongInt(pad[i + k]) * cp[k];
    acc := SarLongint(acc, 14);
    if acc > 32767 then acc := 32767 else if acc < -32767 then acc := -32767;
    Result[j] := acc;
    nf := Int64(f) + stepF;
    if nf >= Int64(1) shl 32 then Inc(i);
    f := LongWord(nf and $FFFFFFFF);
    Inc(i, stepI);
  end;
end;

function ToTx(const x: TSamples): TSamples;
begin
  if TxRate = 44100 then Result := To44(x) else Result := ToRate(x, TxRate);
end;

function MakeFrame(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;
begin
  Result := ToTx(Build(ch, map, typ, msg, msgLen, level));
end;

function MakeTrain(ch, level: Integer): TSamples;
var m: TBitMap; none: array[0..0] of Byte;
begin
  StdMap(ch, m);
  none[0] := 0;
  Result := ToTx(Build(ch, m, T_TRAIN, none, 0, level));
end;

end.
