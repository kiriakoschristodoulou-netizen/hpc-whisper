program netsim;
{ The handheld's Whisper Net (stack, link, turns) on Linux, for the end-to-end
  test. Sound goes over a TCP connection to the phone-side simulator
  (java E2ESim), IP packets over stdin / stdout (2-byte length, packet), as a
  TUN bridge makes them.
  usage: netsim host port }
{$mode objfpc}{$H+}
uses sysutils, baseunix, unix, sockets, wnframe, wnrx, wnlink, wnstack, wnturn;

var
  sock: LongInt;
  simNow: LongWord = 0;
  playBuf: array of SmallInt; playN: Integer;
  inBuf: array[0..4095] of Byte; inN: Integer;
  eof: Boolean;
  verbose: Boolean;

procedure SockWrite(const p; n: Integer);
var done, r: Integer; b: PByte;
begin
  b := @p; done := 0;
  while done < n do
  begin
    r := fpSend(sock, b + done, n - done, 0);
    if r <= 0 then begin WriteLn(StdErr, 'socket closed'); Halt(3); end;
    Inc(done, r);
  end;
end;

procedure SockRead(var p; n: Integer);
var done, r: Integer; b: PByte;
begin
  b := @p; done := 0;
  while done < n do
  begin
    r := fpRecv(sock, b + done, n - done, 0);
    if r <= 0 then begin WriteLn(StdErr, 'socket closed'); Halt(3); end;
    Inc(done, r);
  end;
end;

procedure Cmd(c: Char; arg: LongInt);
var h: array[0..4] of Byte;
begin
  h[0] := Ord(c);
  h[1] := (arg shr 24) and 255; h[2] := (arg shr 16) and 255; h[3] := (arg shr 8) and 255; h[4] := arg and 255;
  SockWrite(h, 5);
end;

procedure WaitK;
var k: Byte;
begin
  SockRead(k, 1);
end;

function FNow: LongWord; begin Result := simNow; end;

procedure FSleep(ms: Integer);
begin
  Cmd('S', ms); WaitK;
  simNow := simNow + LongWord(ms);
  fpSelect(0, nil, nil, nil, 1);        { a little real time too }
  Sleep(1);
end;

procedure FPlayStart; begin playN := 0; end;
procedure FPlayChunk(buf: PSmallInt; n: Integer);
begin
  if playN + n > Length(playBuf) then SetLength(playBuf, Length(playBuf) * 2);
  Move(buf^, playBuf[playN], n * 2);
  Inc(playN, n);
end;
procedure FPlayEnd;
begin
  Cmd('P', playN);
  SockWrite(playBuf[0], playN * 2);
  WaitK;
  simNow := simNow + LongWord(Int64(playN) * 1000 div NtRate);
end;
procedure FMicStart; begin Cmd('O', 0); WaitK; end;
procedure FMicStop; begin end;
function FMicRead(buf: PSmallInt; n: Integer): Boolean;
begin
  Cmd('M', n);
  SockRead(buf^, n * 2);
  simNow := simNow + LongWord(Int64(n) * 1000 div NtRate);
  Result := not eof;
end;

procedure FIpOut(p: PByte; len: Integer);
var h: array[0..1] of Byte;
begin
  h[0] := len shr 8; h[1] := len and 255;
  fpWrite(1, h, 2);
  fpWrite(1, p^, len);
end;

procedure FPoll;
var r, fl, pl: Integer; ready: Boolean;
begin
  { stdin is non-blocking }
  r := fpRead(0, inBuf[inN], SizeOf(inBuf) - inN);
  if r > 0 then Inc(inN, r)
  else if r = 0 then begin eof := True; NtStop := True; end;
  while inN >= 2 do
  begin
    pl := (inBuf[0] shl 8) or inBuf[1];
    if inN < 2 + pl then Break;
    StIpIn(@inBuf[2], pl);
    Move(inBuf[2 + pl], inBuf[0], inN - 2 - pl);
    Dec(inN, 2 + pl);
  end;
end;

var
  addr: TInetSockAddr; fl: LongInt;
begin
  if ParamCount < 2 then begin WriteLn('usage: netsim host port'); Halt(2); end;
  verbose := ParamCount >= 3;
  sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(StrToInt(ParamStr(2)));
  addr.sin_addr := StrToNetAddr(ParamStr(1));
  if fpConnect(sock, @addr, SizeOf(addr)) <> 0 then begin WriteLn(StdErr, 'cannot connect'); Halt(2); end;
  fl := fpFcntl(0, F_GETFL); fpFcntl(0, F_SETFL, fl or O_NONBLOCK);
  SetLength(playBuf, 1 shl 20);
  PfPlayStart := @FPlayStart; PfPlayChunk := @FPlayChunk; PfPlayEnd := @FPlayEnd;
  PfMicStart := @FMicStart; PfMicStop := @FMicStop; PfMicRead := @FMicRead;
  PfPoll := @FPoll; PfNow := @FNow; PfSleep := @FSleep;
  IpOut := @FIpOut;
  NtRate := 43200;
  StInit(20261017);
  StNow := 0;
  NtRun;
  if verbose then WriteLn(StdErr, Format('turns %d, frames in %d, empty turns %d, sim time %d s', [NtTurns, NtFramesIn, NtEmptyTurns, simNow div 1000]));
end.
