program bench;
{ How much of the Jornada's processor listening takes: each part timed here, against the probe's
  integer benchmark (a multiply, three adds and two array accesses a step; 6,556,291 steps/s on the device). }
{$mode objfpc}{$H+}
uses SysUtils, DateUtils, w3core, w3dsp, w3rx;
const SECS = 20; TONE = {$ifdef TONE}300{$else}0{$endif}; JORNADA_STEPS = 6556291;
var x, y: array of SmallInt; rs: TResampler; r: TRx; i, n, k: Integer; t0: TDateTime; tr, tsd, tfd, ts: Double;
    a: array[0..255] of LongInt; s: LongInt; steps: Int64; hostSteps: Double; seed: LongWord;
function Rnd: Integer; begin seed := seed * 1103515245 + 12345; Result := Integer((seed shr 16) and 2047) - 1024; end;
begin
  SetLength(x, 44100 * SECS); seed := 1;
  for i := 0 to High(x) do x[i] := Rnd + Round(TONE * Sin(2 * Pi * 20000 * i / 44100));
  SetLength(y, Length(x) * 2);
  { the probe's step }
  for i := 0 to 255 do a[i] := i;
  t0 := Now; s := 0; steps := 0;
  while MilliSecondsBetween(Now, t0) < 1000 do
  begin
    for k := 0 to 99999 do s := s + a[k and 255] * 3 + a[(k + 7) and 255] + k + 1;
    steps := steps + 100000;
  end;
  hostSteps := steps / (MilliSecondsBetween(Now, t0) / 1000.0);
  if s = 42 then WriteLn;
  t0 := Now;
  RsInit(rs, 4323000, Int64(MRATE) * 100, True);
  n := 0;
  for i := 0 to SECS * 10 - 1 do n := n + RsProcess(rs, x, i * 4410, 4410, y, n);
  tr := MilliSecondsBetween(Now, t0) / 1000.0;
  RxInit(r, CH_SD); t0 := Now;
  for i := 0 to n div 4096 - 1 do RxPush(r, y, i * 4096, 4096);
  tsd := MilliSecondsBetween(Now, t0) / 1000.0;
  RxInit(r, CH_FD); t0 := Now;
  for i := 0 to n div 4096 - 1 do RxPush(r, y, i * 4096, 4096);
  tfd := MilliSecondsBetween(Now, t0) / 1000.0;
  RxInit(r, CH_SU); t0 := Now;
  for i := 0 to n div 4096 - 1 do RxPush(r, y, i * 4096, 4096);
  ts := MilliSecondsBetween(Now, t0) / 1000.0;
  WriteLn(Format('host: %.0f M steps/s, %.0f times the Jornada', [hostSteps / 1e6, hostSteps / JORNADA_STEPS]));
  WriteLn(Format('per second of sound, as share of the Jornada (estimated): resampler %.0f%%, silent receiver %.0f%%, fast receiver %.0f%%  (frames %d fails %d)',
    [100 * tr / SECS * hostSteps / JORNADA_STEPS, 100 * tsd / SECS * hostSteps / JORNADA_STEPS, 100 * tfd / SECS * hostSteps / JORNADA_STEPS, r.frames, r.fails]));
end.
