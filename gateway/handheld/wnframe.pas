unit wnframe;
{ Whisper Net: stream frames (frame version 3, NET-PROTOCOL.md section 2) on
  the HPC Whisper sound format: making them, playing a whole turn of them,
  and the Reed-Solomon decoder the receiver (wnrx) uses.

  Whole numbers only (the StrongARM has no floating point), no strings and no
  heap: this runs in the program's worker thread, which is made with
  CreateThread and so must not touch the heap. }
{$mode objfpc}{$R-}{$Q-}
interface

const
  NET_VERSION = 3;
  NET_MAXLEN = 53;                     { data bytes in one frame }
  NET_MAXB = 10;                       { body blocks }
  NET_MAXSYM = 8 + 15 * (NET_MAXB + 1);
  FL_TURN = $80;
  FL_SYNC = $40;
  PREAMBLE: array[0..7] of Byte = (0, 15, 0, 15, 11, 4, 11, 4);
  MAXTURN = 4;                         { frames in one turn, at most }

type
  TNetFrame = record
    flags, n: Integer;
    ack, off: Integer;                 { 16-bit offsets }
    data: array[0..NET_MAXLEN - 1] of Byte;
    fixed: Integer;                    { symbols the decoder corrected }
    endBlk: LongInt;                   { receiver: block where the frame ended }
  end;

  TSymbols = record
    s: array[0..NET_MAXSYM - 1] of Byte;
    n: Integer;
  end;

  { plays a turn: silence, frames with gaps, silence; optionally a lead tone first }
  TTurnPlayer = record
    rate, bandHz, symMs, volume: Integer;      { volume 0..100 }
    leadHz, leadMs: Integer;                    { 0 = no lead tone }
    preMs, gapMs, tailMs: Integer;
    nf: Integer;
    f: array[0..MAXTURN - 1] of TSymbols;
    { state }
    seg: Integer;                      { -1 idle; 0 pre; 1 lead; 2 frames; 3 tail }
    cur: Integer;                      { frame index }
    pos, len: LongInt;                 { samples into the segment, its length }
    inGap: Boolean;
    phase, stp: LongWord;
    k: Integer;                        { symbol }
    nextAt: LongInt;
  end;

function NetCrc(const b: array of Byte; n: Integer): Word;
procedure RsEnc(const d: array of Byte; var c: array of Byte);
function NetBlocks(n: Integer): Integer;
procedure EncodeNet(flags, n, ack, off: Integer; const data: array of Byte; var sy: TSymbols);
function SymsMs(const sy: TSymbols; symMs: Integer): Integer;
{ errors and erasures (2e + f <= 4); w: 15 symbols; data: the 11 data nibbles }
function RsDec(const w: array of Integer; const eras: array of Integer; ne: Integer;
               var data: array of Integer; var fixed: Integer): Boolean;
{ the frame from its K = B + 1 de-interleaved code words (already RS-decoded data, 11 nibbles each) }
function ParseNet(const words: array of Integer; K: Integer; var f: TNetFrame): Boolean;

procedure TpInit(var t: TTurnPlayer; rate: Integer);
procedure TpStart(var t: TTurnPlayer);         { after filling t.f[0..nf-1] }
{ n samples; False when the whole turn (with its tail) has been played }
function TpFill(var t: TTurnPlayer; var buf: array of SmallInt; n: Integer): Boolean;
function TpMs(const t: TTurnPlayer): Integer;  { how long the turn lasts }

implementation

const
  TAB_BITS = 12; TAB_N = 1 shl TAB_BITS;
  Sine: array[0..TAB_N - 1] of SmallInt = (
{$I sine.inc}
  );

var
  GEXP: array[0..29] of Byte;
  GLOG: array[0..15] of Byte;
  GEN: array[0..4] of Byte;

function GMul(a, b: Integer): Integer;
begin
  if (a = 0) or (b = 0) then Result := 0 else Result := GEXP[GLOG[a] + GLOG[b]];
end;

function GDiv(a, b: Integer): Integer;
begin
  if a = 0 then Result := 0 else Result := GEXP[(GLOG[a] + 15 - GLOG[b]) mod 15];
end;

procedure InitGF;
var i, j, x, gl: Integer; r, g: array[0..5] of Byte;
begin
  x := 1;
  for i := 0 to 14 do
  begin
    GEXP[i] := x; GLOG[x] := i;
    x := x shl 1;
    if (x and 16) <> 0 then x := x xor $13;
  end;
  for i := 15 to 29 do GEXP[i] := GEXP[i - 15];
  g[0] := 1; gl := 1;
  for i := 1 to 4 do
  begin
    for j := 0 to 5 do r[j] := 0;
    for j := 0 to gl - 1 do
    begin
      r[j] := r[j] xor g[j];
      r[j + 1] := r[j + 1] xor GMul(g[j], GEXP[i]);
    end;
    Inc(gl);
    for j := 0 to gl - 1 do g[j] := r[j];
  end;
  for j := 0 to 4 do GEN[j] := g[j];
