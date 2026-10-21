unit retlib;
{ Return Test: can the handheld hear data sent by the phone?

  The phone page (return.html) plays 12 blocks of 96 symbols; each symbol is one of 16 tones 100 Hz apart (4 bits),
  after a preamble tone, at three volumes, three symbol lengths and four frequency bands. The handheld records it,
  finds each block, decides for every symbol which of the 16 tones is strongest, and counts the wrong ones.
  The plan is the same as in retplan.js. }
{$mode objfpc}{$H+}
interface
uses scanlib;

const
  R_MARK_HZ = 4000; R_MARK_MS = 600;
  R_END_AT = 49500; R_PLAN_MS = 50100;
  R_START = 2000; R_PRE = 400; R_GAP = 300; R_NSYM = 96;
  NBLK = 12;

type
  TRetResult = record
    ok: Boolean;
    err: string[100];
    n: LongInt;
    rate100: LongInt;
    t0, t1: LongInt;
    dc: LongInt;
    markDb10, endDb10, noiseRms10: Integer;
    off: array[0..NBLK - 1] of Integer;          { how far (ms) the block was from where the plan says }
    errs, errsEarly: array[0..NBLK - 1] of Integer;   { wrong symbols of 96, and among the first 10 }
    margMed10, margWorst10: array[0..NBLK - 1] of Integer;   { strongest tone over the next strongest, dB x 10: median, and the 5th weakest of 96 }
    lvl10: array[0..NBLK - 1] of Integer;        { level of the right tone, dBFS x 10 }
    pre0, pre100, pre300: array[0..NBLK - 1] of Integer;     { preamble: level at the start (dBFS x 10), and 100 and 300 ms later relative to it }
  end;

function BlockBase(k: Integer): Integer;
function BlockVol(k: Integer): Integer;
function BlockSym(k: Integer): Integer;
function BlockStart(k: Integer): LongInt;
procedure AnalyseRet(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TRetResult);
procedure BuildRetReport(const r: TRetResult; var L: TLines);
procedure BuildRetCompact(const r: TRetResult; var L: TLines);
function BandName(base: Integer): string;

implementation

const
  VOLS: array[0..2] of Integer = (90, 45, 22);
  SYMS: array[0..2] of Integer = (48, 32, 20);
  BASEX: array[0..2] of Integer = (16000, 17000, 19000);

function BlockBase(k: Integer): Integer;
begin
  if k < 9 then Result := 18000 else Result := BASEX[k - 9];
end;

function BlockVol(k: Integer): Integer;
begin
  if k < 9 then Result := VOLS[k div 3] else Result := 90;
end;

function BlockSym(k: Integer): Integer;
begin
  if k < 9 then Result := SYMS[k mod 3] else Result := 32;
end;

function BlockStart(k: Integer): LongInt;
var i: Integer; t: LongInt;
begin
  t := R_START;
  for i := 0 to k - 1 do t := t + R_PRE + R_NSYM * BlockSym(i) + R_GAP;
  Result := t;
end;

procedure MakeSyms(k: Integer; var s: array of Byte);
var x: Int64; j: Integer;
begin
  x := 777 + k;
  for j := 0 to R_NSYM - 1 do
  begin
    x := (x * 1103515245 + 12345) and $7FFFFFFF;
    s[j] := (x shr 16) and 15;
  end;
end;

function ToS(const r: TRetResult; ms: LongInt): LongInt;
begin
  Result := r.t0 + Round(Int64(ms) * r.rate100 / 100000);
end;

procedure Analyse1(x: PSamples; var r: TRetResult; k: Integer; var lastOff: Integer; first: Boolean);
var syms: array[0..R_NSYM - 1] of Byte;
    sy, base, j, t, o, o0, o1, step, best, bi, errs, early, ex, m, ii: Integer;
    sc, bsc, a, am, other: Double; start: LongInt;
    marg: array[0..R_NSYM - 1] of Integer;
    amps: array[0..15] of Double; lvlSum: Int64; hz: Integer; p0: Integer;

  function Score(off: Integer; every: Integer): Double;
  var jj: Integer; s: Double; w0, w1: LongInt;
  begin
    s := 0;
    jj := 0;
    while jj < R_NSYM do
    begin
      w0 := ToS(r, start + R_PRE + off + jj * sy + (sy div 10));
      w1 := ToS(r, start + R_PRE + off + (jj + 1) * sy - (sy div 10));
      s := s + ToneAmp(x, w0, w1 - w0, base + 100 * syms[jj], r.rate100);
      Inc(jj, every);
    end;
    Score := s;
  end;

