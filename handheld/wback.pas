unit wback;
{ HPC Whisper, the return channel on the handheld: listens through the microphone all the time (a thread of
  its own) and gives every acknowledgement the phone sends (ackrx) to the program.

  Windows CE's own sound functions, found by name at run time like in the programs. The microphone is opened
  at 44,100 samples/s, which the chip really runs at about 43,200. }
{$mode objfpc}{$H+}{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
interface
uses Windows, ackrx;

var
  BkOn: Boolean = False;                 { the microphone is open and being read }
  BkErr: string[80] = '';
  BkSeq: LongInt = 0;                    { counts the acknowledgements heard }
  BkDoc, BkP, BkG, BkHash: LongInt;
  BkTick: LongWord = 0;                  { when the last one was heard }
  BkPeak: Integer = 0;                   { loudest sample of the last buffer, 0..32767 }
  BkHeard: LongInt = 0;                  { frames that were read at all, wrong text or not }
  BkWant: Boolean = False;               { the program wants the microphone open (it is closed while the handheld plays) }
  BkOk: Boolean = False;                 { the microphone has opened at least once and the last try worked }
  BkFails: Integer = 0;                  { openings in a row that failed }

procedure BkStart;
procedure BkStop;
procedure BkRelease;                     { closes the microphone and waits until it is closed (before the speaker opens) }

implementation

const
  IN_RATE = 44100;
  IN_N = 4410;
  IN_NBUF = 8;
  BK_RATE = 43210;                       { what the chip really runs at, near enough for the tones }
  WAVE_MAPPER_ = UINT(-1);
  WHDR_DONE_ = 1;

type
  TFmt = record
    tag, channels: Word;
    rate, bytesPerSec: DWORD;
    align, bits, cbSize: Word;
  end;
  THdr = record
    data: Pointer;
    len, recorded: DWORD;
    user: PtrUInt;
    flags, loops: DWORD;
    next: Pointer;
    reserved: PtrUInt;
  end;
  PHdr = ^THdr;
  TNum = function: UINT; API;
  TOpenFn = function(out h: THandle; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; API;
  THdrFn = function(h: THandle; hdr: PHdr; size: UINT): UINT; API;
  THandleFn = function(h: THandle): UINT; API;

var
  pNum: TNum; pOpen: TOpenFn;
  pPrep, pUnprep, pAdd: THdrFn;
  pStart, pStop, pReset, pClose: THandleFn;
  Resolved: Boolean = False;
  hCore2: HMODULE = 0;
  hIn: THandle = 0;
  hThread: THandle = 0;
  StopReq: Boolean = False;
  Hdr: array[0..IN_NBUF - 1] of THdr;
  Buf: array[0..IN_NBUF - 1, 0..IN_N - 1] of SmallInt;
  Rx: PAckRx = nil;

function FindFn(const fn: ShortString; const lib: UnicodeString): Pointer;
var z: array[0..63] of AnsiChar; h: HMODULE;
begin
  Result := nil;
  Move(fn[1], z, Length(fn)); z[Length(fn)] := #0;
  {$ifdef wince}
  h := hCore2;
  if h = 0 then Exit;
  Result := GetProcAddressA(h, @z[0]);
  {$else}
  h := LoadLibraryW(PWideChar(lib));
  if h = 0 then Exit;
  Result := GetProcAddress(h, @z[0]);
  {$endif}
end;

function Resolve: Boolean;
begin
  if Resolved then begin Result := Assigned(pOpen); Exit; end;
  Resolved := True;
  {$ifdef wince}
  hCore2 := LoadLibraryW('coredll.dll');
  if hCore2 = 0 then hCore2 := GetModuleHandleW('coredll.dll');
  {$endif}
  pNum := TNum(FindFn('waveInGetNumDevs', 'winmm.dll'));
  pOpen := TOpenFn(FindFn('waveInOpen', 'winmm.dll'));
  pPrep := THdrFn(FindFn('waveInPrepareHeader', 'winmm.dll'));
  pUnprep := THdrFn(FindFn('waveInUnprepareHeader', 'winmm.dll'));
  pAdd := THdrFn(FindFn('waveInAddBuffer', 'winmm.dll'));
  pStart := THandleFn(FindFn('waveInStart', 'winmm.dll'));
  pStop := THandleFn(FindFn('waveInStop', 'winmm.dll'));
  pReset := THandleFn(FindFn('waveInReset', 'winmm.dll'));
  pClose := THandleFn(FindFn('waveInClose', 'winmm.dll'));
  Result := Assigned(pNum) and Assigned(pOpen) and Assigned(pPrep) and Assigned(pUnprep) and Assigned(pAdd)
    and Assigned(pStart) and Assigned(pStop) and Assigned(pReset) and Assigned(pClose);
  if not Result then pOpen := nil;
end;

procedure Reload(k: Integer);
begin
  pUnprep(hIn, @Hdr[k], SizeOf(THdr));
  FillChar(Hdr[k], SizeOf(THdr), 0);
  Hdr[k].data := @Buf[k][0];
  Hdr[k].len := IN_N * 2;
  pPrep(hIn, @Hdr[k], SizeOf(THdr));
  pAdd(hIn, @Hdr[k], SizeOf(THdr));
end;

{ The sound chip of the Jornada cannot play and record at the same time, so the program opens one or the other:
  the microphone is open while the handheld is quiet (BkWant), and closed while it plays. }
function OpenMic: Boolean;
var fmt: TFmt; k: Integer;
begin
  Result := False;
  if not Resolve then begin BkErr := 'No microphone functions.'; Exit; end;
  if pNum() = 0 then begin BkErr := 'No microphone found.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := IN_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := IN_RATE * 2;
  if pOpen(hIn, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then begin BkErr := 'The microphone would not open.'; Exit; end;
  AckInit(Rx^, BK_RATE);
  for k := 0 to IN_NBUF - 1 do
  begin
    FillChar(Hdr[k], SizeOf(THdr), 0);
    Hdr[k].data := @Buf[k][0];
    Hdr[k].len := IN_N * 2;
    pPrep(hIn, @Hdr[k], SizeOf(THdr));
    pAdd(hIn, @Hdr[k], SizeOf(THdr));
  end;
  pStart(hIn);
  Result := True;
end;

procedure CloseMic;
var k: Integer;
begin
  pStop(hIn); pReset(hIn);
  for k := 0 to IN_NBUF - 1 do pUnprep(hIn, @Hdr[k], SizeOf(THdr));
  pClose(hIn);
end;

function ListenThread(param: Pointer): DWORD; API;
var k, i, pk, v: Integer; open: Boolean;
begin
  Result := 0;
  open := False;
  k := 0;
  while not StopReq do
  begin
    if open and not BkWant then
    begin
      CloseMic; open := False; BkOn := False;
    end;
    if (not open) and BkWant then
    begin
      if OpenMic then
      begin
        open := True; BkOn := True; BkOk := True; BkFails := 0; BkErr := ''; k := 0;
      end
      else
      begin
        BkOk := False; Inc(BkFails);
        Sleep(300);
      end;
    end;
    if not open then begin Sleep(5); Continue; end;
    if (Hdr[k].flags and WHDR_DONE_) = 0 then begin Sleep(10); Continue; end;
    pk := 0;
    for i := 0 to IN_N - 1 do
    begin
      v := Buf[k][i];
      if v < 0 then v := -v;
      if v > pk then pk := v;
    end;
    BkPeak := pk;
    if AckPush(Rx^, Buf[k], IN_N) then
    begin
      BkDoc := Rx^.ack.doc; BkP := Rx^.ack.P; BkG := Rx^.ack.G; BkHash := Rx^.ack.hash;
      BkTick := GetTickCount;
      Inc(BkSeq);
    end;
    BkHeard := Rx^.tried;
    Reload(k);
    k := (k + 1) mod IN_NBUF;
  end;
  if open then CloseMic;
  BkOn := False;
end;

procedure BkStart;
var tid: DWORD;
begin
  if hThread <> 0 then Exit;
  if Rx = nil then New(Rx);
  StopReq := False;
  BkErr := ''; BkFails := 0;
  hThread := CreateThread(nil, 0, @ListenThread, nil, 0, tid);
  if hThread = 0 then BkErr := 'The listening thread could not start.';
end;

procedure BkRelease;
var n: Integer;
begin
  BkWant := False;
  if hThread = 0 then Exit;
  n := 0;
  while BkOn and (n < 300) do begin Sleep(5); Inc(n); end;
end;

procedure BkStop;
var n: Integer;
begin
  if hThread = 0 then Exit;
  BkWant := False;
  StopReq := True;
  n := 0;
  while (WaitForSingleObject(hThread, 100) <> WAIT_OBJECT_0) and (n < 40) do Inc(n);
  CloseHandle(hThread);
  hThread := 0;
  BkOn := False;
end;

end.