end;

function NetCrc(const b: array of Byte; n: Integer): Word;
var i, k: Integer; c: Word;
begin
  c := $FFFF;
  for i := 0 to n - 1 do
  begin
    c := c xor (Word(b[i]) shl 8);
    for k := 1 to 8 do
      if (c and $8000) <> 0 then c := Word((c shl 1) xor $1021) else c := Word(c shl 1);
  end;
  Result := c;
end;

procedure RsEnc(const d: array of Byte; var c: array of Byte);
var r: array[0..14] of Byte; i, j: Integer; m: Byte;
begin
  for i := 0 to 10 do r[i] := d[i];
  for i := 11 to 14 do r[i] := 0;
  for i := 0 to 10 do
  begin
    m := r[i];
    if m <> 0 then
      for j := 1 to 4 do r[i + j] := r[i + j] xor GMul(GEN[j], m);
  end;
  for i := 0 to 10 do c[i] := d[i];
  for i := 11 to 14 do c[i] := r[i];
end;

function NetBlocks(n: Integer): Integer;
begin
  Result := ((n + 2) * 2 + 10) div 11;
end;

procedure EncodeNet(flags, n, ack, off: Integer; const data: array of Byte; var sy: TSymbols);
var all: array[0..NET_MAXLEN + 7] of Byte; nib: array[0..NET_MAXB * 11 - 1] of Byte;
    words: array[0..NET_MAXB, 0..14] of Byte; blk, cw: array[0..14] of Byte;
    i, nn, nb, K, t: Integer; c: Word;
begin
  if n > NET_MAXLEN then n := NET_MAXLEN;
  if n < 0 then n := 0;
  all[0] := (flags and $C0) or n;
  all[1] := (ack shr 8) and 255; all[2] := ack and 255;
  all[3] := (off shr 8) and 255; all[4] := off and 255;
  for i := 0 to n - 1 do all[5 + i] := data[i];
  c := NetCrc(all, n + 5);
  sy.n := 0;
  for i := 0 to 7 do begin sy.s[sy.n] := PREAMBLE[i]; Inc(sy.n); end;
  blk[0] := NET_VERSION;
  blk[1] := all[0] shr 4; blk[2] := all[0] and 15;
  blk[3] := all[1] shr 4; blk[4] := all[1] and 15; blk[5] := all[2] shr 4; blk[6] := all[2] and 15;
  blk[7] := all[3] shr 4; blk[8] := all[3] and 15; blk[9] := all[4] shr 4; blk[10] := all[4] and 15;
  RsEnc(blk, cw);
  for i := 0 to 14 do words[0, i] := cw[i];
  for i := 0 to High(nib) do nib[i] := 0;
  nn := 0;
  for i := 0 to n - 1 do begin nib[nn] := data[i] shr 4; nib[nn + 1] := data[i] and 15; Inc(nn, 2); end;
  nib[nn] := c shr 12; nib[nn + 1] := (c shr 8) and 15; nib[nn + 2] := (c shr 4) and 15; nib[nn + 3] := c and 15;
  nb := NetBlocks(n);
  for nn := 0 to nb - 1 do
  begin
    for i := 0 to 10 do blk[i] := nib[nn * 11 + i];
    RsEnc(blk, cw);
    for i := 0 to 14 do words[nn + 1, i] := cw[i];
  end;
  K := nb + 1;
  for t := 0 to K * 15 - 1 do
  begin
    sy.s[sy.n] := words[t mod K, t div K];
    Inc(sy.n);
  end;
end;

function SymsMs(const sy: TSymbols; symMs: Integer): Integer;
begin
  Result := sy.n * symMs;
end;

function PolyAt(const c: array of Integer; x: Integer): Integer;
var y, i: Integer;
begin
  y := 0;
  for i := 0 to 14 do y := GMul(y, x) xor c[i];
  Result := y;
end;

{ the same algorithm as ackrx.RsDecode15 (Berlekamp-Massey with erasures, Forney) }
function RsDec(const w: array of Integer; const eras: array of Integer; ne: Integer;
               var data: array of Integer; var fixed: Integer): Boolean;
var c: array[0..14] of Integer; S: array[0..4] of Integer; i, j, k, r, f, L, d, len, deg, np, p, xi, om, dl, X: Integer;
    lam, B, xB, T, nw, nb: array[0..9] of Integer; ll, lb, lxb, lt, v: Integer; bad: Boolean;
    pos: array[0..14] of Integer; OmP: array[0..3] of Integer;