begin
  MakeSyms(k, syms);
  base := BlockBase(k); sy := BlockSym(k); start := BlockStart(k);
  { where the block really is: the offset that puts the most energy in the right tones }
  if first then begin o0 := -60; o1 := 60; end else begin o0 := lastOff - 12; o1 := lastOff + 12; end;
  bsc := -1; bi := 0;
  o := o0;
  while o <= o1 do
  begin
    sc := Score(o, 4);
    if sc > bsc then begin bsc := sc; bi := o; end;
    Inc(o, 2);
  end;
  best := bi;
  bsc := -1;
  for o := best - 1 to best + 1 do
  begin
    sc := Score(o, 1);
    if sc > bsc then begin bsc := sc; bi := o; end;
  end;
  r.off[k] := bi; lastOff := bi;
  { the symbols }
  errs := 0; early := 0; lvlSum := 0;
  for j := 0 to R_NSYM - 1 do
  begin
    ii := ToS(r, start + R_PRE + bi + j * sy + (sy div 10));
    m := ToS(r, start + R_PRE + bi + (j + 1) * sy - (sy div 10)) - ii;
    am := -1; ex := 0; other := 0;
    for t := 0 to 15 do
    begin
      a := ToneAmp(x, ii, m, base + 100 * t, r.rate100);
      amps[t] := a;
      if a > am then begin am := a; ex := t; end;
    end;
    for t := 0 to 15 do if (t <> syms[j]) and (amps[t] > other) then other := amps[t];
    if ex <> syms[j] then begin Inc(errs); if j < 10 then Inc(early); end;
    marg[j] := DbOf(amps[syms[j]]) - DbOf(other);
    lvlSum := lvlSum + DbOf(amps[syms[j]]);
  end;
  r.errs[k] := errs; r.errsEarly[k] := early;
  r.lvl10[k] := lvlSum div R_NSYM;
  for j := 1 to R_NSYM - 1 do
  begin
    t := marg[j]; ii := j - 1;
    while (ii >= 0) and (marg[ii] > t) do begin marg[ii + 1] := marg[ii]; Dec(ii); end;
    marg[ii + 1] := t;
  end;
  r.margMed10[k] := marg[R_NSYM div 2];
  r.margWorst10[k] := marg[4];
  { the preamble, to see how the gain settles }
  hz := base + 500;
  m := ToS(r, 20) - ToS(r, 0);
  p0 := DbOf(ToneAmp(x, ToS(r, start + bi), m, hz, r.rate100));
  r.pre0[k] := p0;
  r.pre100[k] := DbOf(ToneAmp(x, ToS(r, start + bi + 100), m, hz, r.rate100)) - p0;
  r.pre300[k] := DbOf(ToneAmp(x, ToS(r, start + bi + 300), m, hz, r.rate100)) - p0;
end;

procedure AnalyseRet(x: PSamples; n: LongInt; nominalRate: LongInt; var r: TRetResult);
var i, k, bs, be: LongInt; sum, sq: Double; lastOff: Integer; s0, s1: LongInt;
begin
  FillChar(r, SizeOf(r), 0);
  r.n := n;
  SetOffset(0);
  r.rate100 := nominalRate * 100;
  if n < nominalRate * 20 then begin r.err := 'The recording is too short (under 20 seconds).'; Exit; end;
  r.t0 := FindMarkerAt(x, 0, n - nominalRate * 20, nominalRate);
  if r.t0 < 0 then begin r.err := 'The first marker (4 kHz beep) was not heard. Move the phone closer and turn it up.'; Exit; end;
  s0 := r.t0 + nominalRate * 48; s1 := r.t0 + nominalRate * 54;
  if s1 > n then s1 := n;
  r.t1 := -1;
  if s1 - s0 > nominalRate then r.t1 := FindMarkerAt(x, s0, s1, nominalRate);
  if r.t1 < 0 then begin r.err := 'The end marker was not heard: record until the phone says Done.'; Exit; end;
  r.rate100 := Round((r.t1 - r.t0) / (R_END_AT / 1000.0) * 100);
  if (r.rate100 < nominalRate * 100 * 90 div 100) or (r.rate100 > nominalRate * 100 * 110 div 100) then
  begin r.err := 'The markers are not 49.5 seconds apart: something went wrong in the recording.'; Exit; end;
  bs := ToS(r, 800); be := ToS(r, 1800);
  sum := 0;
  for i := bs to be - 1 do sum := sum + x^[i];
  r.dc := Round(sum / (be - bs));
  SetOffset(r.dc);
  sq := 0;
  for i := bs to be - 1 do sq := sq + Double(x^[i] - r.dc) * (x^[i] - r.dc);
  r.noiseRms10 := DbOf(Sqrt(sq / (be - bs)) * 1.41421356);
  r.markDb10 := DbOf(ToneAmp(x, ToS(r, 50), ToS(r, R_MARK_MS - 50) - ToS(r, 50), R_MARK_HZ, r.rate100));
  r.endDb10 := DbOf(ToneAmp(x, ToS(r, R_END_AT + 50), ToS(r, R_END_AT + R_MARK_MS - 50) - ToS(r, R_END_AT + 50), R_MARK_HZ, r.rate100));
  lastOff := 0;
  for k := 0 to NBLK - 1 do Analyse1(x, r, k, lastOff, k = 0);
  r.ok := True;
