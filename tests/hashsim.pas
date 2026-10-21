program hashsim;
{ prints AckHash for a few cases, to be compared with modem.js ackHash }
{$mode objfpc}{$H+}
uses wmodem;
var b: array[0..99] of Byte; i: Integer;
begin
  for i := 0 to 99 do b[i] := (i * 37 + 11) and 255;
  WriteLn(AckHash(7, 0, 0, b));
  WriteLn(AckHash(7, 5, 3, b));
  WriteLn(AckHash(200, 100, 15, b));
end.
