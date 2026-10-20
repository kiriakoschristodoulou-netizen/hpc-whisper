unit scanlib;
{ Mic Scan: what the test signal is, and how a recording of it is measured.

  The phone page (scan.html) plays a fixed 60-second test signal; the handheld
  records it through its microphone and measures it here, with integer
  arithmetic (the handheld has no floating point unit), to learn how the
  microphone really hears sound: which frequencies, how loud, how the level
  changes while a tone goes on (automatic gain), the handheld's real sampling
  rate, ghost tones, and how short a burst it still notices.

  The plan below is the same in scan.html. }
{$mode objfpc}{$H+}
interface

const
  { the test signal, in milliseconds from the start of the first marker }
  MARK_HZ = 4000;
  MARK_MS = 600;
  END_AT = 60000;                       { the second marker starts here }
  PLAN_MS = 60600;
  NOISE_FROM = 900; NOISE_TO = 1900;    { silence, to measure the background }

  NTONE = 43;                           { steady tones for the frequency response: 500, 1000 ... 21500 Hz }
  TONE_HZ0 = 500; TONE_STEP = 500;
  TONE_AT0 = 2000; TONE_PERIOD = 600; TONE_MS = 450;

  NAGC = 4;                             { gain tests: a tone, a silence, the tone again }
  AGC_AT0 = 28500; AGC_PERIOD = 6400; AGC_TONE_MS = 2000; AGC_GAP_MS = 1200;
  AGC_HZ: array[0..NAGC - 1] of Integer = (3000, 19000, 3000, 19000);
  AGC_AMP: array[0..NAGC - 1] of Integer = (90, 90, 22, 22);        { percent of full scale }
  NENV = 6;                             { the points of the level curve kept: 50 ms windows }
  ENV_WIN: array[0..NENV - 1] of Integer = (0, 1, 4, 9, 19, 38);

  NBURST = 4; BURST_N = 6;              { bursts at 19.5 kHz of these lengths }
  BURST_AT0 = 54600; BURST_HZ = 19500;
  BURST_MS: array[0..NBURST - 1] of Integer = (20, 40, 60, 100);
  BURST_GAP = 150;

  NGH = 3;                              { other places looked at while a tone plays }
  TONE_AMP = 50;                        { percent of full scale }

