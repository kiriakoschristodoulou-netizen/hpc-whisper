unit ackrx;
{ HPC Whisper, the return channel, receiving side (on the handheld).

  The phone tells the handheld what it has received: a short frame in the band
  19.0 - 20.5 kHz (16 tones 100 Hz apart, 4 bits a symbol, 32 ms a symbol):
  the preamble of the sender's frames, then ONE Reed-Solomon (15,11) code word
  whose 11 nibbles are

      0       1                       (type: acknowledgement)
      1-2     the document id
      3-6     P: bytes 0 .. P-1 of the document are all received (the first byte it does not have is P)
      7       G: the length of the first gap after P (0 = none), at most 15
      8-10    a check of 12 bits: CRC-16 of the bytes doc, P high, P low, G and then the received bytes 0 .. P-1,
              low 12 bits. The sender checks it against its own text, so an acknowledgement for text that has
              since been changed, or a misread frame, is not believed.

  This unit listens all the time: every sample goes into sums for the 16 tones
  (a sum over a block of 43 samples, about 1 ms), kept for the last 2 seconds;
  every 64 blocks it looks for a finished frame in them. Whole numbers only
  (the handheld has no floating point unit). Also used by tests/acksim.pas. }
{$mode objfpc}{$H+}
interface

const
  ACK_BAND = 19000;
  ACK_MS = 32;
  ACK_SYMS = 23;                         { 8 preamble + 15 }
  ACK_TYPE = 1;
  BLK = 43;                              { samples in a block }
  NRING = 2048;                          { blocks kept }

type
  TAck = record
    doc: Integer;
    P, G: Integer;
    hash: Integer;                       { the 12 bits }
    margin10: Integer;                   { weakest symbol: strongest tone over the next strongest, dB x 10 (rough) }
    fixed: Integer;
  end;

  TAckRx = record
    rate: Integer;
    nblk: LongInt;                       { blocks done }
    inBlk: Integer;                      { samples in the block being summed }
    ph: array[0..15] of LongWord;        { phase of each tone }
    st: array[0..15] of LongWord;        { phase step of each tone }
    accRe, accIm: array[0..15] of LongInt;
    re, im: array[0..NRING - 1, 0..15] of LongInt;
    dc: LongInt;                         { running mean, x 256 }
    lastStart: LongInt;                  { start block of the last frame reported }
    lastTry: LongInt;
    found: Boolean;
    ack: TAck;
    tried, decoded: LongInt;
  end;
  PAckRx = ^TAckRx;

procedure AckInit(var r: TAckRx; rate: Integer);
{ feed samples; returns True when a frame was just decoded (r.ack) }
function AckPush(var r: TAckRx; const x: array of SmallInt; n: Integer): Boolean;
function RsDecode15(const w: array of Integer; const eras: array of Integer; ne: Integer; var data: array of Integer; var fixed: Integer): Boolean;

implementation

const
  TAB_N = 4096;
var
  Tab: array[0..TAB_N - 1] of SmallInt;      { sine, +-1024 }
  EXPT: array[0..29] of Integer;
  LOGT: array[0..15] of Integer;
  TabOK: Boolean = False;
  PRE: array[0..7] of Integer = (0, 15, 0, 15, 11, 4, 11, 4);

procedure InitTables;
var i, x: Integer;
begin
  for i := 0 to TAB_N - 1 do Tab[i] := Round(1024 * Sin(2 * Pi * i / TAB_N));
  x := 1;
  for i := 0 to 14 do
  begin
    EXPT[i] := x; LOGT[x] := i;
    x := x shl 1;
    if (x and 16) <> 0 then x := x xor $13;
  end;
  for i := 15 to 29 do EXPT[i] := EXPT[i - 15];
  TabOK := True;
end;

function Gmul(a, b: Integer): Integer;
begin
  if (a <> 0) and (b <> 0) then Result := EXPT[LOGT[a] + LOGT[b]] else Result := 0;
end;

function Gdiv(a, b: Integer): Integer;
begin
  if a <> 0 then Result := EXPT[(LOGT[a] - LOGT[b] + 15) mod 15] else Result := 0;
end;

