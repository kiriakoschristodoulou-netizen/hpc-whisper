program whispernet;
{ Whisper Net 1.0: internet for the HP Jornada 720 through a phone.

  Dial-up networking dials a virtual modem (the HPC Whisper port, whcom.dll);
  this program is the far end of that line: it answers PPP, runs a small
  TCP/IP stack and sends only what matters over sound to the Whisper Gateway
  app on the phone (the HPC Whisper sound format, 16 tones, 20 ms a symbol).
  Pocket Internet Explorer and the other programs then use the connection as
  any other.

  The driver, the registry entries, the dial-up entry and the dialling are
  those of COM Probe 1.6, which got "Connected" on the device.

  Lessons kept: functions not proven on the device are looked up by name;
  threads made with CreateThread use no strings or heap (units wn*, whppp);
  the screen runs on the main thread. }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define WINAPI := cdecl}{$else}{$define WINAPI := stdcall}{$endif}
{$R whispernet.res}
uses Windows, whppp, wnframe, wnrx, wnlink, wnstack, wnturn;

const
  VERSION_TEXT: UnicodeString = 'Whisper Net 1.3';
  CLSNAME: UnicodeString = 'WhisperNet';
  REGKEY: UnicodeString = 'Drivers\HPCWhisper';
  KEEPKEY: UnicodeString = 'Software\HPCWhisper\WhisperNet';
  ENTRY_NAME: UnicodeString = 'Whisper Net';
  DEVICE_NAME: UnicodeString = 'HPC Whisper';
  CFGNAME: UnicodeString = 'whispernet.cfg';
  DRIVER_VERSION = 150;
  DIAL_MS = 25000;
  WM_UPDATE = WM_APP + 1;
  WM_GO = WM_APP + 2;
  WM_RASDIALEVENT = $CCCD;
  IOC_WSP_STATS = $222000;
  IOC_WSP_ABORT = $222008;
  WAVE_MAPPER_ = UINT(-1);
  WHDR_DONE_ = 1;
  OUT_N = 1024;                  { samples in an output buffer: 24 ms }
  OUT_NBUF = 12;
  IN_N = 2205;                   { samples in an input buffer: 50 ms of what the chip really runs at }
  IN_NBUF = 8;
  IN_RATE = 44100;               { what Windows is told; the chip runs at 43,2xx }
  RING_N = 8192;

