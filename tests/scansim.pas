program scansim;
{ usage: scansim recording.raw rate   (16-bit little endian samples). Prints what scanlib measured, one value per line. }
{$mode objfpc}{$H+}
uses scanlib;
var f: file; x: PSamples; n, rate, code, i, g, k: LongInt; r: TScanResult; L: TLines; size: LongInt;
begin
  Assign(f, ParamStr(1)); Reset(f, 1);
  size := FileSize(f);
  n := size div 2;
  GetMem(x, size);
  BlockRead(f, x^, size);
  Close(f);
  Val(ParamStr(2), rate, code);
  Analyse(x, n, rate, r);
  WriteLn('ok ', Ord(r.ok));
  WriteLn('err ', r.err);
  if r.ok then
  begin
    WriteLn('rate100 ', r.rate100);
    WriteLn('t0 ', r.t0, ' t1 ', r.t1);
    WriteLn('mark ', r.markDb10, ' ', r.endDb10);
    WriteLn('noise ', r.noiseRms10);
    for i := 0 to NTONE - 1 do
      WriteLn('tone ', i, ' ', r.toneDb10[i], ' ', r.noiseDb10[i], ' ', r.fall10[i], ' ', r.ghostLo10[i], ' ', r.ghostHi10[i], ' ', r.harm10[i]);
    for g := 0 to NAGC - 1 do
    begin
      Write('agc ', g, ' ', r.envAbs10[g], ' ', r.envBack10[g]);
      for k := 0 to NENV - 1 do Write(' ', r.envDb10[g, k]);
      WriteLn;
    end;
    for g := 0 to NBURST - 1 do WriteLn('burst ', g, ' ', r.burstDb10[g], ' ', r.burstSeen[g]);
    WriteLn('usable ', UsableLowHz(r), ' ', UsableHighHz(r));
  end;
  BuildReport(r, L);
  for i := 0 to L.n - 1 do WriteLn('# ', L.s[i]);
  BuildCompact(r, L);
  for i := 0 to L.n - 1 do WriteLn('$ ', L.s[i]);
end.