function PolyAt(const c: array of Integer; x: Integer): Integer;
var y, i: Integer;
begin
  y := 0;
  for i := 0 to 14 do y := Gmul(y, x) xor c[i];
  Result := y;
end;

{ errors and erasures (2 e + f <= 4); w = 15 symbols; the first 11 of the corrected word go to data }
function RsDecode15(const w: array of Integer; const eras: array of Integer; ne: Integer; var data: array of Integer; var fixed: Integer): Boolean;
var c: array[0..14] of Integer; S: array[0..4] of Integer; i, j, k, r, f, L, d, len, deg, np, p, xi, om, dl, X: Integer;
    lam, B, xB, T, nw, nb: array[0..9] of Integer; ll, lb, lxb, lt: Integer; bad: Boolean;
    pos: array[0..14] of Integer; OmP: array[0..3] of Integer; v: Integer;
begin
  Result := False;
  fixed := 0;
  if not TabOK then InitTables;
  for i := 0 to 14 do c[i] := w[i];
  bad := False;
  for i := 1 to 4 do begin S[i] := PolyAt(c, EXPT[i]); if S[i] <> 0 then bad := True; end;
  if not bad then begin for i := 0 to 10 do data[i] := c[i]; Result := True; Exit; end;
  f := ne;
  if f > 4 then Exit;
  FillChar(lam, SizeOf(lam), 0); lam[0] := 1; ll := 1;
  for k := 0 to f - 1 do
  begin
    X := EXPT[14 - eras[k]];
    FillChar(nw, SizeOf(nw), 0);
    for j := 0 to ll - 1 do begin nw[j] := nw[j] xor lam[j]; nw[j + 1] := nw[j + 1] xor Gmul(lam[j], X); end;
    Inc(ll);
    for j := 0 to ll - 1 do lam[j] := nw[j];
  end;
  FillChar(B, SizeOf(B), 0);
  for j := 0 to ll - 1 do B[j] := lam[j];
  lb := ll;
  L := f;
  for r := f + 1 to 4 do
  begin
    d := 0;
    for j := 0 to ll - 1 do if j < r then d := d xor Gmul(lam[j], S[r - j]);
    FillChar(xB, SizeOf(xB), 0);
    for j := 0 to lb - 1 do xB[j + 1] := B[j];
    lxb := lb + 1;
    if d = 0 then
    begin
      for j := 0 to lxb - 1 do B[j] := xB[j];
      lb := lxb;
      Continue;
    end;
    FillChar(T, SizeOf(T), 0);
    if ll > lxb then lt := ll else lt := lxb;
    for j := 0 to ll - 1 do T[j] := lam[j];
    for j := 0 to lxb - 1 do T[j] := T[j] xor Gmul(d, xB[j]);
    if 2 * L <= r + f - 1 then
    begin
      L := r + f - L;
      FillChar(nb, SizeOf(nb), 0);
      for j := 0 to ll - 1 do nb[j] := Gdiv(lam[j], d);
      for j := 0 to ll - 1 do B[j] := nb[j];
      lb := ll;
    end
    else
    begin
      for j := 0 to lxb - 1 do B[j] := xB[j];
      lb := lxb;
    end;
    for j := 0 to lt - 1 do lam[j] := T[j];
    ll := lt;
  end;
  len := ll;
  while (len > 1) and (lam[len - 1] = 0) do Dec(len);
  deg := len - 1;
  if (deg > 4) or (2 * (deg - f) + f > 4) then Exit;
  np := 0;
  for p := 0 to 14 do
  begin
    xi := EXPT[(15 - p) mod 15];
    v := 0;
    for i := len - 1 downto 0 do v := Gmul(v, xi) xor lam[i];
    if v = 0 then begin pos[np] := p; Inc(np); end;
  end;
  if np <> deg then Exit;
  for i := 0 to 3 do
  begin
    OmP[i] := 0;
    for j := 0 to i do
      if j < len then OmP[i] := OmP[i] xor Gmul(S[i - j + 1], lam[j]);
  end;
  for k := 0 to np - 1 do
  begin
    p := pos[k]; xi := EXPT[(15 - p) mod 15];
    om := 0;
    for i := 3 downto 0 do om := Gmul(om, xi) xor OmP[i];
    dl := 0;
    i := 1;
    while i < len do
    begin
      if lam[i] <> 0 then dl := dl xor Gmul(lam[i], EXPT[(LOGT[xi] * (i - 1)) mod 15]);
      Inc(i, 2);
    end;
    if dl = 0 then Exit;
    c[14 - p] := c[14 - p] xor Gdiv(om, dl);
  end;
  for i := 1 to 4 do if PolyAt(c, EXPT[i]) <> 0 then Exit;
  for i := 0 to 10 do data[i] := c[i];
  fixed := np;
  Result := True;
