unit wtone;
{ Whisper Tools: tones down (3.9.1). The phone's way of reaching the handheld that does not depend on the
  modem: 16 tones, 100 Hz apart, from 17.8 to 19.3 kHz (inside the codec's flat range), one tone a symbol, 4 bits
  a symbol, 30 ms a symbol. A frame is a preamble of 8 symbols, then the coded header and message of format 3
  (docs/FORMAT3.md, section 9) a nibble at a time, scrambled as on the silent channel down.

  The receiver is the cheapest one there is: for every tone, the sound is multiplied by a sine and a cosine of
  the tone (tables of 512 steps) and added up over blocks of 128 samples; a symbol is twelve blocks, and
  the energy of a tone in it comes from the sums of those blocks. No floating point, no search for a rate:
  at 100 ppm the tones do not move out of their symbol in a frame's time.

  It works on the same 51,200 samples/s the modem receivers get. }
{$mode objfpc}{$H+}{$Q-}{$R-}
interface

uses w3core, w3dsp, w3rx;

const
  TD_CH = 5;                            { its channel number in the handheld's messages }
  TD_NT = 16;                           { tones }
  TD_FIRST = 178;                       { the first tone, in hundreds of Hz: 17.8 kHz }
  TD_BLK = 128;                         { samples in a block }
  TD_BPS = 12;                          { blocks in a symbol: 1536 samples, 30 ms }
  TD_PRE = 8;                           { symbols in the preamble }
  TD_MAXMSG = 60;                       { longest message }
  TD_RING = 256;                        { blocks kept }
  TD_PREAMBLE: array[0..TD_PRE - 1] of Byte = (2, 13, 2, 13, 9, 6, 9, 6);

type
  TTdRx = record
    ph: array[0..TD_NT - 1] of Integer;               { the tone's phase step, 0..511 }
    acr, aci: array[0..TD_NT - 1] of LongInt;         { this block's sums so far }
    fill: Integer;                                     { samples in this block so far }
    bi: Int64;                                         { blocks completed }
    cr, ci: array[0..TD_RING - 1, 0..TD_NT - 1] of LongInt;   { running sums after each block (wrap-around is fine: only differences count) }
    state: Integer;                                    { 0 = looking for a preamble, 1 = fixing its place, 2 = reading }
    s0: Int64;                                         { first block of the frame }
    seekEnd: Int64; bestSc: Int64; bestS: Int64;
    holdOff: Int64;                                    { no new start before this block }
    nsym: Integer;                                     { symbols read }
    bytes: array[0..8 + 400] of Byte;
    nb: Integer; nib: Integer;                         { bytes complete; a half byte waiting (-1 = none) }
    typ, len, total: Integer;                          { from the header; total = bytes in all }
    snrSum: Int64; snrN: Integer;
    q: array[0..3] of TRxMsg;
    qHead, qTail: Integer;
    starts, hdrs, frames, fails: Integer;              { for the log }
    lastLevelDb: Integer;                              { the loudest tone of the last start, in dB (re 1 unit) }
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
var k: Integer;
begin
  if not TabOk then MakeTables;
  FillChar(r, SizeOf(r), 0);
  for k := 0 to TD_NT - 1 do r.ph[k] := 0;
  r.nib := -1;
  r.lastWhy := '';
end;

function TdBusy(const r: TTdRx): Boolean;
begin
  Result := r.state = 2;
end;

function TdTake(var r: TTdRx; var m: TRxMsg): Boolean;
begin
  Result := r.qHead <> r.qTail;
  if Result then begin m := r.q[r.qTail]; r.qTail := (r.qTail + 1) and 3; end;
end;

{ energies of the tones in the symbol of blocks s .. s + TD_BPS - 1 }
procedure SymEnergy(var r: TTdRx; s: Int64; var e: array of Int64);
var k, a, b: Integer; dr, di: LongInt;
begin
  a := s and (TD_RING - 1); b := (s + TD_BPS) and (TD_RING - 1);
  for k := 0 to TD_NT - 1 do
  begin
    dr := r.cr[b, k] - r.cr[a, k]; di := r.ci[b, k] - r.ci[a, k];
    e[k] := Int64(dr) * dr + Int64(di) * di;
  end;
end;

procedure Idle(var r: TTdRx; why: string);
begin
  r.state := 0; r.lastWhy := why;
end;

const
  MINTOT = Int64(1) shl 36;                           { less than this in a symbol is silence }

{ how well the preamble fits the 8 symbols ending at block count bi; hits = symbols whose tone is the one
  and clearly the loudest; returns a score (hits weighted by how much of the energy the right tone holds) }
function PreambleScore(var r: TTdRx; s: Int64; out hits: Integer): Int64;
var i, k, x: Integer; e: array[0..TD_NT - 1] of Int64; tot: Int64;
begin
  hits := 0; Result := 0;
  for i := 0 to TD_PRE - 1 do
  begin
    SymEnergy(r, s + Int64(i) * TD_BPS, e);
    tot := 0;
    for k := 0 to TD_NT - 1 do tot := tot + e[k];
    x := TD_PREAMBLE[i];
    if (tot >= MINTOT) and (e[x] * 2 > tot) then
    begin
      Inc(hits);
      Result := Result + (e[x] * 256) div tot;
    end;
  end;
end;

procedure Fail(var r: TTdRx; why: string);
begin
  Inc(r.fails);
  r.holdOff := r.bi + TD_PRE * TD_BPS;
  Idle(r, why);
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
  r.holdOff := r.bi + 2 * TD_BPS;
  Idle(r, '');
end;

{ one symbol of the frame has ended: its tone is a nibble }
procedure ReadSymbol(var r: TTdRx; s: Int64);
var e: array[0..TD_NT - 1] of Int64; k, best, db: Integer; tot, rest: Int64; h: array[0..HDR_CODED - 1] of Byte;
    typ, len, map, i: Integer;
begin
  SymEnergy(r, s, e);
  best := 0; tot := 0;
  for k := 0 to TD_NT - 1 do
  begin
    tot := tot + e[k];
    if e[k] > e[best] then best := k;
  end;
  rest := tot - e[best];
  if rest < 1 then rest := 1;
  { quality: the loudest tone against all the others, in tenths of a dB (capped) }
  db := Db100((e[best] * 16) div rest + 1) div 10 - 12;
  if db > 400 then db := 400;
  r.snrSum := r.snrSum + db; Inc(r.snrN);
  if r.nib < 0 then r.nib := best
  else
  begin
    r.bytes[r.nb] := (r.nib shl 4) or best; Inc(r.nb); r.nib := -1;
  end;
  Inc(r.nsym);
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

procedure Block(var r: TTdRx);
var b, hits, k: Integer; sc, s: Int64;
begin
  { the sums so far, after this block }
  b := r.bi and (TD_RING - 1);
  Inc(r.bi);
  s := r.bi and (TD_RING - 1);
  { r.cr[s] = r.cr[b] + this block's sums }
  for k := 0 to TD_NT - 1 do
  begin
    r.cr[s, k] := r.cr[b, k] + r.acr[k]; r.ci[s, k] := r.ci[b, k] + r.aci[k];
    r.acr[k] := 0; r.aci[k] := 0;
  end;
  case r.state of
    0: if (r.bi >= TD_PRE * TD_BPS) and (r.bi >= r.holdOff) then
       begin
         sc := PreambleScore(r, r.bi - TD_PRE * TD_BPS, hits);
         if hits >= 7 then
         begin
           r.state := 1; r.seekEnd := r.bi + 14; r.bestSc := sc; r.bestS := r.bi - TD_PRE * TD_BPS;
           Inc(r.starts);
         end;
       end;
    1: begin
         sc := PreambleScore(r, r.bi - TD_PRE * TD_BPS, hits);
         if (hits >= 7) and (sc > r.bestSc) then begin r.bestSc := sc; r.bestS := r.bi - TD_PRE * TD_BPS; end;
         if r.bi >= r.seekEnd then
         begin
           r.s0 := r.bestS; r.state := 2; r.nsym := 0; r.nb := 0; r.nib := -1; r.total := 0;
           r.snrSum := 0; r.snrN := 0;
         end;
       end;
    2: while (r.state = 2) and (r.bi >= r.s0 + Int64(r.nsym + 1) * TD_BPS) do
       begin
         if r.nsym >= TD_PRE then ReadSymbol(r, r.s0 + Int64(r.nsym) * TD_BPS)
         else Inc(r.nsym);
         if (r.state = 2) and (r.nb > 8 + 400) then Fail(r, 'long');
       end;
  end;
end;

procedure TdPush(var r: TTdRx; const x: array of SmallInt; off, n: Integer);
var run, k, i, ix, m: Integer; ar, ai: LongInt; xs: array[0..TD_BLK - 1] of LongInt; v: LongInt;
begin
  while n > 0 do
  begin
    run := TD_BLK - r.fill;
    if run > n then run := n;
    for i := 0 to run - 1 do xs[i] := x[off + i] div 8;
    for k := 0 to TD_NT - 1 do
    begin
      m := TD_FIRST + k; ix := r.ph[k]; ar := r.acr[k]; ai := r.aci[k];
      i := 0;
      while i + 1 < run do                           { two samples a turn: less loop work for the same sums }
      begin
        v := xs[i];
        ar := ar + v * CosT[ix];
        ai := ai + v * SinT[ix];
        ix := (ix + m) and 511;
        v := xs[i + 1];
        ar := ar + v * CosT[ix];
        ai := ai + v * SinT[ix];
        ix := (ix + m) and 511;
        Inc(i, 2);
      end;
      if i < run then
      begin
        v := xs[i];
        ar := ar + v * CosT[ix];
        ai := ai + v * SinT[ix];
        ix := (ix + m) and 511;
      end;
      r.ph[k] := ix; r.acr[k] := ar; r.aci[k] := ai;
    end;
    Inc(r.fill, run); Inc(off, run); Dec(n, run);
    if r.fill >= TD_BLK then begin r.fill := 0; Block(r); end;
  end;
end;

end.