type
  TWhStats = record
    Version, ComInits, WspInits, ComOpens, WspOpens: LongWord;
    ToPhoneBytes, FromPhoneBytes, ToPhoneQueued, FromPhoneQueued, Dropped: LongWord;
    Refused, Aborts, Dtr, Rts, Baud, WaitMask, LogCount, DtrDrops: LongWord;
  end;

  TActivateDevice = function(key: PWideChar; ctx: DWORD): THandle; WINAPI;
  TDeactivateDevice = function(h: THandle): BOOL; WINAPI;
  TRegisterDevice = function(prefix: PWideChar; index: DWORD; lib: PWideChar; ctx: DWORD): THandle; WINAPI;
  TDeregisterDevice = function(h: THandle): BOOL; WINAPI;
  TRegCreateKeyExW = function(k: HKEY; sub: PWideChar; res: DWORD; cls: PWideChar; opt, sam: DWORD;
                              sa: Pointer; r: Pointer; disp: PDWORD): LONG; WINAPI;
  TRegSetValueExW = function(k: HKEY; name: PWideChar; res, typ: DWORD; data: Pointer; size: DWORD): LONG; WINAPI;
  TRegQueryValueExW = function(k: HKEY; name: PWideChar; res, typ: PDWORD; data: Pointer; size: PDWORD): LONG; WINAPI;
  TRegCloseKey = function(k: HKEY): LONG; WINAPI;
  TCopyFileW = function(src, dst: PWideChar; failIfExists: BOOL): BOOL; WINAPI;
  TGetModuleFileNameW = function(m: HMODULE; buf: PWideChar; n: DWORD): DWORD; WINAPI;
  TDeviceIoControl = function(h: THandle; code: DWORD; inb: Pointer; inl: DWORD; outb: Pointer;
                              outl: DWORD; ret: PDWORD; ov: Pointer): BOOL; WINAPI;
  TRasEnumDevices = function(buf: Pointer; cb, n: PDWORD): DWORD; WINAPI;
  TRasSetEntryProperties = function(book, entry: PWideChar; e: Pointer; size: DWORD; dev: Pointer; devsize: DWORD): DWORD; WINAPI;
  TRasGetEntryProperties = function(book, entry: PWideChar; e: Pointer; size: PDWORD; dev: Pointer; devsize: PDWORD): DWORD; WINAPI;
  TRasDial = function(ext: Pointer; book: PWideChar; params: Pointer; ntype: DWORD; notifier: Pointer; conn: PHandle): DWORD; WINAPI;
  TRasHangUp = function(conn: THandle): DWORD; WINAPI;
  TRasGetConnectStatus = function(conn: THandle; st: Pointer): DWORD; WINAPI;
  TRasDeleteEntry = function(book, entry: PWideChar): DWORD; WINAPI;

  { sound }
  TWaveFmt = record
    tag, channels: Word;
    rate, bytesPerSec: DWORD;
    align, bits, cbSize: Word;
  end;
  TWaveHdr = record
    data: Pointer;
    len, recorded: DWORD;
    user: PtrUInt;
    flags, loops: DWORD;
    next: Pointer;
    reserved: PtrUInt;
  end;
  PWaveHdr = ^TWaveHdr;
  TNumDevs = function: UINT; WINAPI;
  TWOpen = function(out h: THandle; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; WINAPI;
  TWHdrFn = function(h: THandle; hdr: PWaveHdr; size: UINT): UINT; WINAPI;
  TWHandleFn = function(h: THandle): UINT; WINAPI;
  TSetVol = function(h: THandle; v: DWORD): UINT; WINAPI;
  TGetVol = function(h: THandle; v: PDWORD): UINT; WINAPI;

var
  AppInst: HINST;
  hMain: HWND;
  fNorm, fBold, fBig: HFONT;
  Mods: array[0..3] of HMODULE;
  NMods: Integer = 0;
  Missing: UnicodeString = '';

  pActivateDevice: TActivateDevice;
  pDeactivateDevice: TDeactivateDevice;
  pRegisterDevice: TRegisterDevice;
  pDeregisterDevice: TDeregisterDevice;
  pRegCreateKeyExW: TRegCreateKeyExW;
  pRegSetValueExW: TRegSetValueExW;
  pRegQueryValueExW: TRegQueryValueExW;
  pRegCloseKey: TRegCloseKey;
  pCopyFileW: TCopyFileW;
  pGetModuleFileNameW: TGetModuleFileNameW;
  pDevIo: TDeviceIoControl;
  pRasEnumDevices: TRasEnumDevices;
  pRasSetEntryProperties: TRasSetEntryProperties;
  pRasGetEntryProperties: TRasGetEntryProperties;
  pRasDial: TRasDial;
  pRasHangUp: TRasHangUp;
  pRasGetConnectStatus: TRasGetConnectStatus;
  pRasDeleteEntry: TRasDeleteEntry;

  pNumOut: TNumDevs;
  pOutOpen: TWOpen;
  pOutPrep, pOutUnprep, pOutWrite: TWHdrFn;
  pOutReset, pOutClose: TWHandleFn;
  pOutSetVol: TSetVol;
  pOutGetVol: TGetVol;
  pNumIn: TNumDevs;
  pInOpen: TWOpen;
  pInPrep, pInUnprep, pInAdd: TWHdrFn;
  pInStart, pInStop, pInReset, pInClose: TWHandleFn;

  ExeDir, CfgPath, DllSrc, DllDst: UnicodeString;
  PortNo: Integer = 0;
  hComDev: THandle = 0;
  hWspDev: THandle = 0;
  hWsp: THandle = INVALID_HANDLE_VALUE;
  RasDevType: UnicodeString = '';
  EntryOk: Boolean = False;
  hConn: THandle = 0;
  DriverReady: Boolean = False;

  { what the screen shows }
  Phase: Integer = 0;            { 0 off, 1 starting, 2 connected, 3 stopping }
  StageText: UnicodeString = '';
  Problem: UnicodeString = '';
  Busy: Boolean = False;
  CancelReq: Boolean = False;
  QuitReq: Boolean = False;
  DialStart: LongWord = 0;
  Volume: Integer = 80;
  LogL: array[0..5] of UnicodeString;

  { shared with the threads: plain numbers and byte arrays only }
  AppQuit: LongWord = 0;
  LineRun: LongWord = 0;
  EngineRun: LongWord = 0;
  hLine: THandle = 0;
  hEngine: THandle = 0;
  hTick: THandle = 0;
  Ring: array[0..RING_N - 1] of Byte;
  RbHead, RbTail: LongWord;
  HsMatch: Integer;
  HsReplied: LongWord;
  LineBase: LongWord;
  RxTotal: LongWord;
  OutBuf: array[0..OUT_NBUF - 1, 0..OUT_N - 1] of SmallInt;
  OutHdr: array[0..OUT_NBUF - 1] of TWaveHdr;
  OutBusy: array[0..OUT_NBUF - 1] of Boolean;
  OutK: Integer;
  hOut: THandle = 0;
  OldVol: DWORD; HaveOldVol: Boolean = False;
  InBuf: array[0..IN_NBUF - 1, 0..IN_N - 1] of SmallInt;
  InHdr: array[0..IN_NBUF - 1] of TWaveHdr;
  InK: Integer;
  hIn: THandle = 0;
  Fifo: array[0..IN_N * 3 - 1] of SmallInt;
  FifoN: Integer;
  SoundFail: LongWord;           { 1 output would not open, 2 input would not open }
  Peak: LongWord;                { loudest microphone sample lately }

{ ---------- text ---------- }

function IU(i: Int64): UnicodeString;
var t: ShortString;
begin
  Str(i, t); Result := UnicodeString(t);
end;

function SameU(const a, b: UnicodeString): Boolean;
var i: Integer;
begin
  Result := False;
  if Length(a) <> Length(b) then Exit;
  for i := 1 to Length(a) do if a[i] <> b[i] then Exit;
  Result := True;
end;

function ErrU(e: DWORD): UnicodeString;
begin
  Result := 'error ' + IU(e);
end;

function Secs(ms: LongWord): UnicodeString;
begin
  Result := IU(ms div 1000) + '.' + IU((ms mod 1000) div 100) + ' s';
end;

function Ago(t: LongWord): UnicodeString;
begin
  if t = 0 then Result := 'not yet' else Result := Secs(GetTickCount - t) + ' ago';
end;

function WStr(p: PWideChar; maxn: Integer): UnicodeString;
var n: Integer;
begin
  n := 0;
  while (n < maxn) and (p[n] <> #0) do Inc(n);
  SetLength(Result, n);
  if n > 0 then Move(p^, Result[1], n * 2);
end;

procedure PutWStr(p: PByte; const s: UnicodeString; maxn: Integer);
var i: Integer; w: PWideChar;
begin
  w := PWideChar(p);
  for i := 1 to Length(s) do
    if i <= maxn then w[i - 1] := s[i];
  if Length(s) < maxn then w[Length(s)] := #0 else w[maxn - 1] := #0;
end;

procedure PutDW(p: PByte; off, v: LongWord);
begin
  p[off] := v and $FF; p[off + 1] := (v shr 8) and $FF;
  p[off + 2] := (v shr 16) and $FF; p[off + 3] := (v shr 24) and $FF;
end;

function GetDW(p: PByte; off: LongWord): LongWord;
begin
  Result := p[off] or (LongWord(p[off + 1]) shl 8) or (LongWord(p[off + 2]) shl 16) or (LongWord(p[off + 3]) shl 24);
end;

procedure Say(const s: UnicodeString);
var i: Integer;
begin
  for i := 0 to 4 do LogL[i] := LogL[i + 1];
  LogL[5] := s;
  if hMain <> 0 then InvalidateRect(hMain, nil, False);
end;

{ ---------- looking functions up by name ---------- }

procedure AddMod(const name: UnicodeString);
var m: HMODULE;
begin
  m := LoadLibraryW(PWideChar(name));
  if (m <> 0) and (NMods < 4) then begin Mods[NMods] := m; Inc(NMods); end;
end;

function Find1(const name: AnsiString): Pointer;
var i: Integer;
begin
  Result := nil;
  for i := 0 to NMods - 1 do
  begin
    {$ifdef wince}
    Result := GetProcAddressA(Mods[i], PAnsiChar(name));
    {$else}
    Result := GetProcAddress(Mods[i], PAnsiChar(name));
    {$endif}
    if Result <> nil then Exit;
  end;
end;

function Find(const a: AnsiString; const b: AnsiString = ''): Pointer;
begin
  Result := Find1(a);
  if (Result = nil) and (Length(b) > 0) then Result := Find1(b);
  if Result = nil then
  begin
    if Length(Missing) > 0 then Missing := Missing + ', ';
    Missing := Missing + UnicodeString(a);
  end;
end;

procedure LookUpAll;
begin
  pActivateDevice := TActivateDevice(Find('ActivateDevice'));
  pDeactivateDevice := TDeactivateDevice(Find('DeactivateDevice'));
  pRegisterDevice := TRegisterDevice(Find('RegisterDevice'));
  pDeregisterDevice := TDeregisterDevice(Find('DeregisterDevice'));
  pRegCreateKeyExW := TRegCreateKeyExW(Find('RegCreateKeyExW'));
  pRegSetValueExW := TRegSetValueExW(Find('RegSetValueExW'));
  pRegQueryValueExW := TRegQueryValueExW(Find('RegQueryValueExW'));
  pRegCloseKey := TRegCloseKey(Find('RegCloseKey'));
  pCopyFileW := TCopyFileW(Find('CopyFileW'));
  pDevIo := TDeviceIoControl(Find('DeviceIoControl'));
  pRasEnumDevices := TRasEnumDevices(Find('RasEnumDevices', 'RasEnumDevicesW'));
  pRasSetEntryProperties := TRasSetEntryProperties(Find('RasSetEntryProperties', 'RasSetEntryPropertiesW'));
  pRasGetEntryProperties := TRasGetEntryProperties(Find('RasGetEntryProperties', 'RasGetEntryPropertiesW'));
  pRasDial := TRasDial(Find('RasDial', 'RasDialW'));
  pRasHangUp := TRasHangUp(Find('RasHangUp', 'RasHangUpW'));
  pRasGetConnectStatus := TRasGetConnectStatus(Find('RasGetConnectStatus', 'RasGetConnectStatusW'));
  pRasDeleteEntry := TRasDeleteEntry(Find('RasDeleteEntry', 'RasDeleteEntryW'));
  pNumOut := TNumDevs(Find('waveOutGetNumDevs'));
  pOutOpen := TWOpen(Find('waveOutOpen'));
  pOutPrep := TWHdrFn(Find('waveOutPrepareHeader'));
  pOutUnprep := TWHdrFn(Find('waveOutUnprepareHeader'));
  pOutWrite := TWHdrFn(Find('waveOutWrite'));
  pOutReset := TWHandleFn(Find('waveOutReset'));
  pOutClose := TWHandleFn(Find('waveOutClose'));
  pOutSetVol := TSetVol(Find('waveOutSetVolume'));
  pOutGetVol := TGetVol(Find('waveOutGetVolume'));
  pNumIn := TNumDevs(Find('waveInGetNumDevs'));
  pInOpen := TWOpen(Find('waveInOpen'));
  pInPrep := TWHdrFn(Find('waveInPrepareHeader'));
  pInUnprep := TWHdrFn(Find('waveInUnprepareHeader'));
  pInAdd := TWHdrFn(Find('waveInAddBuffer'));
  pInStart := TWHandleFn(Find('waveInStart'));
  pInStop := TWHandleFn(Find('waveInStop'));
  pInReset := TWHandleFn(Find('waveInReset'));
  pInClose := TWHandleFn(Find('waveInClose'));
end;

{ ---------- settings file ---------- }

procedure LoadCfg;
var h: THandle; b: array[0..3] of Byte; got: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 2, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 2) and (b[0] = $57) then
    if (b[1] >= 10) and (b[1] <= 100) then Volume := b[1];
  CloseHandle(h);
end;

procedure SaveCfg;
var h: THandle; b: array[0..3] of Byte; put: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  b[0] := $57; b[1] := Volume; put := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, 2, {$ifdef wince}@put{$else}put{$endif}, nil);
  CloseHandle(h);
