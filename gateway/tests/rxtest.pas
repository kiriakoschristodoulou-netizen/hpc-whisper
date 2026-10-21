program rxtest;
{ Whisper Net, handheld side: frames made by wnframe, played as one turn by
  the turn player, passed through a simulated room (resampled from 48,000 to
  the Jornada's 43,200 samples/s, noise, a ghost 900 Hz lower, an echo, a
  weak start), read back by wnrx.
  usage: rxtest [wavfile]   (optional: also read a recording, 16-bit mono WAV,
  and print the frames found) }
{$mode objfpc}{$H+}
uses sysutils, classes, wnframe, wnrx;

var fails: Integer = 0; checks: Integer = 0;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(checks);
  if ok then WriteLn('PASS  ', what) else begin WriteLn('FAIL  ', what); Inc(fails); end;
end;

var
  seed: LongWord = 12345;
function Rnd(n: Integer): Integer;
begin
  seed := seed * 1103515245 + 12345;
  Result := (seed shr 8) mod LongWord(n);
end;
function Gauss: Double;
var i: Integer; s: Double;
begin
  s := 0;
  for i := 1 to 12 do s := s + Rnd(10000) / 10000.0;
  Result := s - 6;
end;

const MAXS = 48000 * 40;
var
  src: array of SmallInt;
  dst: array of SmallInt;

{ one run: nf frames, sent at srcRate with band/sym; heard at dstRate; noise level (of 32767), ghost (0..1) }
function Run(const name: string; nf, srcRate, dstRate, bandHz, symMs: Integer; noise, ghost, echo: Double; weakMs: Integer): Boolean;
var tp: TTurnPlayer; rx: TNetRx; f: TNetFrame; i, k, n, m, got, ok: Integer;
    sent: array[0..MAXTURN - 1] of TNetFrame; pos: Double; v, ph, gstep: Double; tmp: array[0..4095] of SmallInt;
    a, b: Integer; x: Double; e: Integer;
begin
  TpInit(tp, srcRate);
  tp.bandHz := bandHz; tp.symMs := symMs; tp.volume := 80;
  tp.leadHz := 19800; tp.leadMs := 150;
  tp.nf := nf;
  for k := 0 to nf - 1 do
  begin
    FillChar(sent[k], SizeOf(TNetFrame), 0);
    sent[k].n := Rnd(NET_MAXLEN + 1);
    if k = nf - 1 then sent[k].flags := FL_TURN else sent[k].flags := 0;
    if k = 0 then sent[k].flags := sent[k].flags or FL_SYNC;
    sent[k].ack := Rnd(65536); sent[k].off := Rnd(65536);
    for i := 0 to sent[k].n - 1 do sent[k].data[i] := Rnd(256);
    EncodeNet(sent[k].flags, sent[k].n, sent[k].ack, sent[k].off, sent[k].data, tp.f[k]);
  end;
  TpStart(tp);
  n := 0;
  SetLength(src, MAXS);
  FillChar(src[0], MAXS * 2, 0);
  { a second of silence, the turn, a second of silence }
  n := srcRate;
  while TpFill(tp, tmp, 1024) do begin Move(tmp, src[n], 2048); Inc(n, 1024); end;
  Move(tmp, src[n], 2048); Inc(n, 1024);
  n := n + srcRate;
  { the room: resample (linear), a ghost 900 Hz lower (the tone moved down, as the Jornada's
    dropped samples make), an echo 3 ms later, noise; the first weakMs of each sound weak (gain settling) }
  m := Round(Int64(n) * dstRate / srcRate);
  SetLength(dst, m);
  ph := 0; gstep := 2 * Pi * (-900) / dstRate;
  for i := 0 to m - 1 do
  begin
    pos := i * srcRate / dstRate;
    a := Trunc(pos); b := a + 1; if b >= n then b := n - 1;
    x := src[a] + (src[b] - src[a]) * (pos - a);
    { ghost: a frequency-shifted copy (by mixing; good enough to put energy 900 Hz lower) }
    v := x;
    if ghost > 0 then
    begin
      ph := ph + gstep;
      v := v + ghost * x * Cos(ph) * 2;     { shifts half up, half down 900 Hz }
    end;
    e := Round(pos - 0.003 * srcRate);
    if (echo > 0) and (e >= 0) then v := v + echo * src[e];
    if (weakMs > 0) and (pos < srcRate + weakMs * srcRate / 1000) then v := v * 0.05;
    v := v + noise * Gauss;
    if v > 32767 then v := 32767; if v < -32768 then v := -32768;
    dst[i] := Round(v);
  end;
  NrInit(rx, dstRate, bandHz, symMs);
  i := 0;
  while i < m do
  begin
    k := 4410; if i + k > m then k := m - i;
    NrPush(rx, dst[i], k);
    Inc(i, k);
  end;
  got := 0; ok := 0;
  for k := 0 to nf - 1 do Write(Format(' sent[%d] n=%d off=%d;', [k, sent[k].n, sent[k].off]));
  WriteLn;
  while NrTake(rx, f) do
  begin
    Write(Format(' got n=%d off=%d end=%d;', [f.n, f.off, f.endBlk]));
    if got < nf then
      if (f.n = sent[got].n) and (f.flags = sent[got].flags) and (f.ack = sent[got].ack) and (f.off = sent[got].off)
         and CompareMem(@f.data, @sent[got].data, f.n) then Inc(ok);
    Inc(got);
  end;
  Result := (got = nf) and (ok = nf) and (NrQuietFor(rx) > 800) and (NrQuietFor(rx) < 1500);
  Check(Result, Format('%s: %d of %d frames read right (%d corrected, %d unreadable), quiet for %d blocks at the end',
    [name, ok, nf, rx.corrected, rx.unreadable, NrQuietFor(rx)]));
