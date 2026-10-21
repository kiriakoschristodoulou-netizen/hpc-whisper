program retsim;
{ usage: retsim recording.raw rate   (16-bit little endian samples). Prints what retlib measured. }
{$mode objfpc}{$H+}
uses scanlib, retlib;
var f: file; x: PSamples; n, rate, code, k: LongInt; r: TRetResult; L: TLines; size: LongInt; i: Integer;
begin
  Assign(f, ParamStr(1)); Reset(f, 1);
  size := FileSize(f);
  n := size div 2;
  GetMem(x, size);
  BlockRead(f, x^, size);
  Close(f);
  Val(ParamStr(2), rate, code);
  AnalyseRet(x, n, rate, r);
  WriteLn('ok ', Ord(r.ok));
  WriteLn('err ', r.err);
  if r.ok then
  begin
    WriteLn('rate100 ', r.rate100);
    WriteLn('dc ', r.dc);
    for k := 0 to NBLK - 1 do
      WriteLn('blk ', k, ' ', r.off[k], ' ', r.errs[k], ' ', r.errsEarly[k], ' ', r.margMed10[k], ' ', r.margWorst10[k], ' ', r.lvl10[k], ' ', r.pre0[k], ' ', r.pre100[k], ' ', r.pre300[k]);
  end;
  BuildRetReport(r, L);
  for i := 0 to L.n - 1 do WriteLn('# ', L.s[i]);
  BuildRetCompact(r, L);
  for i := 0 to L.n - 1 do WriteLn('$ ', L.s[i]);
end.
