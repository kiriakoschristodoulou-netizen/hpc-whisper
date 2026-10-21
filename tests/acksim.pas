program acksim;
{ usage: acksim recording.raw rate   (16-bit little endian). Prints every acknowledgement found: time(ms) doc P G margin fixed }
{$mode objfpc}{$H+}
uses ackrx;
var f: file; x: PSmallInt; n, rate, code, i, k: LongInt; r: PAckRx; size: LongInt; buf: array[0..4409] of SmallInt; got: LongInt;
begin
  Assign(f, ParamStr(1)); Reset(f, 1);
  size := FileSize(f);
  n := size div 2;
  Val(ParamStr(2), rate, code);
  New(r);
  AckInit(r^, rate);
  i := 0;
  while i < n do
  begin
    got := n - i; if got > 4410 then got := 4410;
    BlockRead(f, buf, got * 2);
    if AckPush(r^, buf, got) then
      WriteLn('ack ', (Int64(r^.nblk) * 43 * 1000) div rate, ' ', r^.ack.doc, ' ', r^.ack.P, ' ', r^.ack.G, ' ', r^.ack.hash, ' ', r^.ack.margin10, ' ', r^.ack.fixed);
    Inc(i, got);
  end;
  Close(f);
  WriteLn('tried ', r^.tried, ' decoded ', r^.decoded);
end.
