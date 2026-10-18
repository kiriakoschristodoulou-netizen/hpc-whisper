program selftool;
{ The handheld's self test pieces (wtest.pas) on Linux, for tests against the phone's SelfTest.java.
    selftool tones IDX RUN RATE out.wav     one frame of tones of the test
    selftool report SD FD ENDP RATE out.wav  the handheld's results as a frame of tones
    selftool payload RUN STAGE IDX out.bin   a test frame's 24 bytes
    selftool check in.bin                    does this payload pass the handheld's check (prints ok or bad) }
{$mode objfpc}{$H+}
uses SysUtils, w3tx, wtest;

procedure WriteWav(const p: string; const x0: TSamples; rate: LongInt);
var f: File; h: array[0..43] of Byte; n, i: LongInt; x: TSamples;
  procedure P32(o: Integer; v: LongInt); begin h[o] := v and 255; h[o+1] := (v shr 8) and 255; h[o+2] := (v shr 16) and 255; h[o+3] := (v shr 24) and 255; end;
  procedure P16(o: Integer; v: Integer); begin h[o] := v and 255; h[o+1] := (v shr 8) and 255; end;
begin
  SetLength(x, Length(x0) + 8000);
  for i := 0 to High(x) do x[i] := 0;
  for i := 0 to High(x0) do x[4000 + i] := x0[i];
  n := Length(x) * 2;
  h[0] := Ord('R'); h[1] := Ord('I'); h[2] := Ord('F'); h[3] := Ord('F'); P32(4, 36 + n);
  h[8] := Ord('W'); h[9] := Ord('A'); h[10] := Ord('V'); h[11] := Ord('E');
  h[12] := Ord('f'); h[13] := Ord('m'); h[14] := Ord('t'); h[15] := Ord(' '); P32(16, 16);
  P16(20, 1); P16(22, 1); P32(24, rate); P32(28, rate * 2); P16(32, 2); P16(34, 16);
  h[36] := Ord('d'); h[37] := Ord('a'); h[38] := Ord('t'); h[39] := Ord('a'); P32(40, n);
  Assign(f, p); Rewrite(f, 1);
  BlockWrite(f, h, 44);
  BlockWrite(f, x[0], n);
  Close(f);
end;

var x: TSamples; p: array[0..TEST_LEN - 1] of Byte; b: array[0..15] of Byte; t: TTally; f: File; n, rate: LongInt;
begin
  if ParamStr(1) = 'tones' then
  begin
    rate := StrToInt(ParamStr(4));
    ToneTestSound(StrToInt(ParamStr(2)), StrToInt(ParamStr(3)), rate, 50, x);
    WriteWav(ParamStr(5), x, rate);
  end
  else if ParamStr(1) = 'report' then
  begin
    rate := StrToInt(ParamStr(5));
    TallyInit(t); t.run := 7; t.sdMask := StrToInt(ParamStr(2)); t.fdMask := StrToInt(ParamStr(3)); t.endP := ParamStr(4) = '1'; t.frames := 9;
    n := ReportMake(t, 23, -4, b);
    ReportSound(b, n, rate, 50, x);
    WriteWav(ParamStr(6), x, rate);
  end
  else if ParamStr(1) = 'payload' then
  begin
    TestPayload(StrToInt(ParamStr(2)), StrToInt(ParamStr(3)), StrToInt(ParamStr(4)), p);
    Assign(f, ParamStr(5)); Rewrite(f, 1); BlockWrite(f, p, TEST_LEN); Close(f);
  end
  else if ParamStr(1) = 'check' then
  begin
    Assign(f, ParamStr(2)); Reset(f, 1); n := FileSize(f);
    if n > TEST_LEN then n := TEST_LEN + 1;
    FillChar(p, SizeOf(p), 0);
    if n <= TEST_LEN then BlockRead(f, p, n);
    Close(f);
    if TestPayloadOk(p, n) then WriteLn('ok') else WriteLn('bad');
  end;
end.