begin
  Result := False;
  fixed := 0;
  for i := 0 to 14 do c[i] := w[i];
  bad := False;
  for i := 1 to 4 do begin S[i] := PolyAt(c, GEXP[i]); if S[i] <> 0 then bad := True; end;
  if not bad then begin for i := 0 to 10 do data[i] := c[i]; Result := True; Exit; end;
  f := ne;
  if f > 4 then Exit;
  for i := 0 to 9 do lam[i] := 0;
  lam[0] := 1; ll := 1;
  for k := 0 to f - 1 do
  begin
    X := GEXP[14 - eras[k]];
    for i := 0 to 9 do nw[i] := 0;
    for j := 0 to ll - 1 do begin nw[j] := nw[j] xor lam[j]; nw[j + 1] := nw[j + 1] xor GMul(lam[j], X); end;
    Inc(ll);
    for j := 0 to ll - 1 do lam[j] := nw[j];
  end;
  for i := 0 to 9 do B[i] := 0;
  for j := 0 to ll - 1 do B[j] := lam[j];
  lb := ll;
  L := f;
  for r := f + 1 to 4 do
  begin
    d := 0;
    for j := 0 to ll - 1 do if j < r then d := d xor GMul(lam[j], S[r - j]);
    for i := 0 to 9 do xB[i] := 0;
    for j := 0 to lb - 1 do xB[j + 1] := B[j];
    lxb := lb + 1;
    if d = 0 then
    begin
      for j := 0 to lxb - 1 do B[j] := xB[j];
      lb := lxb;
      Continue;
    end;
    for i := 0 to 9 do T[i] := 0;
    if ll > lxb then lt := ll else lt := lxb;
    for j := 0 to ll - 1 do T[j] := lam[j];
    for j := 0 to lxb - 1 do T[j] := T[j] xor GMul(d, xB[j]);
    if 2 * L <= r + f - 1 then
    begin
      L := r + f - L;
      for i := 0 to 9 do nb[i] := 0;
      for j := 0 to ll - 1 do nb[j] := GDiv(lam[j], d);
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
    xi := GEXP[(15 - p) mod 15];
    v := 0;
    for i := len - 1 downto 0 do v := GMul(v, xi) xor lam[i];
    if v = 0 then begin pos[np] := p; Inc(np); end;
  end;
  if np <> deg then Exit;
  for i := 0 to 3 do
  begin
    OmP[i] := 0;
    for j := 0 to i do
      if j < len then OmP[i] := OmP[i] xor GMul(S[i - j + 1], lam[j]);
  end;
  for k := 0 to np - 1 do
  begin
    p := pos[k]; xi := GEXP[(15 - p) mod 15];
    om := 0;
    for i := 3 downto 0 do om := GMul(om, xi) xor OmP[i];
    dl := 0;
    i := 1;
    while i < len do
    begin
      if lam[i] <> 0 then dl := dl xor GMul(lam[i], GEXP[(GLOG[xi] * (i - 1)) mod 15]);
      Inc(i, 2);
    end;
    if dl = 0 then Exit;
    c[14 - p] := c[14 - p] xor GDiv(om, dl);
  end;
  for i := 1 to 4 do if PolyAt(c, GEXP[i]) <> 0 then Exit;
  for i := 0 to 10 do data[i] := c[i];
  fixed := np;
  Result := True;
end;

{ words: K x 11 data nibbles, block 0 the header }
function ParseNet(const words: array of Integer; K: Integer; var f: TNetFrame): Boolean;
var b0, n, i: Integer; all: array[0..NET_MAXLEN + 7] of Byte; by: array[0..NET_MAXB * 11 div 2] of Byte; c: Word;
begin
  Result := False;
  if words[0] <> NET_VERSION then Exit;
  b0 := (words[1] shl 4) or words[2];
  n := b0 and 63;
  if (n > NET_MAXLEN) or (NetBlocks(n) <> K - 1) then Exit;
  all[0] := b0;
  all[1] := (words[3] shl 4) or words[4]; all[2] := (words[5] shl 4) or words[6];
  all[3] := (words[7] shl 4) or words[8]; all[4] := (words[9] shl 4) or words[10];
  { body nibbles: blocks 1 .. K-1 }
  for i := 0 to ((K - 1) * 11) div 2 - 1 do
    by[i] := (words[11 + 2 * i] shl 4) or words[11 + 2 * i + 1];
  for i := 0 to n - 1 do all[5 + i] := by[i];
  c := NetCrc(all, n + 5);
  if ((c shr 8) <> by[n]) or ((c and 255) <> by[n + 1]) then Exit;
  f.flags := b0 and $C0; f.n := n;
  f.ack := (all[1] shl 8) or all[2];
  f.off := (all[3] shl 8) or all[4];
  for i := 0 to n - 1 do f.data[i] := all[5 + i];
  Result := True;
