unit scanlib;
{ Mic Scan: what the test signal is, and how a recording of it is measured.

  The phone page (scan.html) plays a fixed test signal of a bit over a minute;
  the handheld records it through its microphone and measures it here, with
  whole numbers (the handheld has no floating point unit), to learn how the
  microphone really hears sound: which frequencies, how loud, where the
  response ends, whether the level follows the sound (automatic gain), how
  fast the gain reacts, the handheld's real sampling rate, ghost tones, and
  how short a burst it still notices.

  The plan below is the same in scanplan.js. }
{$mode objfpc}{$H+}
interface

const
  { the test signal, in milliseconds from the start of the first marker }
  MARK_HZ = 4000;
  MARK_MS = 600;
  END_AT = 75500;                       { the second marker starts here }
  PLAN_MS = 76100;
  NOISE_FROM = 1400; NOISE_TO = 2600;   { silence, to measure the background }

  { steady tones: 0.5 to 9.5 kHz every 500 Hz, 10 to 14.5 every 250 Hz, 15 to 21.5 every 500 Hz }
  NTONE = 52;
  TONE_AT0 = 3000; TONE_PERIOD = 500; TONE_MS = 400;
  TONE_AMP = 50;                        { percent of full scale }

  { does the level follow the sound? tones at five loudnesses, at three frequencies }
  NLINF = 3; NLINA = 5;
  LIN_AT0 = 29500; LIN_PERIOD = 1000; LIN_MS = 600;
  LIN_HZ: array[0..NLINF - 1] of Integer = (3000, 12000, 19000);
  LIN_AMP: array[0..NLINA - 1] of Integer = (90, 45, 22, 11, 6);      { percent of full scale }

  { gain tests: a tone, a silence, the tone again }
  NAGC = 4;
  AGC_AT0 = 45000; AGC_PERIOD = 5000; AGC_TONE_MS = 1500; AGC_GAP_MS = 1000;
  AGC_HZ: array[0..NAGC - 1] of Integer = (12000, 12000, 19000, 19000);
  AGC_AMP: array[0..NAGC - 1] of Integer = (90, 22, 90, 22);
  NENV = 8;                             { the points of the level curve kept: 20 ms windows starting here (ms) }
  ENV_AT: array[0..NENV - 1] of Integer = (0, 20, 50, 100, 200, 400, 800, 1400);

  { short bursts at two frequencies }
  NBSET = 2; NBURST = 4; BURST_N = 6; BURST_GAP = 150;
  BURST_AT: array[0..NBSET - 1] of Integer = (65500, 70500);
  BURST_HZ: array[0..NBSET - 1] of Integer = (12500, 19500);
  BURST_MS: array[0..NBURST - 1] of Integer = (10, 20, 40, 100);