end;

procedure AckInit(var r: TAckRx; rate: Integer);
var t: Integer;
begin
  if not TabOK then InitTables;
  FillChar(r, SizeOf(r), 0);
  r.rate := rate;
  for t := 0 to 15 do r.st[t] := LongWord((Int64(ACK_BAND + 100 * t) shl 32) div rate);
  r.lastStart := -100000;
  r.lastTry := 0;
end;

{ the sum of tone t over blocks [a, b), as power (re^2 + im^2 in 64 bits, scaled down) }
function WinPow(var r: TAckRx; t: Integer; a, b: LongInt): Int64;
var i: LongInt; sr, si: Int64;
begin
  sr := 0; si := 0;
  for i := a to b - 1 do
  begin
    sr := sr + r.re[i and (NRING - 1), t];
    si := si + r.im[i and (NRING - 1), t];
  end;
  sr := sr div 64; si := si div 64;
  Result := sr * sr + si * si;
end;

{ symbol k of a frame that starts at block s (blocks x 16 for the fraction) }
procedure SymWin(s: LongInt; k: Integer; ds16: LongInt; var a, b: LongInt);
begin
  a := s + (Int64(k) * ds16 + ds16 div 4) div 16;
  b := s + (Int64(k + 1) * ds16 - ds16 div 10) div 16;
end;

{ how well the preamble fits a frame starting at block s: 0..800 (mean share of the expected tone) and the
  number of the 8 symbols in which the expected tone is the strongest }
function PreScore(var r: TAckRx; s: LongInt; ds16: LongInt; var good: Integer): Integer;
var k, t, e: Integer; a, b: LongInt; pw: Int64; tot, mx, ex: Int64; sum: Integer;
begin
  sum := 0; good := 0;
  for k := 0 to 7 do
  begin
    SymWin(s, k, ds16, a, b);
    tot := 0; mx := 0; ex := 0;
    e := PRE[k];
    for t := 0 to 15 do
    begin
      pw := WinPow(r, t, a, b);
      tot := tot + pw;
      if pw > mx then mx := pw;
      if t = e then ex := pw;
    end;
    if (ex > 0) and (ex >= mx) then Inc(good);
    if tot > 0 then sum := sum + Integer((ex * 100) div tot);
  end;
  Result := sum;
end;

function Log10x(a, b: Int64): Integer;           { 10 * 10 * log10(a/b), roughly, for the margin (a, b are powers) }
begin
  if (a <= 0) or (b <= 0) then begin Result := 0; Exit; end;
  Result := Round(100 * Ln(a / b) / Ln(10));
end;

function TryDecode(var r: TAckRx; s: LongInt; ds16: LongInt): Boolean;
var k, t, i, j, best, nd, fx: Integer; a, b: LongInt; pw, mx, sec: Int64; w: array[0..14] of Integer;
    mg: array[0..14] of Integer; ord_: array[0..14] of Integer; er: array[0..3] of Integer; dat: array[0..10] of Integer;
    P, G, doc, minm, tmp: Integer; ok: Boolean;
