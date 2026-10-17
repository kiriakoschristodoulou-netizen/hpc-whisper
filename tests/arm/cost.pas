program cost;
{ What listening costs the Jornada's processor, counted in ARM instructions (ARMv4 code, as for the
  device) under an emulator: run as  cost MODE TENTHS-OF-A-SECOND TONE  and count the instructions; the difference
  between modes is each part's cost. Mode 0: making the test sound only; 1: + the rate converter;
  2: + the silent receiver; 3: + the fast receiver; 6 minus 16: making a text frame;
  7 minus 17: the pairing analysis; 9: the probe's integer step, 1,000,000 times
  (the device did 6,556,291 a second: this calibrates instructions a second). }
{$mode objfpc}{$H+}
uses w3core, w3dsp, w3rx, w3tx, wpair;
var re, im: TCpx;
    x, y: array of SmallInt; rs: TResampler; r: TRx; i, n, k, mode, secs, code: Integer;
    a: array[0..255] of LongInt; s: LongInt; seed: LongWord; tone: Integer;
    m: TBitMap; msg: array[0..39] of Byte; fr: TSamples; pat: TSmallArr; pr: TPairResult; pm: array of Byte;
function Rnd: Integer; begin seed := seed * 1103515245 + 12345; Result := Integer((seed shr 16) and 2047) - 1024; end;
begin
  Val(ParamStr(1), mode, code); Val(ParamStr(2), secs, code); Val(ParamStr(3), tone, code);
  if mode = 5 then
  begin
    for k := 0 to 99 do begin for i := 0 to 511 do begin re[i] := (i * 37) and 1023; im[i] := 0; end; Fft(re, im, -1, True); end;
    Exit;
  end;
  { 6: making one text frame of 40 bytes (silent, at 44,100); 7: the pairing analysis of 4.2 s }
  if (mode = 6) or (mode = 16) then
  begin
    for i := 0 to 39 do msg[i] := i * 7;
    StdMap(CH_SU, m);
    if mode = 6 then fr := MakeFrame(CH_SU, m, 1, msg, 40, 0);
    Exit;
  end;
  if (mode = 7) or (mode = 17) then
  begin
    pat := PairPattern(44100);
    SetLength(x, 44100 * 42 div 10);
    for i := 0 to High(x) do x[i] := 0;
    for i := 0 to High(pat) do x[i + 30000] := pat[i] div 8;
    if mode = 7 then PairAnalyze(x, Length(x), 44100, pr);
    Exit;
  end;
  { 4: the fast receiver reading file packets (1,030 bytes each, as the phone sends them) back to back for
    TENTHS of a second, at the modem rate; 14: the same length of sound without frames (the sound is made
    in both, so 4 minus 14 is the receiver's cost on frames) }
  if (mode = 4) or (mode = 14) then
  begin
    SetLength(pm, 1030); for i := 0 to 1029 do pm[i] := (i * 13 + 5) and 255;
    StdMap(CH_FD, m);
    fr := MakeFrame51(CH_FD, m, T_FILE_DATA, pm, 1030, 9000);
    n := 5120 * secs; SetLength(y, n); seed := 1;
    i := 12800;
    while i < n do
    begin
      for k := 0 to High(fr) do if i + k < n then y[i + k] := fr[k] div 4;
      i := i + Length(fr) + 1280;
    end;
    for i := 0 to n - 1 do y[i] := y[i] + Rnd div 16;
    if mode = 4 then
    begin
      RxInit(r, CH_FD);
      for i := 0 to n div 4096 - 1 do RxPush(r, y, i * 4096, 4096);
      k := 0; for i := 0 to High(fr) do if Abs(fr[i]) > k then k := Abs(fr[i]);
      WriteLn('frames ', r.frames, ' fails ', r.fails, ' frame ', Length(fr), ' samples, peak ', k, ' last ', r.lastFail);
    end;
    Exit;
  end;
  if mode = 9 then
  begin
    for i := 0 to 255 do a[i] := i;
    s := 0;
    for k := 0 to 999999 do s := s + a[k and 255] * 3 + a[(k + 7) and 255] + k + 1;
    if s = 42 then WriteLn('x');
    Exit;
  end;
  SetLength(x, 4410 * secs);   { secs is in tenths of a second } seed := 1;
  for i := 0 to High(x) do x[i] := Rnd + (tone * COS4K[((i * 20000 * 4096) div 44100) and 4095]) div 16384;
  SetLength(y, Length(x) * 2);
  if mode = 0 then Exit;
  RsInit(rs, 4323000, Int64(MRATE) * 100, True);
  n := 0;
  for i := 0 to secs - 1 do n := n + RsProcess(rs, x, i * 4410, 4410, y, n);
  if mode = 1 then Exit;
  if mode = 2 then RxInit(r, CH_SD) else RxInit(r, CH_FD);
  for i := 0 to n div 4096 - 1 do RxPush(r, y, i * 4096, 4096);
  WriteLn('frames ', r.frames, ' fails ', r.fails);
end.