type
  TSamples = array[0..MaxInt div 4] of SmallInt;
  PSamples = ^TSamples;

  TScanResult = record
    ok: Boolean;
    err: string[100];
    n: LongInt;                         { samples in the recording }
    rate100: LongInt;                   { the real sampling rate x 100 (samples per real second) }
    t0, t1: LongInt;                    { sample where each marker starts }
    markDb10, endDb10: Integer;         { marker levels, dB x 10 re full scale }
    noiseRms10: Integer;                { background, dB x 10 re full scale (broadband) }
    toneDb10: array[0..NTONE - 1] of Integer;     { level of each steady tone (median over the tone), dBFS x 10 }
    noiseDb10: array[0..NTONE - 1] of Integer;    { background at each tone's frequency }
    fall10: array[0..NTONE - 1] of Integer;       { level at 50-100 ms minus level at 350-450 ms: how much it fell, dB x 10 }
    ghostLo10, ghostHi10, harm10: array[0..NTONE - 1] of Integer;   { 900 Hz below, 900 Hz above, 2nd harmonic: dB x 10 relative to the tone, -9990 = not looked at }
    envDb10: array[0..NAGC - 1, 0..NENV - 1] of Integer;   { level curve relative to the first 150 ms, dB x 10 }
    envBack10: array[0..NAGC - 1] of Integer;     { second tone, first 150 ms, relative to the first tone's }
    envAbs10: array[0..NAGC - 1] of Integer;      { first tone's first 150 ms, dBFS x 10 }
    burstDb10: array[0..NBURST - 1] of Integer;   { average peak of the bursts relative to the steady tone at that frequency }
    burstSeen: array[0..NBURST - 1] of Integer;   { how many of the BURST_N bursts stood out }
  end;

function ToneHz(i: Integer): Integer;
procedure Analyse(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TScanResult);
{ the same, as lines of text for the screen and for sending to the phone }
const MAXLINES = 80;
type TLines = record n: Integer; s: array[0..MAXLINES - 1] of string[100]; end;
procedure BuildReport(const r: TScanResult; var L: TLines);
{ a short version (about 1,000 characters) to type to the phone }
procedure BuildCompact(const r: TScanResult; var L: TLines);
function UsableLowHz(const r: TScanResult): Integer;
function UsableHighHz(const r: TScanResult): Integer;

implementation

function ToneHz(i: Integer): Integer;
begin
  Result := TONE_HZ0 + i * TONE_STEP;
end;

{ ---------- measuring ---------- }

{ amplitude (in sample counts) of the sine at hz in x[start .. start+len), with the real rate rate100 / 100.
  Goertzel with whole numbers: the coefficient is 14 bits, the sums are 64 bits. }
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
    s0 := x^[i] + ((c * s1) div 16384) - s2;     { div, not shr: the sign must stay }
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

{ the start of a marker: the first 5 ms block, from a to b, in which 4 kHz is clearly there }
function FindMarker(x: PSamples; a, b: LongInt; nominal: LongInt; first: Boolean): LongInt;
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
  if first then Result := -1;
end;

function Median(var a: array of Integer; n: Integer): Integer;
begin
  if n <= 0 then begin Result := -9990; Exit; end;
  SortInt(a, n);
  Result := a[n div 2];
end;

procedure Analyse(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TScanResult);
var i, k, w, g, j, nw: Integer; s0, s1, ws: LongInt; hz: Integer; v: array[0..15] of Integer; a: Double;
    ref, big: Integer; p100: Int64; e, e0: Double; bs, be: LongInt; sum, cnt, seen: Integer; st: LongInt; pk: Double; sub: Integer;
    steady: Double; noiseA: Double; sq: Double; wl: LongInt;
begin
  FillChar(r, SizeOf(r), 0);
  r.n := n;
  r.rate100 := nominalRate * 100;
  if n < nominalRate * 20 then begin r.err := 'The recording is too short (under 20 seconds).'; Exit; end;
  r.t0 := FindMarker(x, 0, n - nominalRate * 20, nominalRate, True);
  if r.t0 < 0 then begin r.err := 'The first marker (4 kHz beep) was not heard. Move the phone closer and turn it up.'; Exit; end;
  { the second marker, 60 s later: look for it between 58 and 64 s (nominal) }
  s0 := r.t0 + nominalRate * 58; s1 := r.t0 + nominalRate * 64;
  if s1 > n then s1 := n;
  r.t1 := -1;
  if s1 - s0 > nominalRate then r.t1 := FindMarker(x, s0, s1, nominalRate, False);
  if r.t1 < 0 then begin r.err := 'The end marker was not heard: record for 65 seconds and let the phone finish.'; Exit; end;
  r.rate100 := Round((r.t1 - r.t0) / (END_AT / 1000.0) * 100);
  if (r.rate100 < nominalRate * 100 * 90 div 100) or (r.rate100 > nominalRate * 100 * 110 div 100) then
  begin r.err := 'The markers are not 60 seconds apart: something went wrong in the recording.'; Exit; end;

  r.markDb10 := Db10(Amp(x, ToSample(r, 50), ToSample(r, MARK_MS - 50) - ToSample(r, 50), MARK_HZ, r.rate100));
  r.endDb10 := Db10(Amp(x, ToSample(r, END_AT + 50), ToSample(r, END_AT + MARK_MS - 50) - ToSample(r, END_AT + 50), MARK_HZ, r.rate100));

  { background: broadband rms in the silence after the first marker }
  bs := ToSample(r, NOISE_FROM); be := ToSample(r, NOISE_TO);
  sq := 0;
  for i := bs to be - 1 do sq := sq + Double(x^[i]) * x^[i];
  r.noiseRms10 := Db10(Sqrt(sq / (be - bs)) * 1.41421356);

  { the steady tones }
  for i := 0 to NTONE - 1 do
  begin
    hz := ToneHz(i);
    st := TONE_AT0 + i * TONE_PERIOD;
    wl := ToSample(r, st + 50) - ToSample(r, st);                      { 50 ms }
    { background at this frequency, from the silence }
    { the background at this frequency, measured the way a tone is: mean power over 50 ms windows of the silence }
    sq := 0; cnt := 0;
    for k := 0 to 19 do
    begin
      a := Amp(x, bs + LongInt(k) * wl, wl, hz, r.rate100);
      sq := sq + a * a; Inc(cnt);
    end;
    r.noiseDb10[i] := Db10(Sqrt(sq / cnt));
    nw := 0;
    for w := 1 to 8 do                                                  { 50 ms windows from 50 to 450 ms }
    begin
      if w < 2 then Continue;
      v[nw] := Db10(Amp(x, ToSample(r, st + w * 50), wl, hz, r.rate100)); Inc(nw);
    end;
    ref := Db10(Amp(x, ToSample(r, st + 50), wl, hz, r.rate100));      { 50-100 ms }
    r.toneDb10[i] := Median(v, nw);
    r.fall10[i] := ref - Db10(Amp(x, ToSample(r, st + 350), wl, hz, r.rate100));
    { ghosts and harmonics, measured over the same 100-450 ms }
    big := 0;
    for k := 0 to 2 do
    begin
      case k of
        0: g := hz - 900;
        1: g := hz + 900;
      else g := hz * 2;
      end;
      j := -9990;
      if (g > 100) and (Int64(g) * 200 * 100 < Int64(r.rate100) * 100) then
        j := Db10(Amp(x, ToSample(r, st + 100), ToSample(r, st + 450) - ToSample(r, st + 100), g, r.rate100)) - r.toneDb10[i];
      case k of 0: r.ghostLo10[i] := j; 1: r.ghostHi10[i] := j; else r.harm10[i] := j; end;
    end;
  end;

  { gain tests }
  for g := 0 to NAGC - 1 do
  begin
    hz := AGC_HZ[g];
    st := AGC_AT0 + g * AGC_PERIOD;
    wl := ToSample(r, st + 50) - ToSample(r, st);
    e0 := 0;
    for k := 0 to 2 do begin a := Amp(x, ToSample(r, st + k * 50), wl, hz, r.rate100); if a > e0 then e0 := a; end;
    r.envAbs10[g] := Db10(e0);
    for k := 0 to NENV - 1 do
      r.envDb10[g, k] := Db10(Amp(x, ToSample(r, st + ENV_WIN[k] * 50), wl, hz, r.rate100)) - Db10(e0);
    st := st + AGC_TONE_MS + AGC_GAP_MS;
    e := 0;
    for k := 0 to 2 do begin a := Amp(x, ToSample(r, st + k * 50), wl, hz, r.rate100); if a > e then e := a; end;
    r.envBack10[g] := Db10(e) - Db10(e0);
  end;

  { short bursts at 19.5 kHz }
  steady := Amp(x, ToSample(r, TONE_AT0 + 38 * TONE_PERIOD + 100), ToSample(r, TONE_AT0 + 38 * TONE_PERIOD + 450) - ToSample(r, TONE_AT0 + 38 * TONE_PERIOD + 100), BURST_HZ, r.rate100);
  wl := ToSample(r, 5) - ToSample(r, 0);
  sq := 0;
  for k := 0 to 19 do begin a := Amp(x, bs + LongInt(k) * wl, wl, BURST_HZ, r.rate100); sq := sq + a * a; end;
  noiseA := Sqrt(sq / 20);
  st := BURST_AT0;
  for g := 0 to NBURST - 1 do
  begin
    sum := 0; seen := 0;
    for k := 0 to BURST_N - 1 do
    begin
      { the strongest 5 ms inside the burst's slot }
      pk := 0;
      sub := BURST_MS[g] div 5;
      if sub < 1 then sub := 1;
      for j := 0 to sub - 1 do
      begin
        a := Amp(x, ToSample(r, st + j * 5), ToSample(r, st + j * 5 + 5) - ToSample(r, st + j * 5), BURST_HZ, r.rate100);
        if a > pk then pk := a;
      end;
      sum := sum + Db10(pk);
      if pk > noiseA * 3.2 then Inc(seen);                          { 10 dB above the background }
      st := st + BURST_MS[g] + BURST_GAP;
    end;
    r.burstDb10[g] := sum div BURST_N - Db10(steady);
    r.burstSeen[g] := seen;
  end;
  r.ok := True;
end;

{ ---------- the verdict ---------- }

{ the range where a tone stands at least 20 dB above the background, and does not fall away by more than 15 dB }
function UsableLowHz(const r: TScanResult): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to NTONE - 1 do
    if (r.toneDb10[i] - r.noiseDb10[i] >= 200) and (r.fall10[i] <= 150) then begin Result := ToneHz(i); Exit; end;
end;

function UsableHighHz(const r: TScanResult): Integer;
var i: Integer;
begin
  Result := 0;
  for i := NTONE - 1 downto 0 do
    if (r.toneDb10[i] - r.noiseDb10[i] >= 200) and (r.fall10[i] <= 150) then begin Result := ToneHz(i); Exit; end;
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
begin
  KHz1 := N0(hz div 1000) + '.' + N0((hz mod 1000) div 100);
end;

procedure Put(var L: TLines; const s: string);
begin
  if L.n < MAXLINES then begin L.s[L.n] := s; Inc(L.n); end;
end;

procedure BuildReport(const r: TScanResult; var L: TLines);
var i, g, lo, hi, best, bi, k, worst: Integer; s: string;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'MIC SCAN failed'); Put(L, r.err); Exit; end;
  Put(L, 'MIC SCAN, handheld microphone report');
  Put(L, 'Real sampling rate: ' + N0(r.rate100 div 100) + '.' + N0((r.rate100 mod 100) div 10) + ' Hz (it says 44100)');
  Put(L, 'Markers 4 kHz: ' + D1(r.markDb10) + ' and ' + D1(r.endDb10) + ' dBFS. Background: ' + D1(r.noiseRms10) + ' dBFS');
  lo := UsableLowHz(r); hi := UsableHighHz(r);
  if lo = 0 then Put(L, 'No tone was heard 20 dB above the background and steady.')
  else Put(L, 'Usable range (20 dB over background, level steady): ' + KHz1(lo) + ' to ' + KHz1(hi) + ' kHz');
  best := -9990; bi := 0;
  for i := 0 to NTONE - 1 do if r.toneDb10[i] - r.noiseDb10[i] > best then begin best := r.toneDb10[i] - r.noiseDb10[i]; bi := i; end;
  Put(L, 'Best: ' + KHz1(ToneHz(bi)) + ' kHz, ' + D1(best) + ' dB over background');
  Put(L, 'RESPONSE kHz: level dBFS | over background | fall 0.4 s | ghosts -0.9, +0.9 kHz | 2nd harmonic');
  for i := 0 to NTONE - 1 do
    Put(L, KHz1(ToneHz(i)) + ': ' + D1(r.toneDb10[i]) + ' | ' + D1(r.toneDb10[i] - r.noiseDb10[i]) + ' | ' + D1(r.fall10[i])
        + ' | ' + D1(r.ghostLo10[i]) + ' ' + D1(r.ghostHi10[i]) + ' | ' + D1(r.harm10[i]));
  Put(L, 'LEVEL WHILE A TONE GOES ON (dB, from the first 0.15 s): at 0.05, 0.1, 0.25, 0.5, 1, 1.9 s; after a pause');
  for g := 0 to NAGC - 1 do
  begin
    s := KHz1(AGC_HZ[g]) + ' kHz at ' + N0(AGC_AMP[g]) + '% (' + D1(r.envAbs10[g]) + ' dBFS): ';
    for k := 0 to NENV - 1 do s := s + D1(r.envDb10[g, k]) + ' ';
    Put(L, s + '| ' + D1(r.envBack10[g]));
  end;
  Put(L, 'SHORT BURSTS at 19.5 kHz: length, level against a steady tone, seen of ' + N0(BURST_N));
  for g := 0 to NBURST - 1 do
    Put(L, N0(BURST_MS[g]) + ' ms: ' + D1(r.burstDb10[g]) + ' dB, ' + N0(r.burstSeen[g]) + ' of ' + N0(BURST_N));
  { in words }
  worst := 0;
  for g := 0 to NAGC - 1 do if r.envDb10[g, 3] < worst then worst := r.envDb10[g, 3];
  if worst <= -150 then Put(L, 'The level falls ' + D1(-worst) + ' dB within half a second of a tone starting: automatic gain.')
  else Put(L, 'The level stays within ' + D1(-worst) + ' dB while a tone goes on: no strong automatic gain.');
end;

procedure BuildCompact(const r: TScanResult; var L: TLines);
var i, g, k, lo, hi, best, bi, nl, med: Integer; s: string; t: array[0..NTONE - 1] of Integer;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'MIC SCAN failed: ' + r.err); Exit; end;
  Put(L, 'MIC SCAN');
  Put(L, 'Real rate ' + N0(r.rate100 div 100) + ' Hz (claims 44100). Markers ' + D1(r.markDb10) + ' / ' + D1(r.endDb10) + ' dBFS. Background ' + D1(r.noiseRms10) + ' dBFS');
  lo := UsableLowHz(r); hi := UsableHighHz(r);
  best := -9990; bi := 0;
  for i := 0 to NTONE - 1 do if r.toneDb10[i] - r.noiseDb10[i] > best then begin best := r.toneDb10[i] - r.noiseDb10[i]; bi := i; end;
  if lo = 0 then Put(L, 'Usable: none (20 dB over background and steady)')
  else Put(L, 'Usable (20 dB over background, steady): ' + KHz1(lo) + ' to ' + KHz1(hi) + ' kHz. Best ' + KHz1(ToneHz(bi)) + ' kHz, ' + D1(best) + ' dB over background');
  Put(L, 'Tones kHz:level dBFS/over background dB/fall in 0.4 s dB');
  s := '';
  for i := 1 to NTONE - 1 do
    if (i mod 2) = 1 then
    begin
      s := s + KHz1(ToneHz(i)) + ':' + D1(r.toneDb10[i]) + '/' + D1(r.toneDb10[i] - r.noiseDb10[i]) + '/' + D1(r.fall10[i]) + '  ';
      if Length(s) > 70 then begin Put(L, s); s := ''; end;
    end;
  if s <> '' then Put(L, s);
  nl := 0;
  for i := 4 to NTONE - 1 do if (r.toneDb10[i] - r.noiseDb10[i] > 150) and (r.ghostLo10[i] > -9000) then begin t[nl] := r.ghostLo10[i]; Inc(nl); end;
  if nl > 0 then begin
    for i := 1 to nl - 1 do begin k := t[i]; g := i - 1; while (g >= 0) and (t[g] > k) do begin t[g + 1] := t[g]; Dec(g); end; t[g + 1] := k; end;
    med := t[nl div 2];
    Put(L, 'Ghost 0.9 kHz below a tone: median ' + D1(med) + ' dB');
  end;
  Put(L, 'Level while a tone goes on (dB; at 0.05 0.1 0.25 0.5 1 1.9 s | after pause)');
  for g := 0 to NAGC - 1 do
  begin
    s := KHz1(AGC_HZ[g]) + 'k ' + N0(AGC_AMP[g]) + '%: ';
    for k := 0 to NENV - 1 do s := s + D1(r.envDb10[g, k]) + ' ';
    Put(L, s + '| ' + D1(r.envBack10[g]));
  end;
  s := 'Bursts 19.5k (dB vs steady, seen of 6): ';
  for g := 0 to NBURST - 1 do s := s + N0(BURST_MS[g]) + 'ms ' + D1(r.burstDb10[g]) + ' ' + N0(r.burstSeen[g]) + '/6  ';
  Put(L, s);
end;

end.
