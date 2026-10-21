library whcom;
{ HPC Whisper virtual serial port, test driver 1.5.
  1.5: every function that answers yes or no returns exactly 1 or 0, as a
  DWORD. Up to 1.4 they were declared BOOL, and Free Pascal turns True into
  -1 (FFFFFFFF) there; Windows code that tests "== TRUE" took every success
  as a failure (ClearCommError FALSE with error 0, dial-up never reading).
  A Windows CE stream driver with two faces in one DLL:
    COM_*  the serial port that programs and dial-up networking open
    WSP_*  the other end of the line (WSP1:)
  device.exe loads the DLL once, so both faces share the pipes in whcore. }
{$mode objfpc}
{$macro on}
{$ifdef wince}
  {$define CC := cdecl}
{$else}
  {$define CC := stdcall}
{$endif}
uses Windows, whcore;

function B(ok: Boolean): DWORD;
begin
  if ok then Result := 1 else Result := 0;
end;

procedure DoSleep(ms: LongWord);
begin
  Windows.Sleep(ms);
end;

function DoTick: LongWord;
begin
  Result := Windows.GetTickCount;
end;

procedure Hook;
begin
  if not Assigned(SleepP) then begin SleepP := @DoSleep; TickF := @DoTick; end;
end;

{ ---- COM ---- }
function COM_Init(ctx: DWORD): DWORD; CC;
begin Hook; Result := ComInit(ctx); end;
function COM_Deinit(h: DWORD): DWORD; CC;
begin Result := B(ComDeinit(h)); end;
function COM_Open(h, access, share: DWORD): DWORD; CC;
begin Result := ComOpen(h, access, share); end;
function COM_Close(h: DWORD): DWORD; CC;
begin Result := B(ComClose(h)); end;
function COM_Read(h: DWORD; buf: Pointer; count: DWORD): DWORD; CC;
begin Result := ComRead(h, buf, count); end;
function COM_Write(h: DWORD; buf: Pointer; count: DWORD): DWORD; CC;
begin Result := ComWrite(h, buf, count); end;
function COM_Seek(h: DWORD; amount: LongInt; kind: DWORD): DWORD; CC;
begin Result := $FFFFFFFF; end;
function COM_IOControl(h, code: DWORD; pin: PByte; lin: DWORD; pout: PByte; lout: DWORD; pact: PDWORD): DWORD; CC;
begin Result := B(ComIOControl(h, code, pin, lin, pout, lout, PLongWord(pact))); end;
procedure COM_PowerUp(h: DWORD); CC;
begin end;
procedure COM_PowerDown(h: DWORD); CC;
begin end;

{ ---- WSP ---- }
function WSP_Init(ctx: DWORD): DWORD; CC;
begin Hook; Result := WspInit(ctx); end;
function WSP_Deinit(h: DWORD): DWORD; CC;
begin Result := B(WspDeinit(h)); end;
function WSP_Open(h, access, share: DWORD): DWORD; CC;
begin Result := WspOpen(h, access, share); end;
function WSP_Close(h: DWORD): DWORD; CC;
begin Result := B(WspClose(h)); end;
function WSP_Read(h: DWORD; buf: Pointer; count: DWORD): DWORD; CC;
begin Result := WspRead(h, buf, count); end;
function WSP_Write(h: DWORD; buf: Pointer; count: DWORD): DWORD; CC;
begin Result := WspWrite(h, buf, count); end;
function WSP_Seek(h: DWORD; amount: LongInt; kind: DWORD): DWORD; CC;
begin Result := $FFFFFFFF; end;
function WSP_IOControl(h, code: DWORD; pin: PByte; lin: DWORD; pout: PByte; lout: DWORD; pact: PDWORD): DWORD; CC;
begin Result := B(WspIOControl(h, code, pin, lin, pout, lout, PLongWord(pact))); end;
procedure WSP_PowerUp(h: DWORD); CC;
begin end;
procedure WSP_PowerDown(h: DWORD); CC;
begin end;

exports
  COM_Init, COM_Deinit, COM_Open, COM_Close, COM_Read, COM_Write, COM_Seek,
  COM_IOControl, COM_PowerUp, COM_PowerDown,
  WSP_Init, WSP_Deinit, WSP_Open, WSP_Close, WSP_Read, WSP_Write, WSP_Seek,
  WSP_IOControl, WSP_PowerUp, WSP_PowerDown;

begin
end.
