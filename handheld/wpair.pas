unit wpair;
{ Whisper Tools: the pairing sound check (docs/FORMAT3.md, section 7). A pattern
  simple enough to be found whatever the speaker, the microphone, the sample
  rate or the room do to it: two 2 kHz markers 2.69 s apart, and between them 32
  short tones from 500 Hz to 21.5 kHz. The listener finds the markers, measures
  how much time stretched between them (the two devices' real sample rates), and
  how loud each tone arrived above the background. Whole numbers only; no Windows
  calls: tested on Linux against the phone's Java. }
{$mode objfpc}{$H+}
interface

const
  PAIR_N = 32;
  PAIR_HZ: array[0..PAIR_N - 1] of Integer = (500, 1000, 1500, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
    10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000, 17500, 18000, 18500, 19000, 19400, 19800, 20200,
    20400, 20600, 20800, 21000, 21200, 21500);
  PAIR_LEAD_MS = 150; PAIR_MARK_MS = 250; PAIR_GAP_MS = 100; PAIR_STEP_MS = 70; PAIR_TAIL_MS = 100;
  PAIR_MARK_HZ = 2000; LEAD_HZ = 21700;
  PAIR_A_MS = PAIR_LEAD_MS;                                                    { marker A starts }
  PAIR_STEPS_MS = PAIR_A_MS + PAIR_MARK_MS + PAIR_GAP_MS;                     { the first step starts }
  PAIR_B_MS = PAIR_STEPS_MS + PAIR_N * PAIR_STEP_MS + PAIR_GAP_MS;            { marker B starts }
  PAIR_AB_MS = PAIR_B_MS - PAIR_A_MS;                                          { 2,690 ms }
  PAIR_TOTAL_MS = PAIR_B_MS + PAIR_MARK_MS + PAIR_TAIL_MS;                     { 3,190 ms }
  PAIR_REPORT = $34;
  PAIR_REPORT_LEN = 40;          { 38 measurements, then the loudness the sender should use: ladder step + 1 (0 = none), its quality }
  { the loudness ladder after the handheld's test sound: its silent channel at falling peaks, each as a TRAIN frame }
  LADDER_N = 6;
  LADDER_GAP_MS = 150;
  PAIR_LADDER: array[0..LADDER_N - 1] of Integer = (29000, 20500, 14500, 10250, 7250, 5100);   { about 3 dB apart }

type
  TPairResult = record
    found: Boolean;
    snr10: array[0..PAIR_N - 1] of Integer;   { tenths of a dB above the background }
    scale10k: Integer;                        { time between the markers / 2.69 s, x 10000 }
    peak: Integer;                            { loudest sample, % of full scale }
    clipped: Boolean;
    aAt: Integer;                             { where marker A starts, in samples }
    ladder: Integer;                          { the loudness ladder step the other side should use, -1 = none }
    ladderQ: Integer;                         { how clean it arrived (dB) }
    pitchOk: Boolean;                         { the markers' pitch was measured (3.9.2) }
    pitchPpm: Integer;                        { how much higher than 2 kHz the markers sound, ppm: the sound card's rate is that much slower than it claims }
  end;
  TSmallArr = array of SmallInt;

{ the pattern at this rate (Hz); peak loudness: markers half of full scale, tones a third }
function PairPattern(rate: Integer): TSmallArr;
{ why the last analysis found nothing (for the log) }
var PairWhy: string = '';
{ looks for the pattern in x[0..n-1] (recorded at rate, as the sound card says) }
function PairAnalyze(const x: array of SmallInt; n, rate: Integer; var res: TPairResult): Boolean;
function PairReportMake(const res: TPairResult; var b: array of Byte): Integer;
function PairReportRead(const b: array of Byte; n: Integer; var res: TPairResult): Boolean;
{ the loudness ladder at 44,100 samples/s: for each peak, a TRAIN frame of the silent channel ch, then a gap }
function PairLadder(ch: Integer; const peaks: array of Integer): TSmallArr;
{ the average of the tones from loHz to hiHz, tenths of a dB }
function PairBand10(const res: TPairResult; loHz, hiHz: Integer): Integer;

implementation

uses w3dsp, w3core, w3tx;

const Q = 16384;

function NS(v: Int64): string;
begin
  Str(v, Result);
end;

{ cos of a (1/65536 of a turn), Q14, between the table's 4096 points }
function CosF(a: LongInt): LongInt;
var i, f: LongInt; c0, c1: LongInt;
begin
  a := a and $FFFF;
  i := a shr 4; f := a and 15;
  c0 := COS4K[i]; c1 := COS4K[(i + 1) and 4095];
  Result := c0 + ((c1 - c0) * f) div 16;
end;

function SinT(hz, i, rate: Int64): Integer;           { sin(2 pi hz i / rate), Q14 }
begin
  Result := CosF(LongInt(((hz * i * 65536) div rate) and $FFFF) - 16384);
end;

function PairPattern(rate: Integer): TSmallArr;
var n, i, k, ramp: Integer;

  procedure Tone(fromMs, ms, hz, peak: Integer);
  var s, e, t: Integer; g: Int64;
  begin
    s := Int64(fromMs) * rate div 1000; e := Int64(fromMs + ms) * rate div 1000;
    ramp := rate div 200;                                { 5 ms in and out: no clicks }
    for t := s to e - 1 do
    begin
      g := peak;
      if t - s < ramp then g := g * (t - s) div ramp;
      if e - 1 - t < ramp then g := g * (e - 1 - t) div ramp;
      Result[t] := (g * SinT(hz, t - s, rate)) div Q;
    end;
  end;

begin
  n := Int64(PAIR_TOTAL_MS) * rate div 1000;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := 0;
  Tone(0, PAIR_LEAD_MS, LEAD_HZ, 1000);                  { keeps the sound path awake, inaudible }
  { quieter than at first (16,000 and 11,000): played loud, a handheld's amplifier gave up after the first marker }
  Tone(PAIR_A_MS, PAIR_MARK_MS, PAIR_MARK_HZ, 9000);
  for k := 0 to PAIR_N - 1 do Tone(PAIR_STEPS_MS + k * PAIR_STEP_MS, PAIR_STEP_MS, PAIR_HZ[k], 6000);
  Tone(PAIR_B_MS, PAIR_MARK_MS, PAIR_MARK_HZ, 9000);
end;

{ the power of one frequency over x[a..b), Goertzel; hz may be fractional (x 100) }
function Power(const x: array of SmallInt; a, b, n: Integer; hz100: Int64; rate: Integer): Int64;
var c: Int64; s0, s1, s2: Int64; i, len: Integer;
begin
  if a < 0 then a := 0;
  if b > n then b := n;
  len := b - a;
  Result := 0;
  if len < 16 then Exit;
  c := Int64(2) * CosF(LongInt((hz100 * 65536 div (Int64(rate) * 100)) and $FFFF)) * 4;   { 2 cos w, Q16 }
  s1 := 0; s2 := 0;
  for i := a to b - 1 do
  begin
    s0 := x[i] + (c * s1) div 65536 - s2;
    s2 := s1; s1 := s0;
  end;
  { |X|^2 = s1^2 + s2^2 - c s1 s2, per sample, in whole numbers. s1 and s2 stay below about 4e7 (full
    loudness, 50 ms), so their squares (below 2e15) fit in 64 bits without scaling down first; the old
    scaling rounded quiet tones to nothing (0 dB where they were 10-40 dB above the room). No floating
    point: the handheld has no unit for it, and its library functions are not proven on the device. }
  Result := (s1 * s1 + s2 * s2 - (c * s1 div 65536) * s2) div len;
  if Result < 1 then Result := 1;
end;

{ where the 2 kHz marker sounds: power in blocks of 5 ms }
function FindMarker(const x: array of SmallInt; n, rate, from: Integer; out at, peakBlock: Integer): Boolean;
var blk, nb, i, run, need, first: Integer; p: array of Int64; bg, top, thr: Int64;
begin
  Result := False; at := -1; peakBlock := 0;
  blk := rate div 200;
  nb := (n - from) div blk;
  if nb < 60 then Exit;
  SetLength(p, nb);
  for i := 0 to nb - 1 do p[i] := Power(x, from + i * blk, from + (i + 1) * blk, n, Int64(PAIR_MARK_HZ) * 100, rate);
  { the background: a low point; the marker: at least 120 ms clearly above it }
  top := 0;
  for i := 0 to nb - 1 do if p[i] > top then top := p[i];
  bg := top;
  for i := 0 to nb - 1 do if p[i] < bg then bg := p[i];
  thr := bg * 20;                                         { 13 dB above the quietest }
  if top div 4 > thr then thr := top div 4;
  need := 24;                                             { 120 ms }
  run := 0; first := -1;
  for i := 0 to nb - 1 do
  begin
    if p[i] > thr then
    begin
      if run = 0 then first := i;
      Inc(run);
      if run >= need then
      begin
        at := from + first * blk;
        peakBlock := first;
        Result := True;
        Exit;
      end;
    end
    else run := 0;
  end;
end;

{ The pitch of the marker that starts at sample `at`: the times the sound (without its constant part) rises through zero are
  fitted by a straight line, one period apart. A tone of 2 kHz at 44,100 has 22 samples to a period and 85 periods are used:
  a few ppm (3.9.2). The recording's rate against the phone's clock is this, much finer than the markers' spacing can say. }
function MarkerPitch(const x: array of SmallInt; n, rate, at: Integer; out ppm: Integer): Boolean;
const MAXC = 160;
var i, a, b, k, cnt, bad, c1: Integer; v0, y0, y1, y2, a1, a2: Int64; t: array[0..MAXC - 1] of Int64;
    sx, sy, sxx, sxy, den, slope, icpt, r, worst: Int64;
begin
  Result := False; ppm := 0;
  a := at + Integer(Int64(40) * rate div 1000);
  b := at + Integer(Int64(PAIR_MARK_MS - 40) * rate div 1000);
  if (at < 8) or (b + 8 >= n) or (b - a < rate div 10) then Exit;
  { a narrow band-pass round 2 kHz first (two poles at radius 0.97, a zero at 0 Hz: it also takes away the microphone's constant
    offset and the room's noise): the noise would otherwise move the times the sound crosses zero }
  c1 := CosF(Int64(PAIR_MARK_HZ) * 65536 div rate);
  a1 := -(Int64(2) * 15888 * c1) div 16384;              { -2 x 0.97 cos w, Q14 }
  a2 := 15417;                                            { 0.97^2, Q14 }
  y1 := 0; y2 := 0; v0 := 0; cnt := 0;
  for i := at to b do
  begin
    y0 := ((Int64(x[i]) - x[i - 2]) * 1024 - a1 * y1 - a2 * y2) div 16384;
    y2 := y1; y1 := y0;
    if i >= a then
    begin
      if (v0 < 0) and (y0 >= 0) and (cnt < MAXC) then
      begin
        t[cnt] := Int64(i - 1) * 4096 + (-v0 * 4096) div (y0 - v0);        { the crossing, in 1/4096 sample }
        Inc(cnt);
      end;
    end;
    v0 := y0;
  end;
  if cnt < 40 then Exit;
  { the line t = icpt + slope k }
  sx := 0; sy := 0; sxx := 0; sxy := 0;
  for k := 0 to cnt - 1 do
  begin
    sx := sx + k; sy := sy + (t[k] - t[0]); sxx := sxx + Int64(k) * k; sxy := sxy + Int64(k) * (t[k] - t[0]);
  end;
  den := cnt * sxx - sx * sx;
  if den = 0 then Exit;
  slope := (cnt * sxy - sx * sy) * 1024 div den;                          { x 1024 }
  icpt := (sy * 1024 - slope * sx) div cnt;                               { x 1024 }
  worst := 0; bad := 0;
  for k := 0 to cnt - 1 do
  begin
    r := (t[k] - t[0]) * 1024 - icpt - slope * k;
    if r < 0 then r := -r;
    if r > worst then worst := r;
    if r > Int64(4096) * 1024 * 3 div 10 then Inc(bad);                   { more than 0.3 sample off the line }
  end;
  if bad > cnt div 10 then Exit;                                           { not a clean tone }
  { period in samples x 4096 = slope / 1024; the tone's pitch against 2 kHz: (rate / period) / 2000 }
  { ppm = 10^6 (rate x 4096 x 1024 / (slope x 2000) - 1) }
  if slope < 1 then Exit;
  ppm := Integer((Int64(rate) * 4096 * 1024 * 1000000) div (slope * PAIR_MARK_HZ) - 1000000);
  if (ppm < -50000) or (ppm > 50000) then begin ppm := 0; Exit; end;
  Result := True;
end;

function PairAnalyze(const x: array of SmallInt; n, rate: Integer; var res: TPairResult): Boolean;
var a, b, dummy, i, c, half, bg0, bg1, pk, pa, pb: Integer; s10k: Int64; ps, pn: Int64; hz100: Int64; db: Integer;
begin
  FillChar(res, SizeOf(res), 0);
  res.ladder := -1;
  Result := False;
  PairWhy := '';
  if not FindMarker(x, n, rate, 0, a, dummy) then begin PairWhy := 'no marker (a 2 kHz tone of 120 ms, clearly above the rest) in ' + NS(Int64(n) * 1000 div rate) + ' ms of sound'; Exit; end;
  if not FindMarker(x, n, rate, a + Int64(PAIR_AB_MS - 300) * rate div 1000, b, dummy) then begin PairWhy := 'the first marker at ' + NS(Int64(a) * 1000 div rate) + ' ms, but no second one after it (' + NS(Int64(n - a) * 1000 div rate) + ' ms of sound after the first)'; Exit; end;
  s10k := Int64(b - a) * 10000 * 1000 div (Int64(PAIR_AB_MS) * rate);
  if (s10k < 9500) or (s10k > 10500) then begin PairWhy := 'two markers ' + NS(Int64(b - a) * 1000 div rate) + ' ms apart, not 2,690'; Exit; end;              { not our two markers }
  res.scale10k := s10k; res.aAt := a;
  { the pitch of the two markers, if they agree with each other and with the spacing }
  if MarkerPitch(x, n, rate, a, pa) and MarkerPitch(x, n, rate, b, pb) then
    if (Abs(pa - pb) < 300) and (Abs((pa + pb) div 2 - Integer(Int64(10000000000) div s10k - 1000000)) < 3000) then
    begin
      res.pitchOk := True; res.pitchPpm := (pa + pb) div 2;
    end;
  { the background: just before the lead-in (or as much of it as there is) }
  bg1 := a - Int64(PAIR_LEAD_MS + 40) * rate div 1000;
  bg0 := bg1 - Int64(300) * rate div 1000;
  if bg0 < 0 then bg0 := 0;
  for i := 0 to PAIR_N - 1 do
  begin
    c := a + Int64(PAIR_STEPS_MS - PAIR_A_MS + i * PAIR_STEP_MS + PAIR_STEP_MS div 2) * rate * s10k div 10000000;
    half := Int64(25) * rate div 1000;                     { the middle 50 ms of the 70 }
    hz100 := Int64(PAIR_HZ[i]) * 100 * 10000 div s10k;     { stretched time: lower frequencies }
    ps := Power(x, c - half, c + half, n, hz100, rate);
    if bg1 - bg0 >= 2 * half then pn := Power(x, bg1 - 2 * half, bg1, n, hz100, rate)
    else if bg1 > 16 then pn := Power(x, bg0, bg1, n, hz100, rate)
    else pn := 1;
    if pn < 1 then pn := 1;
    db := Db100(ps) - Db100(pn);                           { 100 log10 = tenths of a dB }
    res.snr10[i] := db;
  end;
  pk := 0;
  for i := a to b + Int64(PAIR_MARK_MS) * rate div 1000 do
    if (i >= 0) and (i < n) and (Abs(x[i]) > pk) then pk := Abs(x[i]);
  res.peak := pk * 100 div 32768;
  res.clipped := pk >= 32000;
  res.found := True;
  Result := True;
end;

function PairLadder(ch: Integer; const peaks: array of Integer): TSmallArr;
var t: TSamples; i, k, n, at, gap, top: Integer;
begin
  t := MakeTrain(ch, 29000);                                 { made once, then scaled: making it costs time }
  top := 1;
  for i := 0 to High(t) do if Abs(t[i]) > top then top := Abs(t[i]);
  gap := LADDER_GAP_MS * TxRate div 1000;
  n := Length(peaks) * (Length(t) + gap);
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := 0;
  at := 0;
  for k := 0 to High(peaks) do
  begin
    for i := 0 to High(t) do Result[at + i] := Int64(t[i]) * peaks[k] div top;
    Inc(at, Length(t) + gap);
  end;
end;

function PairBand10(const res: TPairResult; loHz, hiHz: Integer): Integer;
var i, s, k: Integer;
begin
  s := 0; k := 0;
  for i := 0 to PAIR_N - 1 do
    if (PAIR_HZ[i] >= loHz) and (PAIR_HZ[i] <= hiHz) then begin s := s + res.snr10[i]; Inc(k); end;
  if k > 0 then Result := s div k else Result := -999;
end;

function PairReportMake(const res: TPairResult; var b: array of Byte): Integer;
var i, v: Integer;
begin
  b[0] := 1; b[1] := PAIR_N;
  for i := 0 to PAIR_N - 1 do
  begin
    v := (res.snr10[i] + 5) div 10 + 20;                    { dB + 20 }
    if v < 0 then v := 0 else if v > 255 then v := 255;
    b[2 + i] := v;
  end;
  b[34] := (res.scale10k shr 8) and 255; b[35] := res.scale10k and 255;
  b[36] := res.peak; b[37] := Ord(res.clipped);
  if res.ladder >= 0 then b[38] := res.ladder + 1 else b[38] := 0;
  if res.ladderQ < 0 then b[39] := 0 else if res.ladderQ > 255 then b[39] := 255 else b[39] := res.ladderQ;
  Result := PAIR_REPORT_LEN;
end;

function PairReportRead(const b: array of Byte; n: Integer; var res: TPairResult): Boolean;
var i: Integer;
begin
  Result := False;
  FillChar(res, SizeOf(res), 0);
  if (n < PAIR_REPORT_LEN) or (b[0] <> 1) or (b[1] <> PAIR_N) then Exit;
  for i := 0 to PAIR_N - 1 do res.snr10[i] := (b[2 + i] - 20) * 10;
  res.scale10k := (b[34] shl 8) or b[35];
  res.peak := b[36]; res.clipped := (b[37] and 1) <> 0;
  res.ladder := b[38] - 1; res.ladderQ := b[39];
  res.found := True;
  Result := True;
end;

end.