end;

{ ---------- registry ---------- }

function RegOpen(root: HKEY; const sub: UnicodeString; out k: HKEY): Boolean;
var disp: DWORD;
begin
  k := 0;
  Result := Assigned(pRegCreateKeyExW) and
    (pRegCreateKeyExW(root, PWideChar(sub), 0, nil, 0, {$ifdef wince}0{$else}$F003F{$endif}, nil, @k, @disp) = 0);
end;

function RegSz(k: HKEY; const name, v: UnicodeString): Boolean;
begin
  Result := pRegSetValueExW(k, PWideChar(name), 0, REG_SZ, PWideChar(v), (Length(v) + 1) * 2) = 0;
end;

function RegDw(k: HKEY; const name: UnicodeString; v: DWORD): Boolean;
begin
  Result := pRegSetValueExW(k, PWideChar(name), 0, REG_DWORD, @v, 4) = 0;
end;

function RegGetDw(k: HKEY; const name: UnicodeString): DWORD;
var typ, size, v: DWORD;
begin
  Result := 0; v := 0; size := 4; typ := 0;
  if not Assigned(pRegQueryValueExW) then Exit;
  if pRegQueryValueExW(k, PWideChar(name), nil, @typ, @v, @size) = 0 then Result := v;
end;

procedure SaveKeep;
var k: HKEY;
begin
  if not RegOpen(HKEY_CURRENT_USER, KEEPKEY, k) then Exit;
  RegDw(k, 'Com', DWORD(hComDev));
  RegDw(k, 'Wsp', DWORD(hWspDev));
  pRegCloseKey(k);
end;

{ ---------- threads ---------- }

function RF(h: THandle; buf: Pointer; n: DWORD; got: PDWORD): BOOL;
begin
  {$ifdef wince}Result := ReadFile(h, buf, n, got, nil);{$else}Result := ReadFile(h, buf^, n, got^, nil);{$endif}
end;

function WF(h: THandle; buf: Pointer; n: DWORD; got: PDWORD): BOOL;
begin
  {$ifdef wince}Result := WriteFile(h, buf, n, got, nil);{$else}Result := WriteFile(h, buf^, n, got^, nil);{$endif}
end;

function StartThread(p: Pointer): THandle;
var tid: DWORD;
begin
  {$ifdef wince}
  Result := CreateThread(nil, 0, p, nil, 0, tid);
  {$else}
  Result := CreateThread(nil, 0, TFNThreadStartRoutine(p), nil, 0, tid);
  {$endif}
end;

procedure EndThread(var h: THandle; ms: DWORD);
begin
  if h = 0 then Exit;
  WaitForSingleObject(h, ms);
  CloseHandle(h);
  h := 0;
end;

{ the line: bytes from the dial-up side of the virtual port, collected for the engine }
function LineProc(p: Pointer): DWORD; WINAPI;
var b: array[0..511] of Byte; n, k: DWORD;
begin
  while (LineRun = 1) and (AppQuit = 0) do
  begin
    n := 0;
    if not RF(hWsp, @b, SizeOf(b), @n) then begin n := 0; Sleep(20); end;
    k := 0;
    while k < n do
    begin
      if RbHead - RbTail < RING_N then
      begin
        Ring[RbHead and (RING_N - 1)] := b[k];
        Inc(RbHead);
      end;
      Inc(k);
    end;
  end;
  Result := 0;
end;

function TickProc(p: Pointer): DWORD; WINAPI;
begin
  while AppQuit = 0 do
  begin
    Sleep(500);
    if hMain <> 0 then PostMessageW(hMain, WM_UPDATE, 0, 0);
  end;
  Result := 0;
end;