end;

procedure ReadWav(const fn: string);
var fs: TFileStream; hdr: array[0..43] of Byte; rate, n, i, k: Integer; buf: array of SmallInt; rx: TNetRx; f: TNetFrame;
begin
  fs := TFileStream.Create(fn, fmOpenRead);
  fs.ReadBuffer(hdr, 44);
  rate := hdr[24] or (hdr[25] shl 8) or (hdr[26] shl 16);
  n := (fs.Size - 44) div 2;
  SetLength(buf, n);
  fs.ReadBuffer(buf[0], n * 2);
  fs.Free;
  NrInit(rx, rate, 18000, 20);
  i := 0;
  while i < n do begin k := 4410; if i + k > n then k := n - i; NrPush(rx, buf[i], k); Inc(i, k); end;
  while NrTake(rx, f) do
    WriteLn(Format('frame: flags %x n %d ack %d off %d fixed %d ends %d ms', [f.flags, f.n, f.ack, f.off, f.fixed, f.endBlk]));
  WriteLn(Format('read %d, unreadable %d', [rx.framesRead, rx.unreadable]));
end;

var r: Integer;
begin
  if ParamCount >= 1 then begin ReadWav(ParamStr(1)); Halt(0); end;
  Run('clean, phone 48 kHz -> handheld 43.2 kHz, 3 frames', 3, 48000, 43200, 18000, 20, 30, 0, 0, 0);
  Run('noise 300, ghost, echo', 3, 48000, 43200, 18000, 20, 300, 0.3, 0.3, 0);
  Run('weak first 150 ms (gain still settling)', 2, 48000, 43200, 18000, 20, 200, 0.2, 0.2, 150);
  Run('handheld -> phone direction band 19.0, 43.2 kHz made, 48 kHz heard', 2, 43200, 48000, 19000, 20, 300, 0, 0.2, 0);
  Run('32 ms symbols, 19.0 kHz', 2, 48000, 43200, 19000, 32, 300, 0.2, 0.2, 0);
  Run('one empty frame (an idle turn)', 1, 48000, 43200, 18000, 20, 300, 0.2, 0.2, 0);
  for r := 1 to 6 do
    Run('random run ' + IntToStr(r) + ', noise 600', 3, 48000, 43200, 18000, 20, 600, 0.3, 0.3, 0);
  WriteLn;
  WriteLn(checks - fails, ' of ', checks, ' checks passed');
  if fails > 0 then Halt(1);
end.
