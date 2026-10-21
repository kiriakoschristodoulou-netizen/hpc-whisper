program linktest;
{ The handheld's link layer against itself over a channel that loses frames,
  with the receiving side sometimes refusing bytes (a full buffer). }
{$mode objfpc}{$H+}
uses sysutils, wnframe, wnlink;

var
  A, B: TLink;
  gotA, gotB: array[0..9999] of Byte; nA, nB: Integer;
  refuse: Boolean;
  seed: LongWord = 777;
  fails, checks: Integer;

function Rnd(n: Integer): Integer;
begin
  seed := seed * 1103515245 + 12345;
  Result := (seed shr 8) mod LongWord(n);
end;

function DataA(b: PByte; len: Integer): Integer;
begin
  if refuse and (len > 7) then len := 7;
  Move(b^, gotA[nA], len); Inc(nA, len); Result := len;
end;
function DataB(b: PByte; len: Integer): Integer;
begin
  if refuse and (len > 5) then len := 5;
  Move(b^, gotB[nB], len); Inc(nB, len); Result := len;
end;
procedure ResetA; begin nA := 0; end;
procedure ResetB; begin nB := 0; end;

function Run(name: string; loss, total: Integer; ref: Boolean): Boolean;
var da, db: array[0..9999] of Byte; pa, pb, k, i, nfr, turns: Integer; fr: array[0..LK_MAXFR - 1] of TNetFrame; ok: Boolean;
begin
  refuse := ref;
  nA := 0; nB := 0;
  LkInit(A, 11 + total, @DataA, @ResetA); LkInit(B, 99 + loss, @DataB, @ResetB);
  for i := 0 to total - 1 do begin da[i] := Rnd(256); db[i] := Rnd(256); end;
  pa := 0; pb := 0; turns := 0;
  while turns < 3000 do
  begin
    Inc(turns);
    k := Rnd(60) + 1; if k > total - pa then k := total - pa; if k > LkFree(A) then k := LkFree(A);
    if k > 0 then begin LkWrite(A, @da[pa], k); Inc(pa, k); end;
    k := Rnd(60) + 1; if k > total - pb then k := total - pb; if k > LkFree(B) then k := LkFree(B);
    if k > 0 then begin LkWrite(B, @db[pb], k); Inc(pb, k); end;
    nfr := LkTurn(A, fr);
    for i := 0 to nfr - 1 do if Rnd(100) >= loss then LkReceive(B, fr[i]);
    nfr := LkTurn(B, fr);
    for i := 0 to nfr - 1 do if Rnd(100) >= loss then LkReceive(A, fr[i]);
    if (pa = total) and (pb = total) and (LkPending(A) = 0) and (LkPending(B) = 0) and (nA >= total) and (nB >= total) then Break;
  end;
  ok := (nA = total) and (nB = total) and CompareMem(@gotA, @db, total) and CompareMem(@gotB, @da, total);
  Inc(checks);
  if ok then WriteLn('PASS  ', name, ' (', turns, ' turns)') else begin WriteLn('FAIL  ', name); Inc(fails); end;
  Result := ok;
end;

begin
  Run('clean, 3000 bytes', 0, 3000, False);
  Run('30% frames lost', 30, 3000, False);
  Run('50% lost', 50, 2000, False);
  Run('refusing bytes (full buffers), 20% lost', 20, 2000, True);
  Run('10 bytes, 30% lost', 30, 10, False);
  WriteLn(checks - fails, ' of ', checks, ' checks passed');
  if fails > 0 then Halt(1);
end.
