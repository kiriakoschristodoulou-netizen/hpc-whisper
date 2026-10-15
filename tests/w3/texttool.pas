program texttool;
{ The handheld's typing document (wtext.pas): types a scripted sequence with keys and Backspace,
  prints each TEXT payload as hex, one per line. Then reads TEXT_ACK payloads (hex) from stdin
  and prints what is left unconfirmed. }
{$mode objfpc}{$H+}
uses SysUtils, wtext;
var s: TTextSender; p: array[0..63] of Byte; n, i: Integer; now: LongWord; line: string; a: array[0..15] of Byte;
procedure SendAll;
var k: Integer;
begin
  repeat
    n := TsNext(s, now, p);
    if n > 0 then begin for k := 0 to n - 1 do Write(IntToHex(p[k], 2)); WriteLn; end;
    now := now + 50;
  until n = 0;
end;
procedure Typ(const t: string);
var k: Integer;
begin
  for k := 1 to Length(t) do begin TsType(s, WideChar(Ord(t[k])), now); now := now + 120; SendAll; end;
end;
begin
  TsInit(s, 7); now := 1000;
  Typ('Dear Ann');
  TsKey(s, K_TAB, now); SendAll;
  Typ('Hi');
  TsBackspace(s, now); SendAll;                     { removes "i" }
  TsKey(s, K_COPY, now); SendAll;
  TsBackspace(s, now); SendAll;                     { after a key: the phone deletes (key 0x08) }
  TsKey(s, K_SEND, now); SendAll;
  WriteLn('END'); Flush(Output);
  while not EOF do
  begin
    ReadLn(line);
    if Length(line) < 10 then Continue;
    for i := 0 to 4 do a[i] := StrToInt('$' + Copy(line, 1 + 2 * i, 2));
    TsAck(s, a, 5, now);
  end;
  WriteLn('unconfirmed ', TsUnconfirmed(s), ' of ', s.L);
end.
