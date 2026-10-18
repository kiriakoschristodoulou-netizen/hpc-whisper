unit wtone;
{ Whisper Tools: tones down (3.9.2). The phone's way of reaching the handheld that does not depend on the
  modem: 16 tones, 100 Hz apart, from 17.8 to 19.3 kHz (inside the codec's flat range), one tone a symbol, 4 bits
  a symbol, 30 ms a symbol. A frame is a PILOT of 8 symbols (a steady 18.5 kHz), a preamble of 8 symbols, then the
  coded header and message of format 3 (docs/FORMAT3.md, section 9) a nibble at a time, scrambled as on the silent
  channel down.

  The receiver works on a narrow band: the sound is mixed with 18.5 kHz and added up 16 samples at a time, which gives
  a complex signal of 3,200 samples/s that holds 16.9 - 20.1 kHz (a tenth of the work of 3.9.1, which multiplied the
  full rate by every tone). Always: 25 bins 100 Hz apart look at that signal, and the pilot shows as one steady bin
  for a quarter of a second. It is then measured finely, over 150 ms: its pitch says how far the microphone's rate
  is off (the phone's clock is right to 0.004 %), up to 4 % either way. The tones of the frame are then looked for
  where that puts them, and a symbol's length follows the same rate. The measurement is passed on (EpsPpm) so that the
  microphone's rate can be set from it.

  No floating point. It works on the same 51,200 samples/s the modem receivers get. }
{$mode objfpc}{$H+}{$Q-}{$R-}
interface

uses w3core, w3dsp, w3rx;

const
  TD_CH = 5;                            { its channel number in the handheld's messages }
  TD_NT = 16;                           { tones }
  TD_FIRST = 178;                       { the first tone, in hundreds of Hz: 17.8 kHz }
  TD_PILOT = 7;                         { the pilot is tone 7: 18.5 kHz }
  TD_PILOT_N = 8;                       { symbols of pilot }
  TD_BB = 16;                           { samples to a baseband sample (3,200/s) }
  TD_BLK = 8;                           { baseband samples in a block (2.5 ms) }
  TD_BPS = 12;                          { blocks in a symbol: 96 baseband samples, 30 ms }
  TD_SYMBB = 96;
  TD_NB = 25;                           { bins that look for the pilot: 18.5 kHz -1.2 .. +1.2 kHz }
  TD_PRE = 8;                           { symbols in the preamble }
  TD_MAXMSG = 60;                       { longest message }
  TD_RING = 256;                        { blocks kept }
  TD_BBR = 8192;                        { baseband samples kept }
  TD_PREAMBLE: array[0..TD_PRE - 1] of Byte = (2, 13, 2, 13, 9, 6, 9, 6);

type
  TTdRx = record
    hx1, hx2, hy1, hy2: LongInt;                       { the high-pass filter's memory }
    mixIx: Integer;                                    { the 18.5 kHz oscillator, 0..511 }
    fill: Integer;                                     { samples in this baseband sample so far }
    accR, accI: LongInt;
    bbr, bbi: array[0..TD_BBR - 1] of LongInt;         { the baseband signal }
    nbb: Int64;                                        { baseband samples made }
    ph: array[0..TD_NB - 1] of Integer;                { the bins' phases, 0..511 }
    acr, aci: array[0..TD_NB - 1] of LongInt;          { this block's sums so far }
    bfill: Integer;
    bi: Int64;                                         { blocks completed }
    cr, ci: array[0..TD_RING - 1, 0..TD_NB - 1] of LongInt;   { running sums after each block (wrap-around is fine: only differences count) }
    state: Integer;                                    { 0 = looking for a pilot, 1 = waiting for its end, 2 = for the preamble, 3 = reading }
    holdOff: Int64;                                    { no new pilot before this block }
    { the pilot that was found }
    epsPpm: Integer;                                   { how far the sound is stretched (+: apparent frequencies are too high) }
    refPw: Int64; lowRun: Integer; waited: Integer;
    pilotEnd: Int64;                                   { baseband sample where the pilot ended }
    pilotD: Int64;                                     { the pilot's pitch, milli-Hz from 18.5 kHz }
    stepQ: array[0..TD_NT - 1] of LongWord;            { the tones' phase steps per baseband sample (2^32 = a turn) }
    l16: Int64;                                        { a symbol's length in baseband samples, x 65536 }
    s0: Int64;                                         { baseband sample of the frame's first preamble symbol }
    nsym: Integer;                                     { symbols of the frame read (the preamble included) }
    bytes: array[0..8 + 400] of Byte;
    nb: Integer; nib: Integer;                         { bytes complete; a half byte waiting (-1 = none) }
    typ, len, total: Integer;                          { from the header; total = bytes in all }
    snrSum: Int64; snrN: Integer;
    q: array[0..3] of TRxMsg;
    qHead, qTail: Integer;
    starts, hdrs, frames, fails: Integer;              { for the log }
    pilots: Integer;                                   { pilots found (starts = those whose preamble also fitted) }
    gotEps: Boolean; goodEps: Integer;                 { a frame was read: its pilot's measurement is fresh (EpsPpm), and how many times }
    lastWhy: string;
  end;

procedure TdInit(var r: TTdRx);
procedure TdPush(var r: TTdRx; const x: array of SmallInt; off, n: Integer);
function TdTake(var r: TTdRx; var m: TRxMsg): Boolean;
function TdBusy(const r: TTdRx): Boolean;

implementation

var
  CosT, SinT: array[0..511] of SmallInt;               { Q9 }
  TabOk: Boolean = False;

procedure MakeTables;
var i: Integer;
begin
  for i := 0 to 511 do
  begin
    CosT[i] := CosI(i * 128) div 32;
    SinT[i] := SinI(i * 128) div 32;
  end;
  TabOk := True;
end;

procedure TdInit(var r: TTdRx);
var j: Integer;
begin
  if not TabOk then MakeTables;
  FillChar(r, SizeOf(r), 0);
  for j := 0 to TD_NB - 1 do r.ph[j] := 0;
  r.nib := -1;
  r.lastWhy := '';
end;

function TdBusy(const r: TTdRx): Boolean;
begin
  Result := r.state >= 2;
end;

function TdTake(var r: TTdRx; var m: TRxMsg): Boolean;
begin
  Result := r.qHead <> r.qTail;
  if Result then begin m := r.q[r.qTail]; r.qTail := (r.qTail + 1) and 3; end;
end;

const
  MINTOT = Int64(1) shl 40;                           { less than this in a window is silence (a tone of about 20 units) }

{ energies of the bins in the 12 blocks s .. s + 11 }
procedure BinEnergy(var r: TTdRx; s: Int64; var e: array of Int64);
var k, a, b: Integer; dr, di: LongInt;
begin
  a := s and (TD_RING - 1); b := (s + TD_BPS) and (TD_RING - 1);
  for k := 0 to TD_NB - 1 do
  begin
    dr := r.cr[b, k] - r.cr[a, k]; di := r.ci[b, k] - r.ci[a, k];
    e[k] := Int64(dr) * dr + Int64(di) * di;
  end;
end;

procedure Idle(var r: TTdRx; why: string);
begin
  r.state := 0; r.lastWhy := why;
end;

procedure Fail(var r: TTdRx; why: string);
begin
  Inc(r.fails);
  r.holdOff := r.bi + (TD_PILOT_N + TD_PRE) * TD_BPS;
  Idle(r, why);
end;

{ the strongest bin and whether it, with its stronger neighbour, holds most of the window: a steady tone (the pilot) }
function PilotWindow(var r: TTdRx; s: Int64; out jc: Integer): Boolean;
var e: array[0..TD_NB - 1] of Int64; k, best, nb: Integer; tot: Int64;
begin
  BinEnergy(r, s, e);
  best := 0; tot := 0;
  for k := 0 to TD_NB - 1 do
  begin
    tot := tot + e[k];
    if e[k] > e[best] then best := k;
  end;
  jc := best;
  Result := False;
  if tot < MINTOT then Exit;
  nb := best;
  if (best > 0) and ((best = TD_NB - 1) or (e[best - 1] >= e[best + 1])) then nb := best - 1
  else if best < TD_NB - 1 then nb := best + 1;
  Result := ((e[best] + e[nb]) shr 8) * 100 > (tot shr 8) * 60;        { (shifted: the energies of a loud tone are near the top of 64 bits) }
  if Result then jc := best * 2 + (nb - best);           { half bins: the pair's centre }
end;

{ the correlation of the baseband samples a .. a + n - 1 with a tone of the phase step st (starting at phase 0) }
procedure Correlate(var r: TTdRx; a: Int64; n: Integer; st: LongWord; out zr, zi: Int64);
var i, ix: Integer; p: LongWord; br, bq: LongInt; c, s: LongInt; sr, si: Int64; k: Integer;
begin
  sr := 0; si := 0; p := 0;
  for i := 0 to n - 1 do
  begin
    k := (a + i) and (TD_BBR - 1);
    br := r.bbr[k]; bq := r.bbi[k];
    ix := p shr 23;
    c := CosT[ix]; s := SinT[ix];
    sr := sr + br * c + bq * s;
    si := si + bq * c - br * s;
    p := p + st;
  end;
  zr := sr; zi := si;
end;

function StepOf(dMilli: Int64): LongWord;
var v: Int64;
begin
  v := (dMilli * 4294967296) div 3200000;
  Result := LongWord(v and $FFFFFFFF);
end;

{ the pilot over the last 60 blocks, near the offset dcMilli (milli-Hz from 18.5 kHz): where exactly it is, and how much
  of the band's energy it holds (1000 = all) }
function PilotFine(var r: TTdRx; dcMilli: Int64; out dMilli: Int64; out conc: Integer): Boolean;
const NP = 37; N = 480;
var i, im: Integer; zr, zi: Int64; m: array[0..NP - 1] of LongInt; a: Int64; tot, pk: Int64; k: Integer; ar, ai: Int64;
    ym, y0, yp, den: Int64;
begin
  Result := False; dMilli := 0; conc := 0;
  a := r.nbb - N;
  im := 0;
  for i := 0 to NP - 1 do
  begin
    Correlate(r, a, N, StepOf(dcMilli + Int64(i - 18) * 4000), zr, zi);
    m[i] := MagI(LongInt(zr div 256), LongInt(zi div 256));
    if m[i] > m[im] then im := i;
  end;
  if (im = 0) or (im = NP - 1) then Exit;
  ym := m[im - 1]; y0 := m[im]; yp := m[im + 1];
  den := ym - 2 * y0 + yp;
  dMilli := dcMilli + Int64(im - 18) * 4000;
  if den < 0 then dMilli := dMilli + (4000 * (ym - yp)) div (2 * den);
  { the energy it holds, of everything in the band over the same samples }
  Correlate(r, a, N, StepOf(dMilli), zr, zi);
  tot := 0;
  for i := 0 to N - 1 do
  begin
    k := (a + i) and (TD_BBR - 1);
    tot := tot + Int64(r.bbr[k]) * r.bbr[k] + Int64(r.bbi[k]) * r.bbi[k];
  end;
  if tot < 1 then Exit;
  ar := zr div 1024; ai := zi div 1024;
  pk := (ar * ar + ai * ai) * 4000;
  conc := Integer(pk div (Int64(N) * (tot div 1)));
  if conc > 1000 then conc := 1000;
  Result := True;
end;

{ the apparent offset (milli-Hz from 18.5 kHz) of tone k when the sound is stretched by eps ppm }
function ToneOffset(k, eps: Integer): Int64;
begin
  Result := Int64(-700 + 100 * k) * 1000 + (Int64(17800 + 100 * k) * eps) div 1000;
end;

{ the energies of the tones in symbol j of the frame whose preamble starts at baseband sample s0: its window follows the
  stretch of the sound; the energy is at the scale of a window of 96 whatever its length }
procedure SymEnergy(var r: TTdRx; s0: Int64; j: Integer; var e: array of Int64);
var k, n: Integer; x0, x1: Int64; zr, zi: Int64;
begin
  x0 := ((s0 shl 16) + Int64(j) * r.l16 + 32768) shr 16;
  x1 := ((s0 shl 16) + Int64(j + 1) * r.l16 + 32768) shr 16;
  n := Integer(x1 - x0);
  for k := 0 to TD_NT - 1 do
  begin
    Correlate(r, x0, n, r.stepQ[k], zr, zi);
    zr := zr * TD_SYMBB div n; zi := zi * TD_SYMBB div n;
    e[k] := zr * zr + zi * zi;
  end;
end;

function PreambleScore(var r: TTdRx; s0: Int64; out hits: Integer): Int64;
var i, k, x: Integer; e: array[0..TD_NT - 1] of Int64; tot: Int64;
begin
  hits := 0; Result := 0;
  for i := 0 to TD_PRE - 1 do
  begin
    SymEnergy(r, s0, i, e);
    tot := 0;
    for k := 0 to TD_NT - 1 do tot := tot + e[k];
    x := TD_PREAMBLE[i];
    if (tot >= MINTOT) and (e[x] * 2 > tot) then
    begin
      Inc(hits);
      Result := Result + ((e[x] shr 12) * 256) div ((tot shr 12) + 1);
    end;
  end;
end;

procedure Done(var r: TTdRx);
var coded: array[0..399] of Byte; i, fixed: Integer; ok: Boolean; h: ^TRxMsg;
begin
  for i := 0 to r.total - 9 - 1 do coded[i] := r.bytes[9 + i];
  Scramble(coded, r.total - 9, CH_SD);
  h := @r.q[r.qHead];
  ok := PayloadDecode(coded, r.len, h^.data, fixed);
  if not ok then begin Fail(r, 'message'); Exit; end;
  h^.typ := r.typ; h^.len := r.len; h^.fixed := fixed;
  if r.snrN > 0 then h^.snr10 := Integer(r.snrSum div r.snrN) else h^.snr10 := 0;
  r.qHead := (r.qHead + 1) and 3;
  if r.qHead = r.qTail then r.qTail := (r.qTail + 1) and 3;
  Inc(r.frames);
  r.gotEps := True; Inc(r.goodEps);
  r.holdOff := r.bi + 2 * TD_BPS;
  Idle(r, '');
end;

{ one symbol of the frame has ended: its tone is a nibble }
procedure ReadSymbol(var r: TTdRx);
var e: array[0..TD_NT - 1] of Int64; k, best, db: Integer; tot, rest: Int64; h: array[0..HDR_CODED - 1] of Byte;
    typ, len, map, i: Integer;
begin
  SymEnergy(r, r.s0, r.nsym, e);
  best := 0; tot := 0;
  for k := 0 to TD_NT - 1 do
  begin
    tot := tot + e[k];
    if e[k] > e[best] then best := k;
  end;
  rest := tot - e[best];
  if rest < 1 then rest := 1;
  { quality: the loudest tone against all the others, in tenths of a dB (capped) }
  db := Db100(((e[best] shr 10) * 16) div ((rest shr 10) + 1) + 1) div 10 - 12;
  if db > 400 then db := 400;
  r.snrSum := r.snrSum + db; Inc(r.snrN);
  Inc(r.nsym);
  if r.nib < 0 then r.nib := best
  else
  begin
    r.bytes[r.nb] := (r.nib shl 4) or best; Inc(r.nb); r.nib := -1;
  end;
  if (r.nb = HDR_CODED) and (r.total = 0) then
  begin
    for i := 0 to HDR_CODED - 1 do h[i] := r.bytes[i];
    Scramble(h, HDR_CODED, CH_SD);
    if not HeaderDecode(h, typ, len, map) then begin Fail(r, 'header'); Exit; end;
    if len > TD_MAXMSG then begin Fail(r, 'length'); Exit; end;
    r.typ := typ; r.len := len;
    r.total := HDR_CODED + CodedLength(len);
    Inc(r.hdrs);
  end;
  if (r.total > 0) and (r.nb >= r.total) then Done(r);
end;

{ the energy of the pilot (at its measured pitch) in the block that ended at baseband sample e }
function PilotBlock(var r: TTdRx; dMilli: Int64; e: Int64): Int64;
var zr, zi, ar, ai: Int64;
begin
  Correlate(r, e - TD_BLK, TD_BLK, StepOf(dMilli), zr, zi);
  ar := zr div 64; ai := zi div 64;
  Result := ar * ar + ai * ai;
end;

procedure Block(var r: TTdRx);
var b, s, j, jj, w, hits, k, ok, ref, o, bestO, bh: Integer; jc: array[0..5] of Integer; i: Integer;
    dMilli, dcMilli, bestSc, sc: Int64; conc: Integer; x: Int64;
begin
  { the sums so far, after this block }
  b := r.bi and (TD_RING - 1);
  Inc(r.bi);
  s := r.bi and (TD_RING - 1);
  for k := 0 to TD_NB - 1 do
  begin
    r.cr[s, k] := r.cr[b, k] + r.acr[k]; r.ci[s, k] := r.ci[b, k] + r.aci[k];
    r.acr[k] := 0; r.aci[k] := 0;
  end;
  case r.state of
    0: if (r.bi >= 6 * TD_BPS) and (r.bi >= r.holdOff) then
       begin
         if not PilotWindow(r, r.bi - TD_BPS, jc[0]) then Exit;
         ok := 1;
         for w := 1 to 5 do
           if PilotWindow(r, r.bi - TD_BPS * (w + 1), jc[w]) then
           begin
             if Abs(jc[w] - jc[0]) <= 2 then Inc(ok);
           end
           else jc[w] := -100;
         if ok < 5 then Exit;
         { a steady tone for most of a quarter of a second: measure it }
         Inc(r.pilots);
         dcMilli := Int64(jc[0]) * 50000 - 1200000;            { jc is in half bins from the lowest, which is -1200 Hz }
         if not PilotFine(r, dcMilli, dMilli, conc) or (conc < 600) then begin Fail(r, 'pilot'); Exit; end;
         r.epsPpm := Integer((dMilli * 2) div 37);             { d / 18.5 kHz in ppm: milli-Hz x 1000 / 18,500,000 }
         if Abs(r.epsPpm) > 40000 then begin Fail(r, 'rate'); Exit; end;
         for k := 0 to TD_NT - 1 do r.stepQ[k] := StepOf(ToneOffset(k, r.epsPpm));
         r.l16 := (Int64(TD_SYMBB) shl 16) * 1000000 div (1000000 + r.epsPpm);
         { how strong the pilot is, block by block, over the last 40 blocks }
         x := 0;
         for i := 20 to 60 do x := x + PilotBlock(r, dMilli, r.nbb - Int64(i - 1) * TD_BLK);
         r.refPw := x div 41;
         r.lowRun := 0;
         for i := 1 to 19 do
           if PilotBlock(r, dMilli, r.nbb - Int64(i - 1) * TD_BLK) * 4 < r.refPw then Inc(r.lowRun) else Break;
         r.pilotEnd := 0; r.waited := 0;
         r.pilotD := dMilli;
         r.state := 1;
       end;
    1: begin
         if PilotBlock(r, r.pilotD, r.nbb) * 4 < r.refPw then Inc(r.lowRun) else r.lowRun := 0;
         Inc(r.waited);
         if r.lowRun >= 3 then
         begin
           r.pilotEnd := r.nbb - Int64(r.lowRun) * TD_BLK;
           r.state := 2;
         end
         else if r.waited > 70 then Fail(r, 'pilot long');
       end;
    2: begin
         { wait for the whole preamble to be in, with a margin for the search }
         if r.nbb >= r.pilotEnd + Int64(TD_PRE) * ((r.l16 + 65535) shr 16) + 40 then
         begin
           bestSc := -1; bestO := 0; bh := 0;
           o := -14;
           while o <= 14 do
           begin
             sc := PreambleScore(r, r.pilotEnd + o, hits);
             if (hits >= 7) and (sc > bestSc) then begin bestSc := sc; bestO := o; bh := hits; end;
             Inc(o, 2);
           end;
           if bestSc < 0 then begin Fail(r, 'preamble'); Exit; end;
           for o := bestO - 1 to bestO + 1 do
           begin
             if o = bestO then Continue;
             sc := PreambleScore(r, r.pilotEnd + o, hits);
             if (hits >= 7) and (sc > bestSc) then begin bestSc := sc; bestO := o; bh := hits; end;
           end;
           r.s0 := r.pilotEnd + bestO;
           r.state := 3; r.nsym := TD_PRE; r.nb := 0; r.nib := -1; r.total := 0;
           r.snrSum := 0; r.snrN := 0;
           Inc(r.starts);
         end;
       end;
    3: begin
         while r.state = 3 do
         begin
           x := ((r.s0 shl 16) + Int64(r.nsym + 1) * r.l16 + 32768) shr 16;
           if r.nbb < x + 2 then Break;
           ReadSymbol(r);
           if (r.state = 3) and (r.nb > 8 + 400) then Fail(r, 'long');
         end;
       end;
  end;
end;

procedure TdPush(var r: TTdRx; const x: array of SmallInt; off, n: Integer);
var i, j, k, ix, ixm: Integer; br, bq: LongInt; v, y: LongInt; c, s: LongInt;
begin
  ixm := r.mixIx;
  for i := 0 to n - 1 do
  begin
    { a high-pass filter first (2nd order, 14 kHz, Q14): the microphone's constant offset (about 850 of 32,768 on the
      Jornada) would turn into a steady tone in the narrow band, and so would a loud low tone (Pair's 2 kHz beep) }
    v := x[off + i] div 8;
    y := (4113 * (v + r.hx2) - 8226 * r.hx1 - 2829 * r.hy1 - 2897 * r.hy2) div 16384;
    r.hx2 := r.hx1; r.hx1 := v; r.hy2 := r.hy1; r.hy1 := y;
    v := y;
    ixm := (ixm + 185) and 511;
    r.accR := r.accR + v * CosT[ixm];
    r.accI := r.accI - v * SinT[ixm];
    Inc(r.fill);
    if r.fill >= TD_BB then
    begin
      r.fill := 0;
      br := SarLongint(r.accR, 9); bq := SarLongint(r.accI, 9);
      r.accR := 0; r.accI := 0;
      k := r.nbb and (TD_BBR - 1);
      r.bbr[k] := br; r.bbi[k] := bq;
      Inc(r.nbb);
      { the bins }
      for j := 0 to TD_NB - 1 do
      begin
        ix := r.ph[j];
        c := CosT[ix]; s := SinT[ix];
        r.acr[j] := r.acr[j] + br * c + bq * s;
        r.aci[j] := r.aci[j] + bq * c - br * s;
        r.ph[j] := (ix + 16 * (j - 12)) and 511;
      end;
      Inc(r.bfill);
      if r.bfill >= TD_BLK then begin r.bfill := 0; Block(r); end;
    end;
  end;
  r.mixIx := ixm;
end;

end.