end;

{ ---------- the turn player ---------- }

procedure TpInit(var t: TTurnPlayer; rate: Integer);
begin
  FillChar(t, SizeOf(t), 0);
  t.rate := rate;
  t.bandHz := 19000; t.symMs := 20; t.volume := 60;
  t.preMs := 100; t.gapMs := 60; t.tailMs := 150;
  t.seg := -1;
end;

function MsToS(const t: TTurnPlayer; ms: LongInt): LongInt;
begin
  Result := LongInt(Int64(ms) * t.rate div 1000);
end;

function SymAt(const t: TTurnPlayer; k: Integer): LongInt;
begin
  Result := LongInt(Int64(k) * t.rate * t.symMs div 1000);
end;

function StepFor(hz, rate: Integer): LongWord;
begin
  Result := LongWord((Int64(hz) shl 32) div rate);
end;

procedure EnterSeg(var t: TTurnPlayer; s: Integer);
begin
  t.seg := s; t.pos := 0;
  case s of
    0: t.len := MsToS(t, t.preMs);
    1: begin t.len := MsToS(t, t.leadMs); t.stp := StepFor(t.leadHz, t.rate); end;
    2: begin
         t.inGap := False; t.k := 0;
         t.len := SymAt(t, t.f[t.cur].n);
         t.nextAt := SymAt(t, 1);
         t.stp := StepFor(t.bandHz + 100 * t.f[t.cur].s[0], t.rate);
       end;
    3: t.len := MsToS(t, t.tailMs);
  end;
end;

procedure TpStart(var t: TTurnPlayer);
begin
  t.cur := 0;
  t.phase := 0;
  EnterSeg(t, 0);
end;

function TpMs(const t: TTurnPlayer): Integer;
var i: Integer;
begin
  Result := t.preMs + t.tailMs;
  if t.leadMs > 0 then Result := Result + t.leadMs + 50;
  for i := 0 to t.nf - 1 do Result := Result + t.f[i].n * t.symMs + t.gapMs;
end;

function TpFill(var t: TTurnPlayer; var buf: array of SmallInt; n: Integer): Boolean;
var i: Integer; env, fade, vol, s: LongInt;
begin
  fade := t.rate div 200;                          { 5 ms soft start and end }
  vol := t.volume * 1024 div 100;
  for i := 0 to n - 1 do
  begin
    buf[i] := 0;
    { move on to the next segment when this one is over }
    while (t.seg >= 0) and (t.pos >= t.len) do
    begin
      case t.seg of
        0: if t.leadMs > 0 then EnterSeg(t, 1)
           else if t.nf > 0 then EnterSeg(t, 2) else EnterSeg(t, 3);
        1: begin                                     { 50 ms of quiet after the lead tone }
             t.seg := 4; t.pos := 0; t.len := MsToS(t, 50);
           end;
        4: if t.nf > 0 then EnterSeg(t, 2) else EnterSeg(t, 3);
        2: if not t.inGap then
           begin
             t.inGap := True; t.pos := 0; t.len := MsToS(t, t.gapMs);
           end
           else
           begin
             Inc(t.cur);
             if t.cur < t.nf then EnterSeg(t, 2) else EnterSeg(t, 3);
           end;
        3: t.seg := -1;
      end;
    end;
    if t.seg < 0 then Continue;
    if (t.seg = 1) or ((t.seg = 2) and not t.inGap) then
    begin
      if t.seg = 2 then
        if t.pos >= t.nextAt then
        begin
          Inc(t.k);
          if t.k < t.f[t.cur].n then
          begin
            t.stp := StepFor(t.bandHz + 100 * t.f[t.cur].s[t.k], t.rate);
            t.nextAt := SymAt(t, t.k + 1);
          end;
        end;
      env := 1024;
      if t.pos < fade then env := t.pos * 1024 div fade
      else if t.len - t.pos < fade then env := (t.len - t.pos) * 1024 div fade;
      s := Sine[t.phase shr (32 - TAB_BITS)];
      if t.seg = 1 then s := s div 4;               { the lead tone is quiet }
      buf[i] := SmallInt((s * env div 1024) * vol div 1024);
      t.phase := t.phase + t.stp;
    end;
    Inc(t.pos);
  end;
  Result := t.seg >= 0;
end;

initialization
  InitGF;
end.
