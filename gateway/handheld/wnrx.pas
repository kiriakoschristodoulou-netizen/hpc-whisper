unit wnrx;
{ Whisper Net: the handheld's receiver for the phone's stream frames (frame
  version 3, NET-PROTOCOL.md), one band and one symbol length.

  The ackrx approach, for whole frames: every sample goes into running sums
  for the band's 16 tones; a block of about 1 ms (rate div 1000 samples) is
  kept per tone in a ring of 8192 blocks (8 s: the longest frame is 3.46 s at
  20 ms a symbol, 5.5 s at 32 ms). The preamble is looked for every 2 blocks;
  a frame found is read as soon as enough of it has been heard for each
  possible size, 1 to 10 body blocks, smallest first. The band's loudness is
  followed too, so the turn logic can tell sound from quiet.

  Whole numbers only, fixed arrays only (no heap): it runs in a CreateThread
  thread on the handheld. Also built for Linux by the tests. }
{$mode objfpc}{$R-}{$Q-}
interface
uses wnframe;

const
  NRING = 8192;
  RXQ = 8;

type
  TNetRx = record
    rate, bandHz, symMs: Integer;
    blk: Integer;                      { samples per block }
    ds16: LongInt;                     { blocks per symbol x 16 }
    nblk: LongInt;                     { blocks done }
    inBlk: Integer;
    ph, st: array[0..15] of LongWord;
    accRe, accIm: array[0..15] of LongInt;
    re, im: array[0..NRING - 1, 0..15] of LongInt;
    dc: LongInt;
    pAvg: Int64;                       { band power, averaged over a few blocks }
    floor: Int64;                      { quiet level of the band power }
    lastLoud: LongInt;                 { last block clearly above the quiet level }
    { the frame being looked for / read }
    candS, candSc, candAge: LongInt;
    pendS: LongInt;                    { start (block) of a frame being read; -1 none }
    pendB: Integer;                    { next size to try }
    pendSc: LongInt;                   { its preamble's score }
    doneUntil: LongInt;                { frames already read end here: no new preamble before }
    { frames read, waiting to be taken }
    q: array[0..RXQ - 1] of TNetFrame;
    qn: Integer;
    framesRead, unreadable, corrected: LongInt;
  end;

procedure NrInit(var r: TNetRx; rate, bandHz, symMs: Integer);
procedure NrReset(var r: TNetRx);        { forget what was heard (after the microphone was closed) }
procedure NrPush(var r: TNetRx; const x: array of SmallInt; n: Integer);
function NrTake(var r: TNetRx; var f: TNetFrame): Boolean;
{ blocks since the band was last clearly louder than its quiet level }
function NrQuietFor(const r: TNetRx): LongInt;
function NrReading(const r: TNetRx): Boolean;     { a frame has been found and is being read }

implementation

const
  TAB_N = 4096;
  TAB: array[0..TAB_N - 1] of SmallInt = (
{$I sine.inc}
  );

procedure NrReset(var r: TNetRx);
var t: Integer;
begin
  r.nblk := 0; r.inBlk := 0;
  for t := 0 to 15 do begin r.ph[t] := 0; r.accRe[t] := 0; r.accIm[t] := 0; end;
  r.candS := -1; r.candSc := 0; r.candAge := 0;
  r.pendS := -1; r.pendB := 1; r.pendSc := 0;
  r.doneUntil := 0;
  r.lastLoud := -100000;
  r.floor := 0; r.pAvg := 0;
  r.qn := 0;
end;

procedure NrInit(var r: TNetRx; rate, bandHz, symMs: Integer);
var t: Integer;
begin
  FillChar(r, SizeOf(r), 0);
  r.rate := rate; r.bandHz := bandHz; r.symMs := symMs;
  r.blk := rate div 1000;
  r.ds16 := (Int64(symMs) * rate * 16) div (1000 * r.blk);
  for t := 0 to 15 do r.st[t] := LongWord((Int64(bandHz + 100 * t) shl 32) div rate);
  NrReset(r);
end;

function NrTake(var r: TNetRx; var f: TNetFrame): Boolean;
var i: Integer;
begin
  Result := r.qn > 0;
  if not Result then Exit;
  f := r.q[0];
  for i := 1 to r.qn - 1 do r.q[i - 1] := r.q[i];
  Dec(r.qn);
end;

function NrQuietFor(const r: TNetRx): LongInt;
begin
  Result := r.nblk - r.lastLoud;
end;

function NrReading(const r: TNetRx): Boolean;
begin
  Result := r.pendS >= 0;
end;

{ power of tone t over blocks [a, b) }
function WinPow(var r: TNetRx; t: Integer; a, b: LongInt): Int64;
var i: LongInt; sr, si: Int64;
begin
  sr := 0; si := 0;
  for i := a to b - 1 do
  begin
    sr := sr + r.re[i and (NRING - 1), t];
    si := si + r.im[i and (NRING - 1), t];
  end;
  sr := sr div 256; si := si div 256;
  Result := sr * sr + si * si;
end;

{ symbol k of a frame whose preamble starts at block s: its window, 25 % to 90 % }
procedure SymWin(const r: TNetRx; s: LongInt; k: Integer; var a, b: LongInt);
begin
  a := s + (Int64(k) * r.ds16 + r.ds16 div 4) div 16;
  b := s + (Int64(k) * r.ds16 + (r.ds16 * 9) div 10) div 16;
  if b <= a then b := a + 1;
end;

{ the strongest tone of a window, and its share of the band (0..1000) }
procedure Strongest(var r: TNetRx; a, b: LongInt; var best: Integer; var share: Integer);
var t: Integer; pw, mx, tot: Int64;
begin
  mx := -1; tot := 0; best := 0;
  for t := 0 to 15 do
  begin
    pw := WinPow(r, t, a, b);
    tot := tot + pw;
    if pw > mx then begin mx := pw; best := t; end;
  end;
  if tot > 0 then share := Integer((mx * 1000) div tot) else share := 0;
end;

{ how well a preamble fits at block s: the sum of the expected tones' shares (0..8000); good = symbols where it is strongest }
function PreScore(var r: TNetRx; s: LongInt; var good: Integer): LongInt;
var k, t: Integer; a, b: LongInt; pw, tot, ex, mx: Int64;
begin
  Result := 0; good := 0;
  for k := 0 to 7 do
  begin
    SymWin(r, s, k, a, b);
    tot := 0; ex := 0; mx := 0;
    for t := 0 to 15 do
    begin
      pw := WinPow(r, t, a, b);
      tot := tot + pw;
      if pw > mx then mx := pw;
      if t = PREAMBLE[k] then ex := pw;
    end;
    if (ex > 0) and (ex >= mx) then Inc(good);
    if tot > 0 then Result := Result + LongInt((ex * 1000) div tot);
  end;
end;

{ read a frame of nb body blocks whose preamble starts at block s }
function TryRead(var r: TNetRx; s: LongInt; nb: Integer; var f: TNetFrame): Boolean;
var K, t, i, j, nd, fx, tmp, total: Integer; a, b: LongInt;
    w: array[0..NET_MAXB, 0..14] of Integer; conf: array[0..NET_MAXB, 0..14] of Integer;
    word, dat: array[0..14] of Integer; ord_: array[0..14] of Integer; er: array[0..3] of Integer;
    words: array[0..(NET_MAXB + 1) * 11 - 1] of Integer; best, share: Integer; ok: Boolean;
begin
  Result := False;
  K := nb + 1;
  for i := 0 to 3 do er[i] := 0;
  for t := 0 to K * 15 - 1 do
  begin
    SymWin(r, s, 8 + t, a, b);
    Strongest(r, a, b, best, share);
    w[t mod K, t div K] := best;
    conf[t mod K, t div K] := share;
  end;
  total := 0;
  for i := 0 to K - 1 do
  begin
    for j := 0 to 14 do word[j] := w[i, j];
    ok := RsDec(word, er, 0, dat, fx);
    if not ok then
    begin
      { the least certain symbols as erasures, one to four of them }
      for j := 0 to 14 do ord_[j] := j;
      for j := 1 to 14 do
      begin
        tmp := ord_[j]; t := j - 1;
        while (t >= 0) and (conf[i, ord_[t]] > conf[i, tmp]) do begin ord_[t + 1] := ord_[t]; Dec(t); end;
        ord_[t + 1] := tmp;
      end;
      for nd := 1 to 4 do
      begin
        for j := 0 to nd - 1 do er[j] := ord_[j];
        ok := RsDec(word, er, nd, dat, fx);
        if ok then Break;
      end;
    end;
    if not ok then Exit;
    total := total + fx;
    for j := 0 to 10 do words[i * 11 + j] := dat[j];
    { the header says the size: stop early when it is another one }
    if i = 0 then
      if (dat[0] <> NET_VERSION) or (NetBlocks(((dat[1] shl 4) or dat[2]) and 63) <> nb) then Exit;
  end;
  if not ParseNet(words, K, f) then Exit;
  f.fixed := total;
  f.endBlk := s + (Int64(8 + K * 15) * r.ds16) div 16;
  Result := True;
end;

procedure Search(var r: TNetRx);
var s, sc, best, bestS: LongInt; good, d: Integer;
begin
  { a preamble that has just ended: its start is 8 symbols back }
  s := r.nblk - (8 * r.ds16) div 16 - 1;
  if s < 2 then Exit;
  best := -1; bestS := s;
  if s > r.doneUntil then
    for d := -1 to 1 do
    begin
      sc := PreScore(r, s + d, good);
      {$ifdef DEBUGRX}if (good >= 5) and (sc >= 2000) then WriteLn('  cand ', s + d, ' sc ', sc, ' good ', good, ' done ', r.doneUntil, ' pend ', r.pendS);{$endif}
      if (good >= 6) and (sc >= 3000) and (sc > best) then begin best := sc; bestS := s + d; end;
    end;
  if best >= 0 then
  begin
    if (r.candS < 0) or (best >= r.candSc) then begin r.candS := bestS; r.candSc := best; r.candAge := 0; end
    else Inc(r.candAge);
  end
  else if r.candS >= 0 then Inc(r.candAge);
  if (r.candS >= 0) and (r.candS <= r.doneUntil) then begin r.candS := -1; r.candSc := 0; end;
  { the best start stopped improving: read that frame }
  if (r.candS >= 0) and (r.candAge >= 3) then
  begin
    if r.pendS < 0 then
    begin
      {$ifdef DEBUGRX}WriteLn('lock ', r.candS, ' score ', r.candSc, ' at ', r.nblk);{$endif}
      r.pendS := r.candS; r.pendB := 1; r.pendSc := r.candSc;
      r.candS := -1; r.candSc := 0; r.candAge := 0;
    end
    else if (Abs(r.candS - r.pendS) * 16 <= 3 * r.ds16) and (r.candSc > r.pendSc) then
    begin
      { a better preamble close to the one being read (the end of one frame and the start of the next can
        look like a preamble a symbol or two early): read this one instead }
      {$ifdef DEBUGRX}WriteLn('relock ', r.candS, ' score ', r.candSc, ' over ', r.pendS, ' at ', r.nblk);{$endif}
      r.pendS := r.candS; r.pendB := 1; r.pendSc := r.candSc;
      r.candS := -1; r.candSc := 0; r.candAge := 0;
    end
    else if r.candS < r.pendS then
    begin
      r.candS := -1; r.candSc := 0; r.candAge := 0;
    end;
  end;
end;

procedure ReadPending(var r: TNetRx);
var a, b: LongInt; f: TNetFrame;
begin
  if r.pendS < 0 then Exit;
  while r.pendB <= NET_MAXB do
  begin
    { the last symbol of a frame of this size must have been heard }
    SymWin(r, r.pendS, 8 + (r.pendB + 1) * 15 - 1, a, b);
    if b + 1 > r.nblk then Exit;
    if TryRead(r, r.pendS, r.pendB, f) then
    begin
      Inc(r.framesRead); r.corrected := r.corrected + f.fixed;
      if r.qn < RXQ then begin r.q[r.qn] := f; Inc(r.qn); end;
      r.doneUntil := f.endBlk - (r.ds16 div 16);
      r.pendS := -1;
      Exit;
    end;
    Inc(r.pendB);
  end;
  { no size fits: give up on it }
  Inc(r.unreadable);
  r.doneUntil := r.pendS + (8 * r.ds16) div 16;
  r.pendS := -1;
end;

procedure EndBlock(var r: TNetRx);
var ring, t: Integer; p, sr, si: Int64;
begin
  ring := r.nblk and (NRING - 1);
  p := 0;
  for t := 0 to 15 do
  begin
    r.re[ring, t] := r.accRe[t]; r.im[ring, t] := r.accIm[t];
    sr := r.accRe[t] div 64; si := r.accIm[t] div 64;
    p := p + (sr * sr + si * si) div 1024;
    r.accRe[t] := 0; r.accIm[t] := 0;
  end;
  r.pAvg := r.pAvg + (p - r.pAvg) div 4;
  { the quiet level: follows quiet blocks, rises only very slowly during sound }
  if r.nblk < 40 then r.floor := r.floor + (r.pAvg - r.floor) div 4
  else if r.pAvg < 3 * r.floor then r.floor := r.floor + (r.pAvg - r.floor) div 32
  else r.floor := r.floor + r.floor div 2048 + 1;
  if (r.nblk >= 40) and (r.pAvg > 10 * r.floor + 100) then r.lastLoud := r.nblk;
  Inc(r.nblk);
  if (r.nblk and 1) = 0 then Search(r);
  ReadPending(r);
end;

procedure NrPush(var r: TNetRx; const x: array of SmallInt; n: Integer);
var i, t: Integer; v, c, s: LongInt;
begin
  for i := 0 to n - 1 do
  begin
    r.dc := r.dc + ((LongInt(x[i]) * 256 - r.dc) div 2048);
    v := LongInt(x[i]) - (r.dc div 256);
    for t := 0 to 15 do
    begin
      c := TAB[((r.ph[t] shr 20) + 1024) and 4095];
      s := TAB[r.ph[t] shr 20];
      r.accRe[t] := r.accRe[t] + (v * c) div 32;
      r.accIm[t] := r.accIm[t] + (v * s) div 32;
      r.ph[t] := r.ph[t] + r.st[t];
    end;
    Inc(r.inBlk);
    if r.inBlk >= r.blk then
    begin
      r.inBlk := 0;
      EndBlock(r);
    end;
  end;
end;

end.