{ ---------- the engine's connections (called from its thread) ---------- }

procedure PppToLine(buf: PByte; len: LongWord);
var w: DWORD;
begin
  w := 0;
  WF(hWsp, buf, len, @w);
end;

procedure HookIp(p: PByte; len: Integer);
begin
  StIpIn(p, len);
end;

procedure FIpOut(p: PByte; len: Integer);
begin
  PppSendIp(p, len);
end;

function FNow: LongWord;
begin
  Result := GetTickCount;
end;

procedure FSleep(ms: Integer);
begin
  Sleep(ms);
end;

{ the far end of the dial-up line: answers "CLIENT" with "CLIENTSERVER" as a
  Windows direct-connection host does, then PPP }
procedure FPoll;
const
  CL: array[0..5] of Byte = (67, 76, 73, 69, 78, 84);
  CS: array[0..11] of Byte = (67, 76, 73, 69, 78, 84, 83, 69, 82, 86, 69, 82);
var b: array[0..511] of Byte; n, k, w, head: DWORD; c: Byte; now: LongWord;
begin
  now := GetTickCount - LineBase;
  head := RbHead;
  n := 0;
  while (RbTail <> head) and (n < SizeOf(b)) do
  begin
    b[n] := Ring[RbTail and (RING_N - 1)];
    Inc(RbTail); Inc(n);
  end;
  if n > 0 then
  begin
    k := 0;
    while k < n do
    begin
      c := b[k];
      if HsReplied = 0 then
      begin
        if c = CL[HsMatch] then Inc(HsMatch) else if c = CL[0] then HsMatch := 1 else HsMatch := 0;
        if HsMatch = 6 then
        begin
          w := 0;
          WF(hWsp, @CS, 12, @w);
          HsReplied := 1; HsMatch := 0;
        end;
      end;
      Inc(k);
    end;
    RxTotal := RxTotal + n;
    PppInput(@b, n, now);
  end;
  PppTick(now);
end;

{ ---------- sound (the engine's thread) ---------- }

procedure FPlayStart;
var fmt: TWaveFmt; v: DWORD; k: Integer;
begin
  hOut := 0;
  if not (Assigned(pNumOut) and Assigned(pOutOpen) and Assigned(pOutPrep) and Assigned(pOutWrite)) then begin SoundFail := 1; Exit; end;
  if pNumOut() = 0 then begin SoundFail := 1; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := NtRate; fmt.bits := 16;
  fmt.align := 2; fmt.bytesPerSec := NtRate * 2;
  if pOutOpen(hOut, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then begin hOut := 0; SoundFail := 1; Exit; end;
  SoundFail := 0;
  if not HaveOldVol then
  begin
    v := 0;
    if Assigned(pOutGetVol) and (pOutGetVol(0, @v) = 0) then begin OldVol := v; HaveOldVol := True; end;
  end;
  if Assigned(pOutSetVol) then begin pOutSetVol(0, $FFFFFFFF); pOutSetVol(hOut, $FFFFFFFF); end;
  for k := 0 to OUT_NBUF - 1 do OutBusy[k] := False;
  OutK := 0;
end;

procedure WaitOut(k: Integer);
var n: Integer;
begin
  n := 0;
  while ((OutHdr[k].flags and WHDR_DONE_) = 0) and (n < 2000) do begin Sleep(2); Inc(n); end;
  pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
  OutBusy[k] := False;
end;

procedure FPlayChunk(buf: PSmallInt; n: Integer);
var k: Integer;
begin
  if hOut = 0 then begin Sleep(n * 1000 div NtRate); Exit; end;
  k := OutK;
  if OutBusy[k] then WaitOut(k);
  Move(buf^, OutBuf[k][0], n * 2);
  FillChar(OutHdr[k], SizeOf(TWaveHdr), 0);
  OutHdr[k].data := @OutBuf[k][0];
  OutHdr[k].len := n * 2;
  if pOutPrep(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then
    if pOutWrite(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then OutBusy[k] := True;
  OutK := (k + 1) mod OUT_NBUF;
end;

procedure FPlayEnd;
var k: Integer;
begin
  if hOut = 0 then Exit;
  for k := 0 to OUT_NBUF - 1 do if OutBusy[k] then WaitOut(k);
  pOutReset(hOut);
  pOutClose(hOut);
  hOut := 0;
end;

procedure FMicStart;
var fmt: TWaveFmt; k: Integer;
begin
  hIn := 0; FifoN := 0; InK := 0;
  if not (Assigned(pNumIn) and Assigned(pInOpen) and Assigned(pInPrep) and Assigned(pInAdd) and Assigned(pInStart)) then begin SoundFail := 2; Exit; end;
  if pNumIn() = 0 then begin SoundFail := 2; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := IN_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := IN_RATE * 2;
  if pInOpen(hIn, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then begin hIn := 0; SoundFail := 2; Exit; end;
  SoundFail := 0;
  for k := 0 to IN_NBUF - 1 do
  begin
    FillChar(InHdr[k], SizeOf(TWaveHdr), 0);
    InHdr[k].data := @InBuf[k][0];
    InHdr[k].len := IN_N * 2;
    pInPrep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  end;
  pInStart(hIn);
end;

function FMicRead(buf: PSmallInt; n: Integer): Boolean;
var waited, i, pk, v: Integer;
begin
  Result := False;
  if hIn = 0 then begin Sleep(n * 1000 div NtRate); Exit; end;
  waited := 0;
  while FifoN < n do
  begin
    if EngineRun = 0 then Exit;
    if (InHdr[InK].flags and WHDR_DONE_) = 0 then
    begin
      Sleep(5); Inc(waited, 5);
      if waited > 4000 then Exit;
      Continue;
    end;
    pk := 0;
    for i := 0 to IN_N - 1 do
    begin
      v := InBuf[InK][i];
      if v < 0 then v := -v;
      if v > pk then pk := v;
    end;
    Peak := pk;
    Move(InBuf[InK][0], Fifo[FifoN], IN_N * 2);
    Inc(FifoN, IN_N);
    pInUnprep(hIn, @InHdr[InK], SizeOf(TWaveHdr));
    FillChar(InHdr[InK], SizeOf(TWaveHdr), 0);
    InHdr[InK].data := @InBuf[InK][0];
    InHdr[InK].len := IN_N * 2;
    pInPrep(hIn, @InHdr[InK], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[InK], SizeOf(TWaveHdr));
    InK := (InK + 1) mod IN_NBUF;
  end;
  Move(Fifo[0], buf^, n * 2);
  Move(Fifo[n], Fifo[0], (FifoN - n) * 2);
  Dec(FifoN, n);
  Result := True;
end;

procedure FMicStop;
var k: Integer;
begin
  if hIn = 0 then Exit;
  pInStop(hIn); pInReset(hIn);
  for k := 0 to IN_NBUF - 1 do pInUnprep(hIn, @InHdr[k], SizeOf(TWaveHdr));
  pInClose(hIn);
  hIn := 0;
end;

function EngineProc(p: Pointer): DWORD; WINAPI;
begin
  NtRun;
  EngineRun := 0;
  if (HaveOldVol) and Assigned(pOutSetVol) then pOutSetVol(0, OldVol);
  Result := 0;
end;

{ ---------- the driver, the dial-up entry ---------- }

procedure DriverCleanup;
var k: HKEY; c, w: DWORD;
begin
  if not RegOpen(HKEY_CURRENT_USER, KEEPKEY, k) then Exit;
  c := RegGetDw(k, 'Com'); w := RegGetDw(k, 'Wsp');
  if (c <> 0) and Assigned(pDeactivateDevice) then pDeactivateDevice(THandle(c));
  if (w <> 0) and Assigned(pDeregisterDevice) then pDeregisterDevice(THandle(w));
  RegDw(k, 'Com', 0); RegDw(k, 'Wsp', 0);
  pRegCloseKey(k);
end;

function FindPort: Boolean;
const Tries: array[0..3] of Integer = (8, 7, 5, 2);
var i: Integer; h: THandle; e: DWORD;
begin
  Result := False;
  for i := 0 to 3 do
  begin
    SetLastError(0);
    h := CreateFileW(PWideChar('COM' + IU(Tries[i]) + ':'), 0, 0, nil, OPEN_EXISTING, 0, 0);
    e := GetLastError;
    if h <> INVALID_HANDLE_VALUE then CloseHandle(h)
    else if (e = 2) or (e = 3) or (e = 55) then begin PortNo := Tries[i]; Result := True; Exit; end;
  end;
end;

function SetupDriver: Boolean;
var k: HKEY; s: TWhStats; got: DWORD; ok: Boolean;
begin
  Result := False;
  if Length(Missing) > 0 then begin Problem := 'Missing on this device: ' + Missing; Exit; end;
  Say('driver: unloading anything left from an earlier run');
  DriverCleanup;
  {$ifdef wince}
  SetLastError(0);
  if not pCopyFileW(PWideChar(DllSrc), PWideChar(DllDst), False) then
  begin Problem := 'whcom.dll could not be copied to \Windows (' + ErrU(GetLastError) + '). Is it next to whispernet.exe? Soft reset and try again.'; Exit; end;
  {$endif}
  if not FindPort then begin Problem := 'No free serial port among COM8, 7, 5, 2.'; Exit; end;
  if not RegOpen(HKEY_LOCAL_MACHINE, REGKEY, k) then begin Problem := 'The registry entry for the port could not be made.'; Exit; end;
  ok := RegSz(k, 'Dll', 'whcom.dll') and RegSz(k, 'Prefix', 'COM') and RegDw(k, 'Index', PortNo) and
        RegDw(k, 'Order', 10) and RegSz(k, 'FriendlyName', DEVICE_NAME) and
        RegSz(k, 'Tsp', 'unimodem.dll') and RegDw(k, 'DeviceType', 0);
  pRegCloseKey(k);
  if not ok then begin Problem := 'A registry value could not be written.'; Exit; end;
  SetLastError(0);
  hComDev := pActivateDevice(PWideChar(REGKEY), 0);
  if hComDev = 0 then begin Problem := 'The serial port could not be loaded (' + ErrU(GetLastError) + ').'; Exit; end;
  SaveKeep;
  SetLastError(0);
  hWspDev := pRegisterDevice('WSP', 1, 'whcom.dll', 0);
  if hWspDev = 0 then begin Problem := 'The port''s other end (WSP1:) could not be registered (' + ErrU(GetLastError) + ').'; Exit; end;
  SaveKeep;
  hWsp := CreateFileW('WSP1:', GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  if hWsp = INVALID_HANDLE_VALUE then begin Problem := 'WSP1: would not open (' + ErrU(GetLastError) + ').'; Exit; end;
  FillChar(s, SizeOf(s), 0); got := 0;
  if not (Assigned(pDevIo) and pDevIo(hWsp, IOC_WSP_STATS, nil, 0, @s, SizeOf(s), @got, nil)) then
  begin Problem := 'The driver did not answer.'; Exit; end;
  if s.Version <> DRIVER_VERSION then
  begin Problem := 'An older whcom.dll is still loaded (version ' + IU(s.Version) + '). Soft reset and start again.'; Exit; end;
  Say('driver: COM' + IU(PortNo) + ' and WSP1: ready');
  Result := True;
end;

const
  RE_OPTIONS = 4; RE_NETPROT = 324; RE_FRAMING = 328; RE_DEVTYPE = 1892; RE_DEVNAME = 1926;

var
  BigBuf, BigBuf2: array[0..8191] of Byte;

procedure Pump;
var m: TMsg;
begin
  while PeekMessageW(@m, 0, 0, 0, PM_REMOVE) do
  begin
    if m.message = WM_QUIT then begin QuitReq := True; PostQuitMessage(0); Exit; end;
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end;

function MakeEntry: Boolean;
const REC = 104;
var size, n, e, got: DWORD; i, tries: Integer; nm, ty, back: UnicodeString; found: Boolean;
begin
  Result := False;
  if not (Assigned(pRasEnumDevices) and Assigned(pRasSetEntryProperties) and Assigned(pRasGetEntryProperties)) then
  begin Problem := 'Dial-up networking functions are missing.'; Exit; end;
  found := False;
  for tries := 0 to 14 do
  begin
    FillChar(BigBuf, SizeOf(BigBuf), 0);
    PutDW(@BigBuf, 0, REC);
    size := 40 * REC; n := 0;
    e := pRasEnumDevices(@BigBuf, @size, @n);
    if e <> 0 then begin Problem := 'RasEnumDevices: ' + ErrU(e); Exit; end;
    if n > 40 then n := 40;
    for i := 0 to Integer(n) - 1 do
    begin
      ty := WStr(PWideChar(@BigBuf[i * REC + 4]), 17);
      nm := WStr(PWideChar(@BigBuf[i * REC + 38]), 33);
      if SameU(nm, DEVICE_NAME) then begin found := True; RasDevType := ty; end;
    end;
    if found or CancelReq then Break;
    StageText := 'Waiting for the modem to appear (' + IU(tries + 1) + ')...';
    InvalidateRect(hMain, nil, False);
    for i := 1 to 25 do begin Pump; Sleep(40); end;
  end;
  if not found then begin Problem := 'The HPC Whisper modem is not listed for dial-up networking.'; Exit; end;
  size := 0;
  e := pRasGetEntryProperties(nil, '', nil, @size, nil, nil);
  if (size < 1992) or (size > SizeOf(BigBuf)) then begin Problem := 'Dial-up record size ' + IU(size); Exit; end;
  FillChar(BigBuf, size, 0);
  PutDW(@BigBuf, 0, size);
  PutDW(@BigBuf, RE_OPTIONS, $10);
  PutDW(@BigBuf, RE_NETPROT, 4);
  PutDW(@BigBuf, RE_FRAMING, 1);
  PutWStr(@BigBuf[RE_DEVTYPE], RasDevType, 17);
  PutWStr(@BigBuf[RE_DEVNAME], DEVICE_NAME, 33);
  e := pRasSetEntryProperties(nil, PWideChar(ENTRY_NAME), @BigBuf, size, nil, 0);
  if e <> 0 then begin Problem := 'RasSetEntryProperties: ' + ErrU(e); Exit; end;
  FillChar(BigBuf2, size, 0);
  PutDW(@BigBuf2, 0, size);
  got := size;
  e := pRasGetEntryProperties(nil, PWideChar(ENTRY_NAME), @BigBuf2, @got, nil, nil);
  back := WStr(PWideChar(@BigBuf2[RE_DEVNAME]), 33);
  EntryOk := (e = 0) and SameU(back, DEVICE_NAME);
  if not EntryOk then begin Problem := 'The dial-up entry could not be made.'; Exit; end;
  Say('dial-up entry "' + ENTRY_NAME + '" made');
  Result := True;
end;

{ ---------- start and stop ---------- }

procedure StartEngine;
begin
  FillChar(Ring, SizeOf(Ring), 0);
  RbHead := 0; RbTail := 0; HsMatch := 0; HsReplied := 0; RxTotal := 0;
  PppReset;
  PppOut := @PppToLine;
  PppIpHook := @HookIp;
  IpOut := @FIpOut;
  PfPlayStart := @FPlayStart; PfPlayChunk := @FPlayChunk; PfPlayEnd := @FPlayEnd;
  PfMicStart := @FMicStart; PfMicStop := @FMicStop; PfMicRead := @FMicRead;
  PfPoll := @FPoll; PfNow := @FNow; PfSleep := @FSleep;
  NtRate := 43200; NtRxRate := 43210; NtUpHz := 19000; NtDownHz := 19000; NtSymMs := 20;
  NtVolume := Volume;
  NtStop := False; NtTurns := 0; NtFramesIn := 0; NtLastHeard := 0;
  StInit(GetTickCount * 2654435761 + 12345);
  StNow := GetTickCount;
  LineBase := GetTickCount;
  LineRun := 1; EngineRun := 1;
  hLine := StartThread(@LineProc);
  hEngine := StartThread(@EngineProc);
end;

procedure StopEngine;
begin
  NtStop := True;
  EngineRun := 0;
  EndThread(hEngine, 6000);
  LineRun := 0;
  EndThread(hLine, 2000);
  PppIpHook := nil;
  PppOut := nil;
end;

function StateName(st: DWORD): UnicodeString;
begin
  case st of
    0: Result := 'opening the port'; 3: Result := 'device connected'; 5: Result := 'authenticating';
    10: Result := 'negotiating'; 14: Result := 'authenticated'; 18: Result := 'network ready';
    $2000: Result := 'connected'; $2001: Result := 'disconnected';
  else Result := 'dialling (' + IU(st) + ')';
  end;
end;

var
  DialState: DWORD = 0;
  DialErr: DWORD = 0;
  ConnAt: LongWord = 0;

procedure Disconnect;
var t0: DWORD; cst: array[0..119] of Byte; e: DWORD;
begin
  if Phase = 0 then Exit;
  Phase := 3; StageText := 'Disconnecting...';
  InvalidateRect(hMain, nil, False);
  if (hConn <> 0) and Assigned(pRasHangUp) then
  begin
    pRasHangUp(hConn);
    t0 := GetTickCount;
    if Assigned(pRasGetConnectStatus) then
      repeat
        FillChar(cst, SizeOf(cst), 0); PutDW(@cst, 0, 112);
        e := pRasGetConnectStatus(hConn, @cst);
        if e = 6 then Break;
        Sleep(50);
      until GetTickCount - t0 > 3000
    else Sleep(1000);
    hConn := 0;
  end;
  StopEngine;
  Phase := 0; StageText := 'Off'; ConnAt := 0;
  Say('disconnected');
  InvalidateRect(hMain, nil, False);
end;

procedure Connect;
const Sizes: array[0..2] of DWORD = (1464, 1460, 1462);
var
  params: array[0..1471] of Byte;
  i: Integer; e: DWORD; done: Boolean; m: TMsg;
begin
  if Busy or (Phase <> 0) then Exit;
  Busy := True; CancelReq := False; Problem := '';
  Phase := 1; StageText := 'Starting...';
  InvalidateRect(hMain, nil, False); UpdateWindow(hMain);
  if not DriverReady then
  begin
    StageText := 'Setting up the port...'; InvalidateRect(hMain, nil, False); UpdateWindow(hMain);
    if SetupDriver then DriverReady := True;
  end;
  if DriverReady and (not EntryOk) then
  begin
    if not MakeEntry then DriverReady := DriverReady;
  end;
  if (not DriverReady) or (not EntryOk) then
  begin
    if Length(Problem) = 0 then Problem := 'Setup did not finish.';
    Say(Problem);
    Phase := 0; StageText := 'Off'; Busy := False;
    InvalidateRect(hMain, nil, False);
    Exit;
  end;
  StageText := 'Dialling...'; InvalidateRect(hMain, nil, False); UpdateWindow(hMain);
  StartEngine;
  DialStart := GetTickCount; DialState := 0; DialErr := 0; ConnAt := 0;
  hConn := 0; e := 0;
  for i := 0 to 2 do
  begin
    FillChar(params, SizeOf(params), 0);
    PutDW(@params, 0, Sizes[i]);
    PutWStr(@params[4], ENTRY_NAME, 21);
    hConn := 0;
    e := pRasDial(nil, nil, @params, $FFFFFFFF, Pointer(hMain), @hConn);
    if e <> 632 then Break;
  end;
  if e <> 0 then
  begin
    if hConn <> 0 then pRasHangUp(hConn);
    hConn := 0;
    Problem := 'Dial-up could not start (' + ErrU(e) + ').';
    Say(Problem);
    StopEngine;
    Phase := 0; StageText := 'Off'; Busy := False;
    InvalidateRect(hMain, nil, False);
    Exit;
  end;
  done := False;
  while not done do
  begin
    while PeekMessageW(@m, 0, 0, 0, PM_REMOVE) do
    begin
      if m.message = WM_QUIT then begin QuitReq := True; PostQuitMessage(0); done := True; end
      else if m.message = WM_RASDIALEVENT then
      begin
        DialState := m.wParam; DialErr := m.lParam;
        StageText := 'Dial-up: ' + StateName(DialState);
        InvalidateRect(hMain, nil, False);
        if (DialState = $2000) then begin ConnAt := GetTickCount; if ConnAt = 0 then ConnAt := 1; done := True; end;
        if (DialState = $2001) or (DialErr <> 0) then done := True;
      end
      else begin TranslateMessage(@m); DispatchMessageW(@m); end;
    end;
    if CancelReq then done := True;
    if (ConnAt = 0) and (GetTickCount - DialStart >= DIAL_MS) then done := True;
    if not done then Sleep(20);
  end;
  Busy := False;
  if ConnAt > 0 then
  begin
    Phase := 2; StageText := 'Connected';
    Say('connected in ' + Secs(ConnAt - DialStart) + '; the handheld is ' + IU(PS.PeerIp shr 24) + '.' + IU((PS.PeerIp shr 16) and 255) + '.' + IU((PS.PeerIp shr 8) and 255) + '.' + IU(PS.PeerIp and 255));
    InvalidateRect(hMain, nil, False);
  end
  else
  begin
    if CancelReq then Problem := 'Cancelled.'
    else if DialErr <> 0 then Problem := 'Dial-up failed (' + ErrU(DialErr) + ' at ' + StateName(DialState) + ').'
    else Problem := 'Dial-up did not connect in ' + Secs(DIAL_MS) + ' (' + StateName(DialState) + ').';
    Say(Problem);
    Disconnect;
  end;
end;

procedure Cleanup;
var k: HKEY;
begin
  AppQuit := 1;
  if Phase <> 0 then Disconnect;
  EndThread(hTick, 1000);
  if hWsp <> INVALID_HANDLE_VALUE then begin CloseHandle(hWsp); hWsp := INVALID_HANDLE_VALUE; end;
  if EntryOk and Assigned(pRasDeleteEntry) then pRasDeleteEntry(nil, PWideChar(ENTRY_NAME));
  if (hWspDev <> 0) and Assigned(pDeregisterDevice) then pDeregisterDevice(hWspDev);
  if (hComDev <> 0) and Assigned(pDeactivateDevice) then pDeactivateDevice(hComDev);
  hWspDev := 0; hComDev := 0;
  if RegOpen(HKEY_CURRENT_USER, KEEPKEY, k) then
  begin RegDw(k, 'Com', 0); RegDw(k, 'Wsp', 0); pRegCloseKey(k); end;
end;

{ ---------- drawing ---------- }

const
  COL_NAVY = $36251B; COL_PAPER = $EEF2F4; COL_INK = $30241D; COL_MUTED = $786F6B;
  COL_GOOD = $1F8A3D; COL_FAIL = $4F60E5; COL_AMBER = $4AA0E8; COL_LINE = $D0D8DC;
  BTN_X = 530; BTN_W = 106; BTN_H = 28;
  NBTN = 4;

function MkRect(l, t, r, b: Integer): TRect;
begin
  Result.left := l; Result.top := t; Result.right := r; Result.bottom := b;
end;

function MkFont(h, weight: Integer): HFONT;
var lf: LOGFONTW; face: UnicodeString; i: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -h; lf.lfWeight := weight; lf.lfCharSet := DEFAULT_CHARSET;
  face := 'Tahoma';
  for i := 1 to Length(face) do lf.lfFaceName[i - 1] := face[i];
  Result := CreateFontIndirectW(@lf);
end;

procedure Txt(dc: HDC; const t: UnicodeString; rc: TRect; f: HFONT; col: COLORREF; flags: UINT);
var old: HGDIOBJ;
begin
  if Length(t) = 0 then Exit;
  old := SelectObject(dc, f);
  SetTextColor(dc, col);
  SetBkMode(dc, TRANSPARENT);
  DrawTextW(dc, PWideChar(t), Length(t), rc, flags or DT_NOPREFIX);
  SelectObject(dc, old);
end;

procedure FillR(dc: HDC; const rc: TRect; col: COLORREF);
var br: HBRUSH; r2: TRect;
begin
  r2 := rc; br := CreateSolidBrush(col); FillRect(dc, r2, br); DeleteObject(br);
end;

function BtnRect(i: Integer): TRect;
begin
  Result := MkRect(BTN_X, 38 + i * (BTN_H + 6), BTN_X + BTN_W, 38 + i * (BTN_H + 6) + BTN_H);
end;

function BtnText(i: Integer): UnicodeString;
begin
  case i of
    0: if Phase = 0 then Result := 'Connect  C' else if Phase = 1 then Result := 'Cancel  C' else Result := 'Disconnect  C';
    1: Result := 'Volume -';
    2: Result := 'Volume +';
  else Result := 'Exit  Q';
  end;
end;

procedure DrawButtons(dc: HDC);
var i: Integer; rc: TRect; col: COLORREF;
begin
  for i := 0 to NBTN - 1 do
  begin
    rc := BtnRect(i);
    if i = 0 then
    begin
      if Phase = 2 then col := COL_FAIL else col := COL_GOOD;
      FillR(dc, rc, col);
      Txt(dc, BtnText(i), rc, fBold, $FFFFFF, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
    end
    else
    begin
      FillR(dc, rc, $FFFFFF);
      FillR(dc, MkRect(rc.left, rc.top, rc.right, rc.top + 1), COL_LINE);
      FillR(dc, MkRect(rc.left, rc.bottom - 1, rc.right, rc.bottom), COL_LINE);
      FillR(dc, MkRect(rc.left, rc.top, rc.left + 1, rc.bottom), COL_LINE);
      FillR(dc, MkRect(rc.right - 1, rc.top, rc.right, rc.bottom), COL_LINE);
      Txt(dc, BtnText(i), rc, fBold, COL_INK, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
    end;
  end;
end;

procedure Row(dc: HDC; y: Integer; const lab, val: UnicodeString; col: COLORREF);
begin
  Txt(dc, lab, MkRect(12, y, 130, y + 16), fBold, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, val, MkRect(130, y, 524, y + 16), fNorm, col, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
end;

procedure Paint(wnd: HWND);
var ps2: PAINTSTRUCT; dc, mdc: HDC; bmp, oldb: HBITMAP; rc: TRect; y, i, w, h: Integer;
    s: UnicodeString; col: COLORREF; heard: UnicodeString;
begin
  dc := BeginPaint(wnd, ps2);
  GetClientRect(wnd, rc);
  w := rc.right; h := rc.bottom;
  mdc := CreateCompatibleDC(dc);
  bmp := CreateCompatibleBitmap(dc, w, h);
  oldb := SelectObject(mdc, bmp);
  FillR(mdc, MkRect(0, 0, w, h), COL_PAPER);
  FillR(mdc, MkRect(0, 0, w, 30), COL_NAVY);
  Txt(mdc, VERSION_TEXT, MkRect(12, 0, 300, 30), fBold, $FFFFFF, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
  Txt(mdc, 'internet for the handheld, through the phone', MkRect(200, 0, 524, 30), fNorm, $D9C8B8, DT_RIGHT or DT_VCENTER or DT_SINGLELINE);
  { state }
  case Phase of
    2: col := COL_GOOD;
    1, 3: col := COL_AMBER;
  else col := COL_MUTED;
  end;
  if Length(Problem) > 0 then Txt(mdc, Problem, MkRect(12, 36, 524, 70), fNorm, COL_FAIL, DT_LEFT or DT_WORDBREAK)
  else Txt(mdc, StageText, MkRect(12, 36, 524, 62), fBig, col, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
  y := 72;
  if Phase = 2 then
  begin
    if NtLastHeard = 0 then heard := 'nothing heard from the phone yet: is Whisper Gateway on, next to the handheld?'
    else heard := 'last heard ' + Ago(NtLastHeard);
    if NtLastHeard = 0 then col := COL_AMBER else col := COL_GOOD;
    Row(mdc, y, 'Phone gateway', heard, col); Inc(y, 17);
    Row(mdc, y, 'Sound', IU(NtTurns) + ' turns, ' + IU(NtFramesIn) + ' frames heard, ' + IU(NtUnread) + ' unreadable, volume ' + IU(Volume) + '%, mic level ' + IU(Peak * 100 div 32768) + '%', COL_INK); Inc(y, 17);
    Row(mdc, y, 'Internet', IU(StConns) + ' open, ' + IU(St.tcpOpened) + ' made, names ' + IU(St.dnsAsked) + ' asked / ' + IU(St.dnsCached) + ' remembered', COL_INK); Inc(y, 17);
    Row(mdc, y, 'Bytes', IU(St.bytesUp) + ' sent up, ' + IU(St.bytesDown) + ' received', COL_INK); Inc(y, 17);
  end
  else if Phase = 0 then
  begin
    Row(mdc, y, 'Before you start', 'Open Whisper Gateway on the phone, put it next to the handheld,', COL_INK); Inc(y, 17);
    Row(mdc, y, '', 'then press Connect. Afterwards use Pocket Internet Explorer as usual.', COL_INK); Inc(y, 17);
  end;
  { the log }
  y := 148;
  FillR(mdc, MkRect(8, y - 3, 524, y - 2), COL_LINE);
  for i := 5 downto 0 do
  begin
    s := LogL[i];
    Txt(mdc, s, MkRect(12, y, 524, y + 11), fNorm, COL_MUTED, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    Inc(y, 10);
  end;
  DrawButtons(mdc);
  BitBlt(dc, 0, 0, w, h, mdc, 0, 0, SRCCOPY);
  SelectObject(mdc, oldb); DeleteObject(bmp); DeleteDC(mdc);
  EndPaint(wnd, ps2);
end;

procedure Press(i: Integer);
begin
  case i of
    0: if Phase = 0 then PostMessageW(hMain, WM_GO, 0, 0)
       else if Phase = 1 then CancelReq := True
       else if Phase = 2 then Disconnect;
    1: begin if Volume > 10 then Dec(Volume, 10); NtVolume := Volume; SaveCfg; InvalidateRect(hMain, nil, False); end;
    2: begin if Volume < 100 then Inc(Volume, 10); NtVolume := Volume; SaveCfg; InvalidateRect(hMain, nil, False); end;
    3: begin if Phase = 1 then CancelReq := True else DestroyWindow(hMain); end;
  end;
end;

function WndProc(wnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; WINAPI;
var x, y, i: Integer; rc: TRect;
begin
  Result := 0;
  case msg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_UPDATE: InvalidateRect(wnd, nil, False);
    WM_GO: Connect;
    WM_RASDIALEVENT:
      begin
        if (Phase = 2) and ((wp = $2001) or (lp <> 0)) then
        begin
          Say('the dial-up connection ended');
          Disconnect;
        end;
      end;
    WM_LBUTTONDOWN:
      begin
        x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
        for i := 0 to NBTN - 1 do
        begin
          rc := BtnRect(i);
          if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then Press(i);
        end;
      end;
    WM_CHAR:
      case wp of
        Ord('c'), Ord('C'), 13, 32: Press(0);
        Ord('-'): Press(1);
        Ord('+'), Ord('='): Press(2);
        Ord('q'), Ord('Q'), 27: Press(3);
      end;
    WM_CLOSE: if Phase <> 1 then DestroyWindow(wnd) else CancelReq := True;
    WM_DESTROY: begin Cleanup; PostQuitMessage(0); end;
  else
    Result := DefWindowProcW(wnd, msg, wp, lp);
  end;
end;

procedure SetPaths;
var buf: array[0..259] of WideChar; n, i, cut: Integer; p: UnicodeString;
begin
  p := '';
  if Assigned(pGetModuleFileNameW) then
  begin
    n := pGetModuleFileNameW(0, @buf[0], 260);
    if n > 0 then
    begin
      SetLength(p, n);
      for i := 1 to n do p[i] := buf[i - 1];
    end;
  end;
  cut := 0;
  for i := 1 to Length(p) do if p[i] = '\' then cut := i;
  if cut > 0 then ExeDir := Copy(p, 1, cut) else ExeDir := '\';
  CfgPath := ExeDir + CFGNAME;
  DllSrc := ExeDir + 'whcom.dll';
  DllDst := '\Windows\whcom.dll';
end;

var
  wc: WNDCLASSW;
  msgv: TMsg;
  wa: TRect;
begin
  AppInst := GetModuleHandleW(nil);
  {$ifdef wince}
  AddMod('coredll.dll');
  {$else}
  AddMod('kernel32.dll'); AddMod('advapi32.dll'); AddMod('rasapi32.dll'); AddMod('winmm.dll');
  {$endif}
  pGetModuleFileNameW := TGetModuleFileNameW(Find1('GetModuleFileNameW'));
  LookUpAll;
  SetPaths;
  LoadCfg;
  StageText := 'Off';
  FillChar(wc, SizeOf(wc), 0);
  wc.style := CS_HREDRAW or CS_VREDRAW;
  wc.lpfnWndProc := @WndProc;
  wc.hInstance := AppInst;
  wc.hbrBackground := GetStockObject(WHITE_BRUSH);
  wc.lpszClassName := PWideChar(CLSNAME);
  {$ifdef wince}
  if RegisterClassW(@wc) = 0 then Halt(1);
  {$else}
  wc.hCursor := LoadCursorW(0, PWideChar(IDC_ARROW));
  if RegisterClassW(wc) = 0 then Halt(1);
  {$endif}
  fNorm := MkFont(11, 400);
  fBold := MkFont(11, 700);
  fBig := MkFont(16, 700);
  if not SystemParametersInfoW(SPI_GETWORKAREA, 0, @wa, 0) then wa := MkRect(0, 0, 640, 214);
  {$ifndef wince}
  wa := MkRect(40, 40, 680, 254);
  {$endif}
  hMain := CreateWindowExW(0, PWideChar(CLSNAME), PWideChar(VERSION_TEXT), WS_POPUP or WS_VISIBLE,
    wa.left, wa.top, wa.right - wa.left, wa.bottom - wa.top, 0, 0, AppInst, nil);
  if hMain = 0 then Halt(2);
  ShowWindow(hMain, SW_SHOW);
  UpdateWindow(hMain);
  SetForegroundWindow(hMain);
  hTick := StartThread(@TickProc);
  while GetMessageW(@msgv, 0, 0, 0) do
  begin
    TranslateMessage(@msgv);
    DispatchMessageW(@msgv);
  end;
end.
