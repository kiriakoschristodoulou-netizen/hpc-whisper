program filetest;
{ The handheld's file logic (wfile.pas) over a lossy link: the same cases as FileTest.java. }
{$mode objfpc}{$H+}
uses wfile;

var seed: LongWord;
function Rnd: Integer; begin seed := seed * 1103515245 + 12345; Result := (seed shr 16) and 32767; end;

function Run(size, lossPct, backPct: Integer; answers: Boolean; sd: LongWord): Integer;
var d, name, p, np: TByteArr; s: TFileSend; r: TFileRecv; haveR: Boolean; now, busy, unknownAt: LongWord;
    typ, n, i, steps, m: Integer; ok: Boolean;
begin
  seed := sd;
  SetLength(d, size); for i := 0 to size - 1 do d[i] := Rnd and 255;
  SetLength(name, 3); name[0] := 97; name[1] := 98; name[2] := 99;
  FsInit(s, 77, name, 1, d);
  haveR := False; now := 0; busy := 0; unknownAt := 0; steps := 0; SetLength(p, 0); SetLength(np, 0);
  while (not s.done) and (not s.failed) and (steps < 200000) do
  begin
    Inc(steps); now := now + 10;
    if LongInt(now - busy) >= 0 then
      if FsNext(s, now, typ, p, n) then
      begin
        busy := now + 300 + n div 2;
        if Rnd mod 100 >= lossPct then
        begin
          if typ = $10 then
          begin
            if not haveR then haveR := FrFromOffer(r, p, n, busy, 1 shl 24) else FrOffer(r, busy);
          end
          else if (typ = $11) and haveR then FrData(r, p, n, busy)
          else if typ = $11 then unknownAt := busy;
        end;
      end;
    if (not haveR) and answers and (unknownAt <> 0) and (LongInt(now - unknownAt) > QUIET_MS) and (LongInt(now - busy) >= 0) then
    begin
      unknownAt := 0;
      m := FrNeedOffer(77, np);
      if Rnd mod 100 >= backPct then FsNeed(s, np, m);
      busy := now + 200;
    end;
    if haveR and answers and (LongInt(now - busy) >= 0) and FrNeedDue(r, now) then
    begin
      m := FrNeed(r, np);
      if Rnd mod 100 >= backPct then FsNeed(s, np, m);
      busy := now + 200;
    end;
  end;
  ok := haveR and FrComplete(r);
  if ok then for i := 0 to size - 1 do if r.data[i] <> d[i] then ok := False;
  Write('size ', size:7, ' loss ', lossPct:2, '% back ', backPct:2, '% answers ', answers:5, ': ');
  if ok then Write('complete') else Write('INCOMPLETE');
  if s.confirmedAll then Write(' (confirmed)');
  if s.failed then Write(' (failed)');
  WriteLn(', ', s.sentPackets, ' packets sent for ', s.packets, ', ', now div 1000, ' s');
  if ok then Result := 0 else Result := 1;
end;

var bad: Integer;
begin
  bad := 0;
  bad += Run(1, 0, 0, True, 1);
  bad += Run(1024, 0, 0, True, 2);
  bad += Run(50000, 0, 0, True, 3);
  bad += Run(50000, 10, 10, True, 4);
  bad += Run(300000, 20, 20, True, 5);
  bad += Run(300000, 40, 30, True, 6);
  bad += Run(20000, 0, 0, False, 7);
  if bad = 0 then WriteLn('ALL PASS') else WriteLn(bad, ' FAILED');
  Halt(bad);
end.
