unit w3rx;
{ Format 3 receiver for the handheld: reads one channel from sound at the
  modem rate (51,200 samples/s). The same method as the phone's Rx.java, in
  whole numbers only:
  - the sync symbol repeats after 256 (fast) or 128 (silent) samples: a
    running correlation of the sound with itself finds it;
  - the reference symbol confirms the frame and sets the timing (the peak of
    the room's response measured on it);
  - each symbol is compared with the one before; the pilots, then all the
    decided carriers, take out the turn all carriers share. }
{$mode objfpc}{$H+}
interface

uses w3core, w3dsp;

const
  RB = 1 shl 15; RMASK = RB - 1; RBACK = 8;
  MSGQ = 8;

type
  TBiquad = record
    b0, b1, b2, a1, a2: LongInt;          { Q14 }
    x1, x2, y1, y2: LongInt;
  end;
  TRxMsg = record
    typ, len, snr10, fixed: Integer;
    data: array[0..MAXMSG - 1] of Byte;
  end;
  TCarr = array[0..MAXCAR - 1] of LongInt;
  TRx = record
    ch: Integer;
    lag, lagShift: Integer;
    buf: array[0..RB - 1] of SmallInt;
    fb: array[0..RB - 1] of SmallInt;
    metric: array[0..RB - 1] of SmallInt;     { Q12 }
    energy: array[0..RB - 1] of LongInt;
    t: Int64;
    P, E1, E2: Int64;
    resum: Integer;
    pre: array[0..1] of TBiquad; npre: Integer;
    floor: LongInt;
    state: Integer;
    scan, trig, sym0: Int64;
    s, hsym, psym, adjust, moved: Integer;
    tau8: LongInt;                     { drift, in 1/256 sample }
    typ, len, mapNo: Integer;
    std, cur: TBitMap;
    maps: array[0..31] of TBitMap;
    haveMap: array[0..31] of Boolean;
    prevRe, prevIm: TCarr;
    bitsBuf: array of Byte; bitPos: Integer;
    errSum: Int64; errN: Integer;
    trainErr: array[0..MAXCAR - 1] of Int64;
    trainN: Integer;
    { results }
    q: array[0..MSGQ - 1] of TRxMsg;
    qHead, qTail: Integer;
    trainReady: Boolean;
    trainSnr10: array[0..MAXCAR - 1] of Integer;
    frames, fails: Integer;
    lastFail: string;
    { for the diagnostics log: frames that seemed to start, that were found (S and R), headers read, the last one }
    trigs, starts, hdrs, hdrTyp, hdrLen, hdrSym, gated: Integer;
    { the full checks of the last tenth of a second (3.8.2): at most 3 }
    fullAt: Int64; fullN: Integer;
  end;
  PRx = ^TRx;

procedure RxInit(var r: TRx; ch: Integer);
procedure RxAddMap(var r: TRx; const m: TBitMap);
procedure RxPush(var r: TRx; const x: array of SmallInt; off, n: Integer);
function RxTake(var r: TRx; var m: TRxMsg): Boolean;

implementation

const IDLE = 0; SEEK = 1; DECODE = 2; DECIM = 4;

procedure BqSet(var b: TBiquad; const c: array of LongInt);
begin
  b.b0 := c[0]; b.b1 := c[1]; b.b2 := c[2]; b.a1 := c[3]; b.a2 := c[4];
  b.x1 := 0; b.x2 := 0; b.y1 := 0; b.y2 := 0;
end;

function BqRun(var b: TBiquad; x: LongInt): LongInt; inline;
var y: LongInt;
begin
  y := SarLongint(b.b0 * x + b.b1 * b.x1 + b.b2 * b.x2 - b.a1 * b.y1 - b.a2 * b.y2, 14);
  b.x2 := b.x1; b.x1 := x; b.y2 := b.y1; b.y1 := y;
  Result := y;
end;

procedure RxInit(var r: TRx; ch: Integer);
var i: Integer;
begin
  FillChar(r, SizeOf(r), 0);
  r.ch := ch;
  r.lag := NFFT div Chans[ch].syncStep;
  r.lagShift := 0; while (1 shl r.lagShift) < r.lag do Inc(r.lagShift);
  StdMap(ch, r.std);
  for i := 0 to 31 do r.haveMap[i] := False;
  r.maps[0] := r.std; r.haveMap[0] := True;
  if Chans[ch].silent then
  begin
    BqSet(r.pre[0], BQ_SILENT1); BqSet(r.pre[1], BQ_SILENT2); r.npre := 2;
  end
  else begin BqSet(r.pre[0], BQ_FAST); r.npre := 1; end;
  r.floor := 0;
  r.scan := 600;
  r.state := IDLE;
  SetLength(r.bitsBuf, MAXCODED + 64);
end;

procedure RxAddMap(var r: TRx; const m: TBitMap);
begin
  if m.ch <> r.ch then Exit;
  r.maps[m.number and 31] := m; r.haveMap[m.number and 31] := True;
end;

function RxTake(var r: TRx; var m: TRxMsg): Boolean;
begin
  Result := r.qHead <> r.qTail;
  if not Result then Exit;
  m := r.q[r.qTail];
  r.qTail := (r.qTail + 1) mod MSGQ;
end;

procedure PutBits(var r: TRx; v, n: Integer);
var i, byteI: Integer;
begin
  for i := n - 1 downto 0 do
  begin
    byteI := r.bitPos shr 3;
    if byteI < Length(r.bitsBuf) then
      if ((v shr i) and 1) <> 0 then r.bitsBuf[byteI] := r.bitsBuf[byteI] or ($80 shr (r.bitPos and 7));
    Inc(r.bitPos);
  end;
end;

procedure ClearBits(var r: TRx);
var i: Integer;
begin
  for i := 0 to High(r.bitsBuf) do r.bitsBuf[i] := 0;
  r.bitPos := 0;
end;

{ the carriers of the 512 samples from w }
procedure SymFft(var r: TRx; w: Int64; var cre, cim: TCarr);
var re, im: TCpx; i: Integer;
begin
  for i := 0 to 511 do begin re[i] := r.buf[(w + i) and RMASK]; im[i] := 0; end;
  Fft(re, im, -1, True);
  for i := 0 to Chans[r.ch].n - 1 do begin cre[i] := re[Chans[r.ch].bins[i]]; cim[i] := im[Chans[r.ch].bins[i]]; end;
end;

type
  TFit = record s, sx, sy, sxx, sxy: Int64; end;

procedure FitClear(var f: TFit);
begin
  f.s := 0; f.sx := 0; f.sy := 0; f.sxx := 0; f.sxy := 0;
end;

procedure FitAdd(var f: TFit; w, x, y: Int64); inline;
begin
  f.s := f.s + w; f.sx := f.sx + w * x; f.sy := f.sy + w * y; f.sxx := f.sxx + w * x * x; f.sxy := f.sxy + w * x * y;
end;

{ the straight line y = (a8 + b8 x) / 256 through the weighted points }
procedure FitSolve(const f: TFit; out a8, b8: Int64);
var den: Int64;
begin
  den := f.s * f.sxx - f.sx * f.sx;
  if den > 0 then b8 := ((f.s * f.sxy - f.sx * f.sy) * 256) div den else b8 := 0;
  if f.s > 0 then a8 := (f.sy * 256 - b8 * f.sx) div f.s else a8 := 0;
end;

{ weights of 0..256 from magnitudes }
procedure Weights(const mag: array of Int64; n: Integer; var w: array of Integer);
var c: Integer; mx: Int64;
begin
  mx := 1;
  for c := 0 to n - 1 do if mag[c] > mx then mx := mag[c];
  for c := 0 to n - 1 do w[c] := (mag[c] * 256) div mx;
end;

{ on the reference symbol (ref) or the sync symbol: how many samples early the window is (of 256), and the coherence (of 4096) }
procedure Slope(var r: TRx; const yre, yim: TCarr; ref: Boolean; out early8: Int64; out coh: Integer);
var Cn: TChannel; zr, zi: TCarr; c, q, g, span, best, k, d0, it, cm: Integer;
    re, im: TCpx; bm, m, mr, mi, sa, th8, a8, b8: Int64; a, m0: Integer;
    rr, ii: LongInt; f: TFit; mag: array[0..MAXCAR - 1] of Int64; w: array[0..MAXCAR - 1] of Integer;
    ph: array[0..MAXCAR - 1] of Integer;
begin
  Cn := Chans[r.ch];
  for c := 0 to Cn.n - 1 do
  begin
    if (not ref) and ((Cn.bins[c] mod Cn.syncStep) <> 0) then begin zr[c] := 0; zi[c] := 0; Continue; end;   { S leaves these off }
    if ref then q := RPhase(c) else q := SPhase(c);  { turn back by q quarter turns: exact }
    case q of
      0: begin zr[c] := yre[c]; zi[c] := yim[c]; end;
      1: begin zr[c] := yim[c]; zi[c] := -yre[c]; end;
      2: begin zr[c] := -yre[c]; zi[c] := -yim[c]; end;
    else begin zr[c] := -yim[c]; zi[c] := yre[c]; end;
    end;
  end;
  { the room's response: its strongest arrival }
  for k := 0 to 511 do begin re[k] := 0; im[k] := 0; end;
  for c := 0 to Cn.n - 1 do begin re[Cn.bins[c]] := zr[c]; im[Cn.bins[c]] := zi[c]; end;
  Fft(re, im, 1, True);
  g := Cn.bins[1] - Cn.bins[0]; span := NFFT div g; best := 0; bm := -1;
  for k := 0 to span - 1 do
  begin
    m := Int64(re[k]) * re[k] + Int64(im[k]) * im[k];
    if m > bm then begin bm := m; best := k; end;
  end;
  if best <= span div 2 then d0 := best else d0 := best - span;
  th8 := -Int64(128) * g * d0 * 256;                 { turn per carrier, 1/256 of 1/65536 of a turn }
  cm := Cn.n div 2;
  for it := 1 to 2 do
  begin
    mr := 0; mi := 0;
    for c := 0 to Cn.n - 1 do
    begin
      a := (-th8 * c div 256) and $FFFF;
      mr := mr + (Int64(zr[c]) * CosI(a) - Int64(zi[c]) * SinI(a)) div 16384;
      mi := mi + (Int64(zr[c]) * SinI(a) + Int64(zi[c]) * CosI(a)) div 16384;
    end;
    while (Abs(mr) > 1 shl 28) or (Abs(mi) > 1 shl 28) do begin mr := mr div 2; mi := mi div 2; end;
    m0 := Atan2i(LongInt(mi), LongInt(mr));
    for c := 0 to Cn.n - 1 do
    begin
      a := ((-th8 * c div 256) - m0) and $FFFF;
      rr := (Int64(zr[c]) * CosI(a) - Int64(zi[c]) * SinI(a)) div 16384;
      ii := (Int64(zr[c]) * SinI(a) + Int64(zi[c]) * CosI(a)) div 16384;
      mag[c] := MagI(rr, ii);
      ph[c] := WrapA(Atan2i(ii, rr));
    end;
    Weights(mag, Cn.n, w);
    FitClear(f);
    for c := 0 to Cn.n - 1 do FitAdd(f, w[c], c - cm, ph[c]);
    FitSolve(f, a8, b8);
    th8 := th8 + b8;
  end;
  early8 := -th8 div (128 * g);
  mr := 0; mi := 0; sa := 0;
  for c := 0 to Cn.n - 1 do
  begin
    a := (-th8 * c div 256) and $FFFF;
    mr := mr + (Int64(zr[c]) * CosI(a) - Int64(zi[c]) * SinI(a)) div 16384;
    mi := mi + (Int64(zr[c]) * SinI(a) + Int64(zi[c]) * CosI(a)) div 16384;
    sa := sa + MagI(zr[c], zi[c]);
  end;
  while (Abs(mr) > 1 shl 28) or (Abs(mi) > 1 shl 28) do begin mr := mr div 2; mi := mi div 2; sa := sa div 2; end;
  if sa > 0 then coh := (Int64(MagI(LongInt(mr), LongInt(mi))) * 4096) div sa else coh := 0;
end;

{ the share of the power on the carriers S leaves off, of 4096 }
function OffShare(var r: TRx; const yre, yim: TCarr): Integer;
var c: Integer; p, off, all: Int64;
begin
  off := 0; all := 1;
  for c := 0 to Chans[r.ch].n - 1 do
  begin
    p := Int64(yre[c]) * yre[c] + Int64(yim[c]) * yim[c];
    all := all + p;
    if (Chans[r.ch].bins[c] mod Chans[r.ch].syncStep) <> 0 then off := off + p;
  end;
  Result := (off * 4096) div all;
end;

{ S at w: the carriers it uses (bins on its step) should all hold some of its power: at least half of them
  a tenth of their average. On a fast channel, its upper half of the band should also hold at least a
  hundredth of what the lower half holds (a voice or a hum holds far less up there). }
function SLooksRight(var r: TRx; w: Int64): Boolean;
var yre, yim: TCarr; c, n, cnt, on, nOff: Integer; p: array[0..MAXCAR - 1] of Int64; sum, lo, hi, offSum: Int64; Cn: TChannel;
begin
  Cn := Chans[r.ch];
  SymFft(r, w, yre, yim);
  sum := 0; n := 0; lo := 0; hi := 0; offSum := 0; nOff := 0;
  for c := 0 to Cn.n - 1 do
  begin
    p[c] := -1;
    if (Cn.bins[c] mod Cn.syncStep) <> 0 then
    begin
      { S leaves these carriers off }
      offSum := offSum + Int64(yre[c]) * yre[c] + Int64(yim[c]) * yim[c]; Inc(nOff);
      Continue;
    end;
    p[c] := Int64(yre[c]) * yre[c] + Int64(yim[c]) * yim[c];
    sum := sum + p[c]; Inc(n);
    if c < Cn.n div 2 then lo := lo + p[c] else hi := hi + p[c];
  end;
  if (n = 0) or (sum <= 0) then begin Result := False; Exit; end;
  cnt := 0; on := 0;
  for c := 0 to Cn.n - 1 do
    if p[c] >= 0 then begin Inc(cnt); if p[c] * 10 * n >= sum then Inc(on); end;
  Result := on * 2 >= cnt;
  { S holds its carriers and leaves the ones between them empty; a voice, a click or noise fills both alike.
    On average the carriers it uses must hold at least 3 times what the others do. }
  if Result and (nOff > 0) then Result := (sum div n) >= 3 * (offSum div nOff);
  if Result and (not Cn.silent) then Result := hi * 100 >= lo;
end;

procedure Fail(var r: TRx; const why: string);
begin
  Inc(r.fails);
  r.lastFail := why;
  {$ifdef RXDEBUG}WriteLn('fail ', why, ' sym0 ', r.sym0);{$endif}
  r.state := IDLE;
  { on from the frame's start, but never back over where it was triggered: the same sound would start it
    again and again (on the phone, a thousand times a second) }
  r.scan := r.sym0 + NSYM;
  if r.scan < r.trig + r.lag then r.scan := r.trig + r.lag;
end;

procedure Symbol(var r: TRx; w: Int64);
var Cn: TChannel; yre, yim: TCarr; dr, di: array[0..MAXCAR - 1] of Int64;
    c, n, ts, nb, lv, pass, k, q, a, e, cm, stp: Integer; head, train: Boolean;
    t, a8, b8, x8, alpha8, beta8, dt8: Int64;
    idx, ang, wt: array[0..MAXCAR - 1] of Integer; mag: array[0..MAXCAR - 1] of Int64;
    m: TBitMap; f: TFit;
begin
  Cn := Chans[r.ch]; n := Cn.n; cm := Cn.bins[n div 2];
  SymFft(r, w, yre, yim);
  if r.moved <> 0 then
  begin
    { the window was just moved by m samples, which turned every carrier by bin x m / 512 of a turn: turn it
      back, so that the comparison with the symbol before sees only the sound }
    for c := 0 to n - 1 do
    begin
      a := (-Cn.bins[c] * r.moved * 128) and $FFFF;
      t := (Int64(yre[c]) * CosI(a) - Int64(yim[c]) * SinI(a)) div 16384;
      yim[c] := (Int64(yre[c]) * SinI(a) + Int64(yim[c]) * CosI(a)) div 16384;
      yre[c] := t;
    end;
    r.moved := 0;
  end;
  head := r.s < 2 + r.hsym;
  train := (not head) and (r.typ = T_TRAIN);
  ts := r.s - 2 - r.hsym;
  for c := 0 to n - 1 do
  begin
    dr[c] := Int64(yre[c]) * r.prevRe[c] + Int64(yim[c]) * r.prevIm[c];
    di[c] := Int64(yim[c]) * r.prevRe[c] - Int64(yre[c]) * r.prevIm[c];
    if train then
    begin
      q := (4 - TrainStep(c, ts)) and 3;              { take out the known step }
      case q of
        1: begin t := dr[c]; dr[c] := -di[c]; di[c] := t; end;
        2: begin dr[c] := -dr[c]; di[c] := -di[c]; end;
        3: begin t := dr[c]; dr[c] := di[c]; di[c] := -t; end;
      end;
    end;
    r.prevRe[c] := yre[c]; r.prevIm[c] := yim[c];
  end;
  for c := 0 to n - 1 do
  begin
    t := Abs(dr[c]); if Abs(di[c]) > t then t := Abs(di[c]);
    k := 0; while t > 1 shl 28 do begin t := t shr 1; Inc(k); end;
    ang[c] := Atan2i(LongInt(di[c] div (Int64(1) shl k)), LongInt(dr[c] div (Int64(1) shl k)));
    mag[c] := Int64(MagI(LongInt(dr[c] div (Int64(1) shl k)), LongInt(di[c] div (Int64(1) shl k)))) shl k;
  end;
  Weights(mag, n, wt);
  { the pilots (in training, every carrier): a common turn and one growing with frequency }
  FitClear(f);
  for c := 0 to n - 1 do
    if train or Cn.pilot[c] then FitAdd(f, wt[c], Cn.bins[c] - cm, WrapA(ang[c]));
  FitSolve(f, alpha8, beta8);
  if head then m := r.std else m := r.cur;
  { decide every carrier, then fit the common turn again from all of them (decisions included) and decide again }
  for pass := 0 to 1 do
  begin
    FitClear(f);
    for c := 0 to n - 1 do
    begin
      x8 := alpha8 + beta8 * (Cn.bins[c] - cm);
      a := WrapA(ang[c] - x8 div 256);
      if train or Cn.pilot[c] then nb := 0 else nb := m.bits[c];
      if (not train) and (not Cn.pilot[c]) and (nb = 0) then Continue;
      if nb > 0 then
      begin
        lv := 1 shl nb; stp := 65536 div lv;
        k := (a + stp div 2 + 65536) div stp - lv;   { the nearest step (a + 65536 keeps the division positive) }
        e := a - k * stp;
        idx[c] := ((k mod lv) + lv) mod lv;
      end
      else e := a;
      if pass = 0 then FitAdd(f, wt[c], Cn.bins[c] - cm, e)
      else if train then r.trainErr[c] := r.trainErr[c] + Int64(e) * e
      else if nb > 0 then begin r.errSum := r.errSum + Int64(e) * e; Inc(r.errN); end;
    end;
    if pass = 0 then
    begin
      FitSolve(f, a8, b8);
      alpha8 := alpha8 + a8; beta8 := beta8 + b8;
      { follow the drift (from all carriers): a clock drifts by a small fraction of a sample per symbol,
        so a larger reading is noise or a wrapped phase and is left out }
      dt8 := -beta8 div 128;
      if Abs(dt8) < 256 then r.tau8 := r.tau8 + dt8;
      if Abs(r.tau8) >= 3 * 256 then
      begin
        k := (r.tau8 + 128 * Ord(r.tau8 > 0) - 128 * Ord(r.tau8 < 0)) div 256;
        Inc(r.adjust, k);
        r.tau8 := r.tau8 - k * 256;
        r.moved := k;
      end;
    end;
  end;
  if train then begin Inc(r.trainN); Exit; end;
  for c := 0 to n - 1 do
  begin
    if Cn.pilot[c] then Continue;
    nb := m.bits[c];
    if nb = 0 then Continue;
    k := idx[c];
    PutBits(r, k xor (k shr 1), nb);
  end;
end;

{ tenths of a dB from a mean square phase error in (1/65536 turn)^2: 100 log10(65536^2 / (4 pi^2) / mse) }
function SnrTenths(sum: Int64; n: Integer): Integer;
var mse: Int64;
begin
  if n < 1 then n := 1;
  mse := sum div n;
  if mse < 1 then mse := 1;
  Result := 804 - Db100(mse);
end;

procedure Finish(var r: TRx);
var coded: array[0..MAXCODED - 1] of Byte; i, fixed, c, cl: Integer; m: ^TRxMsg;
begin
  r.state := IDLE;
  r.scan := r.sym0 + Int64(2 + r.hsym + r.psym) * NSYM;
  if r.typ = T_TRAIN then
  begin
    for c := 0 to Chans[r.ch].n - 1 do r.trainSnr10[c] := SnrTenths(r.trainErr[c], r.trainN);
    r.trainReady := True;
    Inc(r.frames);
    Exit;
  end;
  cl := CodedLength(r.len);
  for i := 0 to cl - 1 do coded[i] := r.bitsBuf[i];
  Scramble(coded, cl, r.ch);
  m := @r.q[r.qHead];
  if not PayloadDecode(coded, r.len, m^.data, fixed) then
  begin
    Inc(r.fails); r.lastFail := 'payload';
    Exit;
  end;
  m^.typ := r.typ; m^.len := r.len; m^.fixed := fixed;
  m^.snr10 := SnrTenths(r.errSum, r.errN);
  r.qHead := (r.qHead + 1) mod MSGQ;
  if r.qHead = r.qTail then r.qTail := (r.qTail + 1) mod MSGQ;      { full: the oldest goes }
  Inc(r.frames);
end;

procedure StepRx(var r: TRx);
var last, d, dS, w, start, early8, st, bestStart: Int64; k, mx, mv, coh, cs, span, bestQ: Integer; e: LongInt; yre, yim: TCarr;
    h: array[0..HDR_CODED - 1] of Byte; i, hb, offS: Integer;
begin
  if r.state = IDLE then
  begin
    last := r.t - 2 * r.lag - DECIM;              { the metric is written DECIM samples at a time }
    while r.scan <= last do
    begin
      k := r.scan and RMASK;
      e := r.energy[k];
      if r.floor = 0 then r.floor := e + 1;          { the first look }
      { a frame: the two halves alike (S), and clearly louder than the recent average. A steady tone
        is alike too, but never louder than its own average: it does not start a frame. }
      if (r.metric[k] > 1843) and ((e shr 1) > r.floor) and (e > 2) then
      begin
        {$ifdef RXDEBUG}WriteLn('trigger at ', r.scan, ' e ', e, ' floor ', r.floor, ' metric ', r.metric[k]);{$endif}
        r.state := SEEK; r.trig := r.scan; Inc(r.trigs); Exit;
      end;
      r.floor := r.floor + SarLongint(e - r.floor, 10);     { about 80 ms }
      if r.floor < 1 then r.floor := 1;
      Inc(r.scan, DECIM);
    end;
    Exit;
  end;
  if r.state = SEEK then
  begin
    if r.t - 2 * r.lag < r.trig + 256 + r.lag then Exit;
    mx := -32768;
    for k := 0 to 255 + r.lag do
    begin
      mv := r.metric[(r.trig + k) and RMASK];
      if mv > mx then mx := mv;
    end;
    if mx < 2048 then begin {$ifdef RXDEBUG}WriteLn('seek: low metric ', mx, ' at ', r.trig);{$endif} r.state := IDLE; r.scan := r.trig + 1; Exit; end;
    { the metric climbs in a straight line for one lag as the window enters S and is level while it
      stays inside: the frame starts half a lag after it is half way up }
    dS := r.trig;
    while (dS > r.trig - 2 * r.lag) and (dS > 0) and (r.metric[(dS - 1) and RMASK] >= mx div 2) do Dec(dS);
    while r.metric[dS and RMASK] < mx div 2 do Inc(dS);
    dS := dS + r.lag div 2;
    w := dS + NSYM + NCP - RBACK;
    if w + NFFT + 2 * NSYM > r.t then Exit;            { wait for R (and some margin) }
    { first a cheap look at S: does its sound lie on our carriers, spread over the band? A voice repeats
      itself too (and fills the fast channel's lower half), a click fills everything; the careful search
      below costs ten times as much. Not ours: on by two symbols. }
    if not SLooksRight(r, dS + NCP - RBACK) then
    begin
      Inc(r.gated);
      r.state := IDLE; r.scan := r.trig + 2 * NSYM; Exit;
    end;
    { and not more than 3 careful searches in a tenth of a second: a sound that keeps passing the look
      (a voice, music) would otherwise use all the processor }
    if r.t - r.fullAt >= (MRATE div 10) then begin r.fullAt := r.t; r.fullN := 0; end;
    Inc(r.fullN);
    if r.fullN > 3 then
    begin
      Inc(r.gated);
      r.state := IDLE; r.scan := r.trig + 2 * NSYM; Exit;
    end;
    SymFft(r, w, yre, yim);
    Slope(r, yre, yim, True, early8, coh);
    start := dS + (early8 + 128) div 256 - RBACK;
    { silent carriers are 200 Hz apart: a shift of 256 samples turns each by whole turns, which R cannot
      see. Of the three places, keep the one where S and R both match best. }
    span := NFFT div (Chans[r.ch].bins[1] - Chans[r.ch].bins[0]);
    bestQ := -1; bestStart := start;
    for k := -1 to 1 do
    begin
      st := start + k * span;
      if (k <> 0) and (span >= NFFT) then Continue;
      if (st + NCP - RBACK < 0) or (st + 2 * NSYM + NFFT > r.t) then Continue;
      SymFft(r, st + NCP - RBACK, yre, yim);
      Slope(r, yre, yim, False, early8, cs);
      offS := OffShare(r, yre, yim);
      SymFft(r, st + NSYM + NCP - RBACK, yre, yim);
      Slope(r, yre, yim, True, early8, coh);
      { S leaves every second carrier off and R fills them all: in the right place the "off" carriers hold
        nothing in S and their share in R. With few carriers the slopes alone match almost as well 256
        samples away. }
      cs := cs + 2 * (OffShare(r, yre, yim) - offS);
      {$ifdef RXDEBUG}WriteLn('  candidate ', k, ' start ', st, ' S ', cs, ' R ', coh);{$endif}
      if cs + coh > bestQ then begin bestQ := cs + coh; bestStart := st; end;
    end;
    start := bestStart;
    SymFft(r, start + NSYM + NCP - RBACK, yre, yim);
    Slope(r, yre, yim, True, early8, coh);
    if coh < 2048 then begin {$ifdef RXDEBUG}WriteLn('seek: coh ', coh, ' trig ', r.trig, ' start ', start);{$endif} r.state := IDLE; r.scan := r.trig + r.lag; Exit; end;
    r.sym0 := start; r.prevRe := yre; r.prevIm := yim;
    r.s := 2; r.adjust := 0; r.tau8 := 0; r.moved := 0;
    hb := MapBits(r.std);
    r.hsym := (HDR_CODED * 8 + hb - 1) div hb;
    r.psym := -1; r.cur := r.std;
    ClearBits(r); r.errSum := 0; r.errN := 0;
    for i := 0 to MAXCAR - 1 do r.trainErr[i] := 0;
    r.trainN := 0;
    r.state := DECODE; Inc(r.starts);
  end;
  if r.state = DECODE then
    while True do
    begin
      w := r.sym0 + Int64(r.s) * NSYM + NCP - RBACK + r.adjust;
      if w + NFFT > r.t then Exit;
      Symbol(r, w);
      Inc(r.s);
      if r.s = 2 + r.hsym then
      begin
        for i := 0 to HDR_CODED - 1 do h[i] := r.bitsBuf[i];
        Scramble(h, HDR_CODED, r.ch);
        if not HeaderDecode(h, r.typ, r.len, r.mapNo) then begin Fail(r, 'header'); Exit; end;
        if not r.haveMap[r.mapNo] then begin Fail(r, 'map'); Exit; end;
        r.cur := r.maps[r.mapNo];
        ClearBits(r);
        Inc(r.hdrs); r.hdrTyp := r.typ; r.hdrLen := r.len;
        if r.typ = T_TRAIN then r.psym := TRAIN_SYMBOLS
        else
        begin
          hb := MapBits(r.cur); if hb < 1 then hb := 1;
          r.psym := (CodedLength(r.len) * 8 + hb - 1) div hb;
          if CodedLength(r.len) > MAXCODED then begin Fail(r, 'length'); Exit; end;
        end;
        r.errSum := 0; r.errN := 0;
        r.hdrSym := r.psym;
      end;
      if (r.psym >= 0) and (r.s = 2 + r.hsym + r.psym) then begin Finish(r); Exit; end;
    end;
end;

procedure Recompute(var r: TRx);
var d: Int64; m: Integer; a, b: LongInt;
begin
  r.P := 0; r.E1 := 0; r.E2 := 0;
  d := r.t - 2 * r.lag + 1;
  for m := 0 to r.lag - 1 do
  begin
    a := r.fb[(d + m) and RMASK]; b := r.fb[(d + m + r.lag) and RMASK];
    r.P := r.P + a * b; r.E1 := r.E1 + a * a; r.E2 := r.E2 + b * b;
  end;
end;

procedure RxPush(var r: TRx; const x: array of SmallInt; off, n: Integer);
var i, j, k: Integer; v, f, a, o, mt, m32, p32: LongInt; d, e, mx, pp: Int64; el: LongInt;
begin
  for i := 0 to n - 1 do
  begin
    v := x[off + i];
    k := r.t and RMASK;
    r.buf[k] := v;
    f := v;
    for j := 0 to r.npre - 1 do f := BqRun(r.pre[j], f);
    if f > 32767 then f := 32767 else if f < -32767 then f := -32767;
    r.fb[k] := f;
    a := r.fb[(r.t - r.lag) and RMASK]; o := r.fb[(r.t - 2 * r.lag) and RMASK];
    r.P := r.P + a * f - o * a;           { each product fits 32 bits, their difference may not }
    r.E2 := r.E2 + f * f - a * a;
    r.E1 := r.E1 + a * a - o * o;
    Inc(r.resum);
    if r.resum >= 8192 then begin r.resum := 0; Recompute(r); end;
    { the metric and the energy, every DECIM samples (the processor of a handheld has no time for more) }
    if ((r.t and (DECIM - 1)) = 0) and (r.t >= 2 * r.lag) then
    begin
      d := r.t - 2 * r.lag + 1;
      e := r.E2; if e < 0 then e := 0;
      mx := r.E1; if e > mx then mx := e;
      pp := r.P;
      if (pp <= 0) or (mx < 1) then mt := 0
      else
      begin
        { P / max(E1, E2) in 1/4096, with both scaled down to 32-bit numbers first }
        while mx >= (Int64(1) shl 19) do begin mx := mx shr 2; pp := pp shr 2; end;
        m32 := mx; p32 := pp;
        if m32 < 1 then m32 := 1;
        mt := (p32 * 4096) div m32;
        if mt > 4096 then mt := 4096;
      end;
      el := e shr r.lagShift;
      for j := 0 to DECIM - 1 do
      begin
        r.metric[(d - j) and RMASK] := mt;
        r.energy[(d - j) and RMASK] := el;
      end;
    end;
    Inc(r.t);
    if (r.t and (DECIM - 1)) = 0 then StepRx(r);
  end;
end;

end.