end;

{ ---------- text ---------- }

function N0(v: LongInt): string;
var s: string[16];
begin
  Str(v, s); N0 := s;
end;

function D1(v: Integer): string;
var s: string[12];
begin
  Str(Abs(v) div 10, s);
  if v < 0 then s := '-' + s;
  D1 := s + '.' + Chr(48 + Abs(v) mod 10);
end;

function KH(hz: Integer): string;
var q: Integer;
begin
  q := (hz mod 1000) div 100;
  KH := N0(hz div 1000) + '.' + N0(q);
end;

function BandName(base: Integer): string;
begin
  BandName := KH(base) + '-' + KH(base + 1500);
end;

procedure Put(var L: TLines; const s: string);
begin
  if L.n < MAXLINES then begin L.s[L.n] := s; Inc(L.n); end;
end;

function Good(const r: TRetResult; k: Integer): Boolean;
begin
  Good := (r.errs[k] = 0) and (r.margWorst10[k] >= 60);
end;

procedure Verdict(const r: TRetResult; var L: TLines);
var v, s: Integer; t: string; found: Boolean;
begin
  for v := 0 to 2 do
  begin
    t := 'At ' + N0(VOLS[v]) + ' % volume (' + BandName(18000) + ' kHz): ';
    found := False;
    for s := 2 downto 0 do
      if (not found) and Good(r, v * 3 + s) then begin t := t + 'clean down to ' + N0(SYMS[s]) + ' ms per symbol'; found := True; end;
    if not found then
    begin
      if r.errs[v * 3] = 0 then t := t + 'no wrong symbols at 48 ms, but too little margin'
      else t := t + 'not clean even at 48 ms (' + N0(r.errs[v * 3]) + ' wrong)';
    end;
    Put(L, t);
  end;
  t := 'Other bands at 90 %, 32 ms, wrong of 96:';
  for v := 0 to 2 do t := t + ' ' + BandName(BASEX[v]) + ': ' + N0(r.errs[9 + v]) + ';';
  Put(L, t);
end;

procedure BuildRetReport(const r: TRetResult; var L: TLines);
var k: Integer;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'RETURN TEST failed'); Put(L, r.err); Exit; end;
  Put(L, 'RETURN TEST, phone to handheld');
  Put(L, 'Real rate ' + N0(r.rate100 div 100) + ' Hz. Offset ' + N0(r.dc) + '. Markers ' + D1(r.markDb10) + ' / ' + D1(r.endDb10) + ' dBFS. Background ' + D1(r.noiseRms10) + ' dBFS');
  Verdict(r, L);
  Put(L, 'BLOCKS: band kHz, volume, ms per symbol: wrong of 96 (first 10) | margin median/worst dB | level dBFS | preamble start, +100, +300 ms');
  for k := 0 to NBLK - 1 do
    Put(L, BandName(BlockBase(k)) + ' ' + N0(BlockVol(k)) + '% ' + N0(BlockSym(k)) + 'ms: ' + N0(r.errs[k]) + ' (' + N0(r.errsEarly[k]) + ') | '
        + D1(r.margMed10[k]) + '/' + D1(r.margWorst10[k]) + ' | ' + D1(r.lvl10[k]) + ' | ' + D1(r.pre0[k]) + ' ' + D1(r.pre100[k]) + ' ' + D1(r.pre300[k]));
end;

procedure BuildRetCompact(const r: TRetResult; var L: TLines);
var k: Integer;
begin
  L.n := 0;
  if not r.ok then begin Put(L, 'RETURN TEST failed: ' + r.err); Exit; end;
  Put(L, 'RETURN TEST');
  Put(L, 'Real rate ' + N0(r.rate100 div 100) + ' Hz. Markers ' + D1(r.markDb10) + ' / ' + D1(r.endDb10) + ' dBFS. Background ' + D1(r.noiseRms10) + ' dBFS');
  Verdict(r, L);
  Put(L, 'Block: wrong of 96 (first 10) | margin med/worst dB | level | preamble +100,+300 ms');
  for k := 0 to NBLK - 1 do
    Put(L, BandName(BlockBase(k)) + ' ' + N0(BlockVol(k)) + '% ' + N0(BlockSym(k)) + 'ms: ' + N0(r.errs[k]) + ' (' + N0(r.errsEarly[k]) + ') | '
        + D1(r.margMed10[k]) + '/' + D1(r.margWorst10[k]) + ' | ' + D1(r.lvl10[k]) + ' | ' + D1(r.pre100[k]) + ' ' + D1(r.pre300[k]));
end;

end.
