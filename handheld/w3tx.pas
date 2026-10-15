unit w3tx;
{ Format 3 frames made on the handheld: at the modem rate (51,200), then
  converted to the sound card's 44,100. Whole numbers only. }
{$mode objfpc}{$H+}
interface

uses w3core, w3dsp;

type
  TSamples = array of SmallInt;

{ A frame at 44,100 samples/s. level: peak of 32767 (0 = the channel's default). }
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
  Scramble(hdr, HDR_CODED);
  SetLength(hr.b, HDR_CODED);
  for i := 0 to HDR_CODED - 1 do hr.b[i] := hdr[i];
  hr.pos := 0;
  if typ <> T_TRAIN then
  begin
    SetLength(pr.b, CodedLength(msgLen));
    PayloadEncode(msg, msgLen, pr.b);
    Scramble(pr.b, Length(pr.b));
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
      amp := CAR_AMP;
      if s = 0 then
      begin
        if (C.bins[cc] mod C.syncStep) <> 0 then Continue;
        p := 2 * SPhase(cc);
        amp := 724;                                    { S uses half the carriers: as much power as the others }
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
  { loudness: RMS a third of the peak (data symbols), then clip at the peak; the silent channels
    RMS 1/2.2 of the peak (a little clipping, 3.5 dB more power per carrier) }
  if level <= 0 then level := C.level;
  from := 2 * NSYM;
  e := 0;
  for i := from to total - 1 do e := e + Int64(acc[i]) * acc[i];
  if total - from > 0 then g := ISqrt(e div (total - from)) else g := 1;
  if g < 1 then g := 1;
  if C.silent then gq := (Int64(level) * 65536 * 10) div (22 * g) else gq := (Int64(level) * 65536) div (3 * g);
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

function To44(const x: TSamples): TSamples;
var r: TResampler; pad: TSamples; n, i: Integer;
begin
  RsInit(r, Int64(MRATE) * 100, 4410000, False);
  SetLength(pad, Length(x) + RSM_TAPS);
  for i := 0 to High(pad) do pad[i] := 0;
  for i := 0 to High(x) do pad[i] := x[i];
  SetLength(Result, Length(pad) * 44100 div MRATE + 64);
  n := RsProcess(r, pad, 0, Length(pad), Result, 0);
  SetLength(Result, n);
end;

function MakeFrame(ch: Integer; const map: TBitMap; typ: Integer; const msg: array of Byte; msgLen, level: Integer): TSamples;
begin
  Result := To44(Build(ch, map, typ, msg, msgLen, level));
end;

function MakeTrain(ch, level: Integer): TSamples;
var m: TBitMap; none: array[0..0] of Byte;
begin
  StdMap(ch, m);
  none[0] := 0;
  Result := To44(Build(ch, m, T_TRAIN, none, 0, level));
end;

end.