type
  TSamples = array[0..MaxInt div 4] of SmallInt;
  PSamples = ^TSamples;

  TScanResult = record
    ok: Boolean;
    err: string[100];
    n: LongInt;                         { samples in the recording }
    rate100: LongInt;                   { the real sampling rate x 100 (samples per real second) }
    t0, t1: LongInt;                    { sample where each marker starts }
    dc: LongInt;                        { the microphone's offset, in sample counts }
    markDb10, endDb10: Integer;         { marker levels, dB x 10 re full scale }
    noiseRms10: Integer;                { background, dB x 10 re full scale (broadband, offset removed) }
    toneDb10: array[0..NTONE - 1] of Integer;     { level of each steady tone (median over the tone), dBFS x 10 }
    noiseDb10: array[0..NTONE - 1] of Integer;    { background at each tone's frequency, measured the same way }
    fall10: array[0..NTONE - 1] of Integer;       { level at 50-100 ms minus level at 300-350 ms: how much it fell, dB x 10 }
    ghostLo10, ghostHi10, harm10: array[0..NTONE - 1] of Integer;   { 900 Hz below, 900 Hz above, 2nd harmonic: dB x 10 relative to the tone, -9990 = not looked at }
    linEarly10, linLate10: array[0..NLINF - 1, 0..NLINA - 1] of Integer;   { level 20-120 ms and 400-600 ms into the tone, dBFS x 10 }
    envDb10: array[0..NAGC - 1, 0..NENV - 1] of Integer;   { level curve relative to the first 20 ms }
    envBack10: array[0..NAGC - 1] of Integer;     { second tone, first 20 ms, relative to the first tone's }
    envAbs10: array[0..NAGC - 1] of Integer;      { first tone's first 20 ms, dBFS x 10 }
    burstDb10: array[0..NBSET - 1, 0..NBURST - 1] of Integer;   { average peak of the bursts relative to the steady tone at that frequency }
    burstSeen: array[0..NBSET - 1, 0..NBURST - 1] of Integer;   { how many of the BURST_N bursts stood out }
    { the verdict }
    passDb10: Integer;                  { median level of the tones from 1 to 8 kHz }
    cliffHz: Integer;                   { first tone above 8 kHz that is 20 dB under that, 0 = none }
    strongTopHz: Integer;               { top of the unbroken run of tones 40 dB over the background, from the lowest }
    marginalTopHz: Integer;             { highest tone 20 dB over the background }
    slope100: array[0..NLINF - 1] of Integer;     { output change per input change, percent: 100 = follows, 0 = constant }
  end;

function ToneHz(i: Integer): Integer;
function ToneIndex(hz: Integer): Integer;
procedure Analyse(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TScanResult);
{ the same, as lines of text for the screen and for sending to the phone }
const MAXLINES = 100;
type TLines = record n: Integer; s: array[0..MAXLINES - 1] of string[110]; end;
procedure BuildReport(const r: TScanResult; var L: TLines);
{ a short version (about 1,300 characters) to type to the phone }
procedure BuildCompact(const r: TScanResult; var L: TLines);
function Following(const r: TScanResult): Boolean;   { true when the output level follows the input (no strong automatic gain) }

implementation

function ToneHz(i: Integer): Integer;
begin
  if i < 19 then Result := 500 * (i + 1)
  else if i < 38 then Result := 10000 + (i - 19) * 250
  else Result := 15000 + (i - 38) * 500;
end;

function ToneIndex(hz: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to NTONE - 1 do if ToneHz(i) <= hz then Result := i;
end;

{ ---------- measuring ---------- }

var DcI: LongInt = 0;

{ amplitude (in sample counts) of the sine at hz in x[start .. start+len), with the real rate rate100 / 100, the
  microphone's offset taken away. Goertzel with whole numbers: the coefficient is 14 bits, the sums are 64 bits. }
function Amp(x: PSamples; start, len: LongInt; hz: Integer; rate100: LongInt): Double;
var w: Double; c: Int64; s0, s1, s2, p: Int64; i: LongInt;
begin
  Result := 0;
  if len < 8 then Exit;
  w := 2 * Pi * hz * 100 / rate100;
  if w >= Pi then Exit;                       { above half the rate: not seen }
  c := Round(2 * Cos(w) * 16384);
  s1 := 0; s2 := 0;
  for i := start to start + len - 1 do
  begin
    s0 := (x^[i] - DcI) + ((c * s1) div 16384) - s2;     { div, not shr: the sign must stay }
    s2 := s1; s1 := s0;
  end;
  p := s1 * s1 + s2 * s2 - ((c * s1) div 16384) * s2;
  if p <= 0 then Exit;
  Result := 2 * Sqrt(p) / len;
end;

function Db10(a: Double): Integer;
begin
  if a < 0.0001 then begin Result := -9990; Exit; end;
  Result := Round(200 * Ln(a / 32768) / Ln(10));
end;

function ToSample(const r: TScanResult; ms: LongInt): LongInt; inline;
begin
  Result := r.t0 + Round(Int64(ms) * r.rate100 / 100000);
end;

{ the start of a marker: the first 5 ms block, from a to b, in which 4 kHz is clearly there }
function FindMarker(x: PSamples; a, b: LongInt; nominal: LongInt): LongInt;
const NR = 4;
var rates: array[0..NR - 1] of LongInt; blk: LongInt; i, k, nb, nsub: LongInt; lvl: array of Double; mx, md, thr, v: Double;
    tmp: array of Double;
begin
  Result := -1;
  rates[0] := nominal * 100; rates[1] := 43230 * 100; rates[2] := 42000 * 100; rates[3] := 44100 * 100;
  blk := nominal div 200;                     { 5 ms }
  if b - a < blk * 8 then Exit;
  nb := (b - a) div blk;
  SetLength(lvl, nb);
  for i := 0 to nb - 1 do
  begin
    mx := 0;
    for k := 0 to NR - 1 do
    begin
      v := Amp(x, a + i * blk, blk, MARK_HZ, rates[k]);
      if v > mx then mx := v;
    end;
    lvl[i] := mx;
  end;
  mx := 0;
  for i := 0 to nb - 1 do if lvl[i] > mx then mx := lvl[i];
  { the background: the lower tenth of every 16th block }
  nsub := nb div 16;
  if nsub < 8 then Exit;
  SetLength(tmp, nsub);
  for i := 0 to nsub - 1 do tmp[i] := lvl[i * 16];
  for i := 1 to nsub - 1 do begin v := tmp[i]; k := i - 1; while (k >= 0) and (tmp[k] > v) do begin tmp[k + 1] := tmp[k]; Dec(k); end; tmp[k + 1] := v; end;
  md := tmp[nsub div 10];
  thr := mx * 0.3;
  if thr < md * 12 then thr := md * 12;
  if mx < md * 12 then Exit;                  { nothing stands out }
  for i := 0 to nb - 1 do
    if lvl[i] >= thr then
    begin
      { and it must go on for 60 ms: not a click }
      k := 0;
      while (i + k < nb) and (lvl[i + k] >= thr * 0.5) do Inc(k);
      if k >= 12 then begin Result := a + i * blk; Exit; end;
    end;
end;

procedure SortInt(var a: array of Integer; n: Integer);
var i, j, t: Integer;
begin
  for i := 1 to n - 1 do
  begin
    t := a[i]; j := i - 1;
    while (j >= 0) and (a[j] > t) do begin a[j + 1] := a[j]; Dec(j); end;
    a[j + 1] := t;
  end;
end;

function Median(var a: array of Integer; n: Integer): Integer;
begin
  if n <= 0 then begin Result := -9990; Exit; end;
  SortInt(a, n);
  Result := a[n div 2];
end;

{ the background at a frequency, in windows of wl samples over the silence: mean power }
function NoiseAt(x: PSamples; bs, wl: LongInt; count: Integer; hz: Integer; rate100: LongInt): Double;
var k: Integer; a, sq: Double;
begin
  sq := 0;
  for k := 0 to count - 1 do
  begin
    a := Amp(x, bs + LongInt(k) * wl, wl, hz, rate100);
    sq := sq + a * a;
  end;
  Result := Sqrt(sq / count);
end;

procedure Analyse(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TScanResult);
var i, k, w, g, f, j, nw, a2: Integer; s0, s1, bs, be, st, wl: LongInt; hz: Integer; v: array[0..15] of Integer; a: Double;
    ref, hiRef: Integer; nz, sq, sum: Double; pk, e0, e: Double; seen, sub, sm: Integer; steady: Double; cnt: Integer;
    pass: array[0..15] of Integer; np: Integer; run: Boolean; in1, out1: Double; lo, hi: Integer;
begin
  FillChar(r, SizeOf(r), 0);
  r.n := n;
  DcI := 0;
  r.rate100 := nominalRate * 100;
  if n < nominalRate * 20 then begin r.err := 'The recording is too short (under 20 seconds).'; Exit; end;
  r.t0 := FindMarker(x, 0, n - nominalRate * 20, nominalRate);
  if r.t0 < 0 then begin r.err := 'The first marker (4 kHz beep) was not heard. Move the phone closer and turn it up.'; Exit; end;
  { the second marker, 75.5 s later: look for it between 74 and 80 s (nominal) }
  s0 := r.t0 + nominalRate * 74; s1 := r.t0 + nominalRate * 80;
  if s1 > n then s1 := n;
  r.t1 := -1;
  if s1 - s0 > nominalRate then r.t1 := FindMarker(x, s0, s1, nominalRate);
  if r.t1 < 0 then begin r.err := 'The end marker was not heard: record for 85 seconds and let the phone finish.'; Exit; end;
  r.rate100 := Round((r.t1 - r.t0) / (END_AT / 1000.0) * 100);
  if (r.rate100 < nominalRate * 100 * 90 div 100) or (r.rate100 > nominalRate * 100 * 110 div 100) then
  begin r.err := 'The markers are not 75 seconds apart: something went wrong in the recording.'; Exit; end;

  { the microphone's offset and the background, from the silence after the first marker }
  bs := ToSample(r, NOISE_FROM); be := ToSample(r, NOISE_TO);
  sum := 0;
  for i := bs to be - 1 do sum := sum + x^[i];
  r.dc := Round(sum / (be - bs));
  DcI := r.dc;
  sq := 0;
  for i := bs to be - 1 do sq := sq + Double(x^[i] - DcI) * (x^[i] - DcI);
  r.noiseRms10 := Db10(Sqrt(sq / (be - bs)) * 1.41421356);

  r.markDb10 := Db10(Amp(x, ToSample(r, 50), ToSample(r, MARK_MS - 50) - ToSample(r, 50), MARK_HZ, r.rate100));
  r.endDb10 := Db10(Amp(x, ToSample(r, END_AT + 50), ToSample(r, END_AT + MARK_MS - 50) - ToSample(r, END_AT + 50), MARK_HZ, r.rate100));

  { the steady tones }
  wl := ToSample(r, 50) - ToSample(r, 0);                              { 50 ms }
  for i := 0 to NTONE - 1 do
  begin
    hz := ToneHz(i);
    st := TONE_AT0 + i * TONE_PERIOD;
    r.noiseDb10[i] := Db10(NoiseAt(x, bs, wl, 24, hz, r.rate100));
    nw := 0;
    for w := 2 to 6 do                                                  { 50 ms windows from 100 to 350 ms }
    begin
      v[nw] := Db10(Amp(x, ToSample(r, st + w * 50), wl, hz, r.rate100)); Inc(nw);
    end;
    ref := Db10(Amp(x, ToSample(r, st + 50), wl, hz, r.rate100));      { 50-100 ms }
    r.toneDb10[i] := Median(v, nw);
    r.fall10[i] := ref - Db10(Amp(x, ToSample(r, st + 300), wl, hz, r.rate100));
    for k := 0 to 2 do
    begin
      case k of
        0: g := hz - 900;
        1: g := hz + 900;
      else g := hz * 2;
      end;
      j := -9990;
      if (g > 100) and (Int64(g) * 200 < Int64(r.rate100) div 100 * 100 div 100 * 100 div 100) then j := -9990;
      if (g > 100) and (Int64(g) * 2 * 100 < Int64(r.rate100)) then
        j := Db10(Amp(x, ToSample(r, st + 100), ToSample(r, st + 350) - ToSample(r, st + 100), g, r.rate100)) - r.toneDb10[i];
      case k of 0: r.ghostLo10[i] := j; 1: r.ghostHi10[i] := j; else r.harm10[i] := j; end;
    end;
  end;

  { does the level follow the sound? }
  for f := 0 to NLINF - 1 do
  begin
    for g := 0 to NLINA - 1 do
    begin
      st := LIN_AT0 + (f * NLINA + g) * LIN_PERIOD;
      r.linEarly10[f, g] := Db10(Amp(x, ToSample(r, st + 20), ToSample(r, st + 120) - ToSample(r, st + 20), LIN_HZ[f], r.rate100));
      r.linLate10[f, g] := Db10(Amp(x, ToSample(r, st + 400), ToSample(r, st + 600) - ToSample(r, st + 400), LIN_HZ[f], r.rate100));
    end;
    { 200 * log10(90/6) = 23.5 dB of input; the output change over the same }
    in1 := 200 * Ln(LIN_AMP[0] / LIN_AMP[NLINA - 1]) / Ln(10);
    out1 := r.linLate10[f, 0] - r.linLate10[f, NLINA - 1];
    r.slope100[f] := Round(out1 / in1 * 100);
  end;

  { gain tests }
  for g := 0 to NAGC - 1 do
  begin
    hz := AGC_HZ[g];
    st := AGC_AT0 + g * AGC_PERIOD;
    wl := ToSample(r, 20) - ToSample(r, 0);
    e0 := Amp(x, ToSample(r, st), wl, hz, r.rate100);
    r.envAbs10[g] := Db10(e0);
    for k := 0 to NENV - 1 do
      r.envDb10[g, k] := Db10(Amp(x, ToSample(r, st + ENV_AT[k]), wl, hz, r.rate100)) - Db10(e0);
    e := Amp(x, ToSample(r, st + AGC_TONE_MS + AGC_GAP_MS), wl, hz, r.rate100);
    r.envBack10[g] := Db10(e) - Db10(e0);
  end;

  { short bursts }
  for sm := 0 to NBSET - 1 do
  begin
    hz := BURST_HZ[sm];
    i := ToneIndex(hz);
    steady := Amp(x, ToSample(r, TONE_AT0 + i * TONE_PERIOD + 100), ToSample(r, TONE_AT0 + i * TONE_PERIOD + 350) - ToSample(r, TONE_AT0 + i * TONE_PERIOD + 100), hz, r.rate100);
    wl := ToSample(r, 5) - ToSample(r, 0);
    nz := NoiseAt(x, bs, wl, 24, hz, r.rate100);
    st := BURST_AT[sm];
    for g := 0 to NBURST - 1 do
    begin
      cnt := 0; seen := 0;
      sum := 0;
      for k := 0 to BURST_N - 1 do
      begin
        pk := 0;
        sub := BURST_MS[g] div 5 + 2;
        for j := -1 to sub - 2 do
        begin
          a := Amp(x, ToSample(r, st + j * 5), wl, hz, r.rate100);
          if a > pk then pk := a;
        end;
        sum := sum + Db10(pk);
        Inc(cnt);
        if pk > nz * 3.2 then Inc(seen);                           { 10 dB above the background }
        st := st + BURST_MS[g] + BURST_GAP;
      end;
      r.burstDb10[sm, g] := Round(sum / cnt) - Db10(steady);
      r.burstSeen[sm, g] := seen;
    end;
  end;

  { the verdict: where the response is, where it ends }
  np := 0;
  for i := 0 to NTONE - 1 do if (ToneHz(i) >= 1000) and (ToneHz(i) <= 8000) and (np < 16) then begin pass[np] := r.toneDb10[i]; Inc(np); end;
  r.passDb10 := Median(pass, np);
  r.cliffHz := 0;
  for i := 0 to NTONE - 1 do
    if (ToneHz(i) > 8000) and (r.toneDb10[i] < r.passDb10 - 200) then begin r.cliffHz := ToneHz(i); Break; end;
  r.strongTopHz := 0; run := True;
  for i := 0 to NTONE - 1 do
  begin
    if r.toneDb10[i] - r.noiseDb10[i] >= 400 then begin if run then r.strongTopHz := ToneHz(i); end else run := False;
  end;
  r.marginalTopHz := 0;
  for i := NTONE - 1 downto 0 do if r.toneDb10[i] - r.noiseDb10[i] >= 200 then begin r.marginalTopHz := ToneHz(i); Break; end;
  r.ok := True;
end;

{ ---------- text ---------- }

function Following(const r: TScanResult): Boolean;
var f, c, m: Integer;
begin
  c := 0; m := 0;
  for f := 0 to NLINF - 1 do
  begin
    if r.linLate10[f, 0] - r.noiseDb10[ToneIndex(LIN_HZ[f])] >= 300 then       { only where the loudest was well over the background }
    begin Inc(c); if r.slope100[f] >= 60 then Inc(m); end;
  end;
  Result := (c = 0) or (m * 2 > c);
end;

function D1(v: Integer): string;           { dB x 10 as "-12.3" }
var s: string[12];
begin
  if v <= -9000 then begin D1 := '  - '; Exit; end;
  Str(Abs(v) div 10, s);
  if v < 0 then s := '-' + s;
  D1 := s + '.' + Chr(48 + Abs(v) mod 10);
end;

function N0(v: LongInt): string;
var s: string[16];
begin
  Str(v, s); N0 := s;
end;

function KHz1(hz: Integer): string;
var q: Integer;
begin
  q := (hz mod 1000) div 10;                 { hundredths of a kHz }
  if q mod 10 = 0 then KHz1 := N0(hz div 1000) + '.' + N0(q div 10)
  else if q < 10 then KHz1 := N0(hz div 1000) + '.0' + N0(q)
  else KHz1 := N0(hz div 1000) + '.' + N0(q);
end;

procedure Put(var L: TLines; const s: string);
begin
  if L.n < MAXLINES then begin L.s[L.n] := s; Inc(L.n); end;
end;

procedure Verdict(const r: TScanResult; var L: TLines);
var f: Integer; s: string;
begin
  if r.cliffHz > 0 then Put(L, 'The response ends near ' + KHz1(r.cliffHz) + ' kHz: from there the level is 20 dB under the 1-8 kHz level (' + D1(r.passDb10) + ' dBFS).')
  else Put(L, 'No sharp end of the response up to 21.5 kHz.');
  Put(L, 'Strong (40 dB over the background) from 0.5 up to ' + KHz1(r.strongTopHz) + ' kHz. Anything at all (20 dB over) up to ' + KHz1(r.marginalTopHz) + ' kHz.');
  if Following(r) then Put(L, 'The recorded level follows the sound: no strong automatic gain.')
  else
  begin
    s := 'Automatic gain: a 23 dB change in the sound changes the recording by only';
    for f := 0 to NLINF - 1 do s := s + ' ' + D1(r.slope100[f] * 235 div 100) + ' dB (' + KHz1(LIN_HZ[f]) + 'k)';
    Put(L, s);
  end;
end;

procedure BuildReport(const r: TScanResult; var L: TLines);
var i, g, k, f, sm: Integer; s: string;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'MIC SCAN failed'); Put(L, r.err); Exit; end;
  Put(L, 'MIC SCAN, handheld microphone report');
  Put(L, 'Real sampling rate: ' + N0(r.rate100 div 100) + '.' + N0((r.rate100 mod 100) div 10) + ' Hz (it says 44100). Offset ' + N0(r.dc) + ' counts, removed.');
  Put(L, 'Markers 4 kHz: ' + D1(r.markDb10) + ' and ' + D1(r.endDb10) + ' dBFS. Background: ' + D1(r.noiseRms10) + ' dBFS');
  Verdict(r, L);
  Put(L, 'RESPONSE kHz: level dBFS | over background | fall 0.25 s | ghosts -0.9, +0.9 kHz | 2nd harmonic');
  for i := 0 to NTONE - 1 do
    Put(L, KHz1(ToneHz(i)) + ': ' + D1(r.toneDb10[i]) + ' | ' + D1(r.toneDb10[i] - r.noiseDb10[i]) + ' | ' + D1(r.fall10[i])
        + ' | ' + D1(r.ghostLo10[i]) + ' ' + D1(r.ghostHi10[i]) + ' | ' + D1(r.harm10[i]));
  Put(L, 'DOES THE LEVEL FOLLOW? sound 90, 45, 22, 11, 6 %: recorded dBFS early (20-120 ms) / late (400-600 ms)');
  for f := 0 to NLINF - 1 do
  begin
    s := KHz1(LIN_HZ[f]) + ' kHz: ';
    for g := 0 to NLINA - 1 do s := s + D1(r.linEarly10[f, g]) + '/' + D1(r.linLate10[f, g]) + '  ';
    Put(L, s);
  end;
  Put(L, 'GAIN: level while a tone goes on (dB re its first 20 ms) at 0, 20, 50, 100, 200, 400, 800, 1400 ms | after a pause');
  for g := 0 to NAGC - 1 do
  begin
    s := KHz1(AGC_HZ[g]) + ' kHz ' + N0(AGC_AMP[g]) + '% (' + D1(r.envAbs10[g]) + ' dBFS): ';
    for k := 0 to NENV - 1 do s := s + D1(r.envDb10[g, k]) + ' ';
    Put(L, s + '| ' + D1(r.envBack10[g]));
  end;
  Put(L, 'SHORT BURSTS: length, level against a steady tone, seen of ' + N0(BURST_N));
  for sm := 0 to NBSET - 1 do
  begin
    s := KHz1(BURST_HZ[sm]) + ' kHz: ';
    for g := 0 to NBURST - 1 do s := s + N0(BURST_MS[g]) + 'ms ' + D1(r.burstDb10[sm, g]) + 'dB ' + N0(r.burstSeen[sm, g]) + '/' + N0(BURST_N) + '  ';
    Put(L, s);
  end;
end;

procedure BuildCompact(const r: TScanResult; var L: TLines);
var i, g, k, f, nl, med, sm: Integer; s: string; t: array[0..NTONE - 1] of Integer;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'MIC SCAN failed: ' + r.err); Exit; end;
  Put(L, 'MIC SCAN');
  Put(L, 'Real rate ' + N0(r.rate100 div 100) + ' Hz (claims 44100). Offset ' + N0(r.dc) + '. Markers ' + D1(r.markDb10) + ' / ' + D1(r.endDb10) + ' dBFS. Background ' + D1(r.noiseRms10) + ' dBFS');
  Verdict(r, L);
  Put(L, 'Tones kHz:level dBFS/over background dB/fall dB');
  s := '';
  for i := 0 to NTONE - 1 do
    if (ToneHz(i) mod 1000 = 0) or ((ToneHz(i) >= 10000) and (ToneHz(i) <= 14500) and (ToneHz(i) mod 500 = 0)) or (ToneHz(i) = 14250) then
    begin
      s := s + KHz1(ToneHz(i)) + ':' + D1(r.toneDb10[i]) + '/' + D1(r.toneDb10[i] - r.noiseDb10[i]) + '/' + D1(r.fall10[i]) + '  ';
      if Length(s) > 80 then begin Put(L, s); s := ''; end;
    end;
  if s <> '' then Put(L, s);
  nl := 0;
  for i := 4 to NTONE - 1 do if (r.toneDb10[i] - r.noiseDb10[i] > 150) and (r.ghostLo10[i] > -9000) then begin t[nl] := r.ghostLo10[i]; Inc(nl); end;
  if nl > 0 then begin
    for i := 1 to nl - 1 do begin k := t[i]; g := i - 1; while (g >= 0) and (t[g] > k) do begin t[g + 1] := t[g]; Dec(g); end; t[g + 1] := k; end;
    med := t[nl div 2];
    Put(L, 'Ghost 0.9 kHz below a tone: median ' + D1(med) + ' dB');
  end;
  Put(L, 'Level vs sound (90,45,22,11,6 %), late dBFS');
  for f := 0 to NLINF - 1 do
  begin
    s := KHz1(LIN_HZ[f]) + 'k: ';
    for g := 0 to NLINA - 1 do s := s + D1(r.linLate10[f, g]) + ' ';
    Put(L, s);
  end;
  Put(L, 'Gain curve dB at 0,20,50,100,200,400,800,1400 ms | pause');
  for g := 0 to NAGC - 1 do
  begin
    s := KHz1(AGC_HZ[g]) + 'k ' + N0(AGC_AMP[g]) + '%: ';
    for k := 0 to NENV - 1 do s := s + D1(r.envDb10[g, k]) + ' ';
    Put(L, s + '| ' + D1(r.envBack10[g]));
  end;
  for sm := 0 to NBSET - 1 do
  begin
    s := 'Bursts ' + KHz1(BURST_HZ[sm]) + 'k seen of 6: ';
    for g := 0 to NBURST - 1 do s := s + N0(BURST_MS[g]) + 'ms ' + N0(r.burstSeen[sm, g]) + '  ';
    Put(L, s);
  end;
end;

end.