begin
  Result := False;
  for k := 0 to 14 do
  begin
    SymWin(s, 8 + k, ds16, a, b);
    mx := -1; sec := -1; best := 0;
    for t := 0 to 15 do
    begin
      pw := WinPow(r, t, a, b);
      if pw > mx then begin sec := mx; mx := pw; best := t; end
      else if pw > sec then sec := pw;
    end;
    w[k] := best;
    mg[k] := Log10x(mx, sec + 1);
    if mg[k] > 600 then mg[k] := 600;
  end;
  { plain; then with the 1 to 4 least certain symbols as erasures }
  ok := RsDecode15(w, er, 0, dat, fx);
  if not ok then
  begin
    for i := 0 to 14 do ord_[i] := i;
    for i := 1 to 14 do
    begin
      tmp := ord_[i]; j := i - 1;
      while (j >= 0) and (mg[ord_[j]] > mg[tmp]) do begin ord_[j + 1] := ord_[j]; Dec(j); end;
      ord_[j + 1] := tmp;
    end;
    for nd := 1 to 4 do
    begin
      for i := 0 to nd - 1 do er[i] := ord_[i];
      ok := RsDecode15(w, er, nd, dat, fx);
      if ok then Break;
    end;
  end;
  if not ok then Exit;
  if dat[0] <> ACK_TYPE then Exit;
  doc := dat[1] * 16 + dat[2];
  P := (dat[3] shl 12) or (dat[4] shl 8) or (dat[5] shl 4) or dat[6];
  G := dat[7];
  minm := 600;
  for k := 0 to 14 do if mg[k] < minm then minm := mg[k];
  r.ack.doc := doc; r.ack.P := P; r.ack.G := G; r.ack.hash := (dat[8] shl 8) or (dat[9] shl 4) or dat[10]; r.ack.margin10 := minm; r.ack.fixed := fx;
  Result := True;
end;

function AckPush(var r: TAckRx; const x: array of SmallInt; n: Integer): Boolean;
var i, t, ring: Integer; v, c, s: LongInt; ds16: LongInt; sbeg, sb, bestS: LongInt; sc, bestSc, good, bestGood: Integer;
begin
  Result := False;
  ds16 := (Int64(ACK_MS) * r.rate * 16) div (1000 * BLK);       { blocks per symbol x 16 }
  for i := 0 to n - 1 do
  begin
    { the offset of the microphone is taken away: it is the same every sample, but a block does not hold a whole number of waves }
    r.dc := r.dc + ((LongInt(x[i]) * 256 - r.dc) div 2048);
    v := LongInt(x[i]) - (r.dc div 256);
    for t := 0 to 15 do
    begin
      c := Tab[((r.ph[t] shr 20) + 1024) and 4095];
      s := Tab[r.ph[t] shr 20];
      r.accRe[t] := r.accRe[t] + v * c;
      r.accIm[t] := r.accIm[t] + v * s;
      r.ph[t] := r.ph[t] + r.st[t];
    end;
    Inc(r.inBlk);
    if r.inBlk >= BLK then
    begin
      ring := r.nblk and (NRING - 1);
      for t := 0 to 15 do
      begin
        r.re[ring, t] := r.accRe[t]; r.im[ring, t] := r.accIm[t];
        r.accRe[t] := 0; r.accIm[t] := 0;
      end;
      r.inBlk := 0;
      Inc(r.nblk);
      { every 64 blocks: is there a finished frame in the last blocks? it ended within the last 64 blocks }
      if (r.nblk - r.lastTry >= 64) and (r.nblk > ACK_SYMS * ds16 div 16 + 200) then
      begin
        r.lastTry := r.nblk;
        sbeg := r.nblk - (ACK_SYMS * ds16) div 16 - 96;          { the earliest start }
        bestSc := -1; bestGood := 0; bestS := 0;
        sb := sbeg;
        while sb <= sbeg + 96 do
        begin
          sc := PreScore(r, sb, ds16, good);
          if sc > bestSc then begin bestSc := sc; bestS := sb; bestGood := good; end;
          Inc(sb, 2);
        end;
        { the frame must have ended inside the newest 64 blocks and not been reported yet }
        if (bestGood >= 6) and (bestSc >= 250) and (bestS > r.lastStart + 600) then
        begin
          Inc(r.tried);
          { refine one block either way }
          sb := bestS - 1; bestSc := -1;
          while sb <= bestS + 1 do
          begin
            sc := PreScore(r, sb, ds16, good);
            if sc > bestSc then begin bestSc := sc; bestS := sb; end;
            Inc(sb);
          end;
          if TryDecode(r, bestS, ds16) then
          begin
            r.lastStart := bestS;
            Inc(r.decoded);
            Result := True;
          end;
        end;
      end;
    end;
  end;
end;

end.
