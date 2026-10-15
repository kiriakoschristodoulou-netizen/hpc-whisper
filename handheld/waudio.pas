unit waudio;
{ HPC Whisper 3: the handheld's sound, both ways.

  Out: a continuous stream at 44,100 samples/s (silence between frames, so
  nothing clicks); frames wait in a queue.
  In: the microphone, at whatever rate it really runs. The Jornada 720 says
  44,100 but delivers about 43,230; the rate is measured against the clock
  (GetTickCount) and the sound converted to the modem rate with it. While
  the handheld itself plays, and for a moment after, what the microphone
  hears is ignored (it would only hear itself).

  Every sound function is looked up by name at run time. }
{$mode objfpc}{$H+}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
interface

uses Windows, w3core, w3dsp, w3rx, w3tx;

const
  OUT_RATE = 44100;
  OUT_N = 4410;                       { 100 ms per buffer }
  OUT_NBUF = 3;
  IN_N = 4410;
  IN_NBUF = 6;
  OUTQ = 16;
  RXQ = 32;

type
  TSamplesArr = TSamples;
  TFillFn = function(var buf: array of SmallInt; n: Integer): Boolean;   { classic tones; True while sounding }
  TGotMsg = record
    ch: Integer;
    msg: TRxMsg;
  end;
  TTrainResult = record
    ch: Integer;
    snr10: array[0..MAXCAR - 1] of Integer;
  end;

var
  { set before AudioStart }
  NotifyWnd: HWND = 0;
  NotifyMsg: UINT = 0;
  InRate100: Int64 = 4322960;          { the microphone's real rate x 100: a first guess, then measured }
  ListenFast: Boolean = False;         { also listen on the fast down channel (files, remote, link check) }
  ClassicFill: TFillFn = nil;          { set to play the version 2 tones }
  { state, for the screen }
  OutOk, InOk: Boolean;
  OutErr, InErr: UnicodeString;
  OutPlaying: Boolean;                 { a frame is sounding }
  InPeak: Integer;                     { loudest sample of the last half second }
  RateMeasured: Boolean;
  FramesOut, FramesIn, FramesBad: Integer;
  Overruns: Integer;                   { buffers not listened to: the processor fell behind }
  RateOdd: Int64;                      { an unbelievable rate measurement (x 100), 0 = none }
  MissingNames: UnicodeString = '';

procedure AudioResolve;
procedure AudioStart;
procedure AudioStop;
{ queue a frame (44,100 samples/s); False when the queue is full }
function AudioSend(const x: TSamplesArr): Boolean;
function AudioQueued: Integer;
function AudioTake(var m: TGotMsg): Boolean;         { a message heard }
function AudioTakeTrain(var t: TTrainResult): Boolean;
procedure AudioAddMap(const m: TBitMap);             { a map for what the phone sends }

implementation

type
  TWaveFormat = record
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
  TNumDevs = function: UINT; API;
  TOpen = function(out h: THandle; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; API;
  THdrFn = function(h: THandle; hdr: PWaveHdr; size: UINT): UINT; API;
  THandleFn = function(h: THandle): UINT; API;
  TSetVol = function(h: THandle; vol: DWORD): UINT; API;
  TGetVol = function(h: THandle; vol: PDWORD): UINT; API;

var
  pOutNum: TNumDevs; pOutOpen: TOpen; pOutPrep, pOutUnprep, pOutWrite: THdrFn; pOutReset, pOutClose: THandleFn;
  pSetVol: TSetVol; pGetVol: TGetVol;
  pInNum: TNumDevs; pInOpen: TOpen; pInPrep, pInUnprep, pInAdd: THdrFn; pInStart, pInStop, pInReset, pInClose: THandleFn;
  hCore: HMODULE = 0;
  Lock: TRTLCriticalSection;
  Quit: Boolean = False;
  hOut, hIn: THandle;
  hOutThread, hInThread: THandle;
  OldVol: DWORD; HaveOldVol: Boolean = False;
  OutHdr: array[0..OUT_NBUF - 1] of TWaveHdr;
  OutBuf: array[0..OUT_NBUF - 1, 0..OUT_N - 1] of SmallInt;
  InHdr: array[0..IN_NBUF - 1] of TWaveHdr;
  InBuf: array[0..IN_NBUF - 1, 0..IN_N - 1] of SmallInt;
  Q: array[0..OUTQ - 1] of TSamplesArr;
  QHead, QTail: Integer;
  Cur: TSamplesArr; CurPos: Integer;
  QuietUntil: LongWord = 0;            { the microphone is ignored until then }
  RxSD, RxFD: TRx;
  Rs: TResampler;
  Got: array[0..RXQ - 1] of TGotMsg;
  GotHead, GotTail: Integer;
  TrainQ: array[0..3] of TTrainResult;
  TrainHead, TrainTail: Integer;
  PendingMaps: array[0..7] of TBitMap;
  PendingN: Integer = 0;
  InitDone: Boolean = False;

function FindIn(h: HMODULE; const fn: ShortString): Pointer;
var z: array[0..63] of AnsiChar;
begin
  Result := nil;
  if h = 0 then Exit;
  Move(fn[1], z, Length(fn)); z[Length(fn)] := #0;
  {$ifdef wince}
  Result := GetProcAddressA(h, @z[0]);
  {$else}
  Result := GetProcAddress(h, @z[0]);
  {$endif}
end;

function US(const s: ShortString): UnicodeString;
var i: Integer;
begin
  SetLength(Result, Length(s));
  for i := 1 to Length(s) do Result[i] := WideChar(Ord(s[i]));
end;

function Find(const fn: ShortString): Pointer;
begin
  {$ifdef wince}
  Result := FindIn(hCore, fn);
  {$else}
  Result := FindIn(LoadLibraryW('winmm.dll'), fn);
  {$endif}
  if Result = nil then
  begin
    if MissingNames <> '' then MissingNames := MissingNames + ', ';
    MissingNames := MissingNames + US(fn);
  end;
end;

procedure AudioResolve;
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pOutNum := TNumDevs(Find('waveOutGetNumDevs'));
  pOutOpen := TOpen(Find('waveOutOpen'));
  pOutPrep := THdrFn(Find('waveOutPrepareHeader'));
  pOutUnprep := THdrFn(Find('waveOutUnprepareHeader'));
  pOutWrite := THdrFn(Find('waveOutWrite'));
  pOutReset := THandleFn(Find('waveOutReset'));
  pOutClose := THandleFn(Find('waveOutClose'));
  pSetVol := TSetVol(Find('waveOutSetVolume'));
  pGetVol := TGetVol(Find('waveOutGetVolume'));
  pInNum := TNumDevs(Find('waveInGetNumDevs'));
  pInOpen := TOpen(Find('waveInOpen'));
  pInPrep := THdrFn(Find('waveInPrepareHeader'));
  pInUnprep := THdrFn(Find('waveInUnprepareHeader'));
  pInAdd := THdrFn(Find('waveInAddBuffer'));
  pInStart := THandleFn(Find('waveInStart'));
  pInStop := THandleFn(Find('waveInStop'));
  pInReset := THandleFn(Find('waveInReset'));
  pInClose := THandleFn(Find('waveInClose'));
end;

procedure Notify;
begin
  if NotifyWnd <> 0 then PostMessageW(NotifyWnd, NotifyMsg, 0, 0);
end;

{ ---------- out ---------- }

function AudioSend(const x: TSamplesArr): Boolean;
var nx: Integer;
begin
  EnterCriticalSection(Lock);
  nx := (QHead + 1) mod OUTQ;
  Result := nx <> QTail;
  if Result then begin Q[QHead] := x; QHead := nx; end;
  LeaveCriticalSection(Lock);
end;

function AudioQueued: Integer;
begin
  EnterCriticalSection(Lock);
  Result := (QHead - QTail + OUTQ) mod OUTQ;
  if CurPos < Length(Cur) then Inc(Result);
  LeaveCriticalSection(Lock);
end;

{ fills one buffer; True when it holds sound }
function FillOut(var b: array of SmallInt): Boolean;
var i, n, take: Integer;
begin
  Result := False;
  i := 0;
  while i < OUT_N do
  begin
    if CurPos >= Length(Cur) then
    begin
      EnterCriticalSection(Lock);
      if QTail <> QHead then
      begin
        Cur := Q[QTail]; SetLength(Q[QTail], 0);
        QTail := (QTail + 1) mod OUTQ;
        CurPos := 0;
        Inc(FramesOut);
      end
      else SetLength(Cur, 0);
      LeaveCriticalSection(Lock);
      if Length(Cur) = 0 then Break;
    end;
    take := Length(Cur) - CurPos;
    if take > OUT_N - i then take := OUT_N - i;
    for n := 0 to take - 1 do b[i + n] := Cur[CurPos + n];
    Inc(CurPos, take); Inc(i, take);
    Result := True;
  end;
  for n := i to OUT_N - 1 do b[n] := 0;
  { the version 2 tones, when they are in use }
  if (i = 0) and Assigned(ClassicFill) then
    if ClassicFill(b, OUT_N) then Result := True;
end;

function OutThread(param: Pointer): DWORD; API;
var fmt: TWaveFormat; k, i: Integer; playing: array[0..OUT_NBUF - 1] of Boolean; v: DWORD; sound: Boolean;
begin
  Result := 0;
  OutOk := False;
  if (not Assigned(pOutOpen)) or (pOutNum() = 0) then begin OutErr := 'No sound device found.'; Notify; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := OUT_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := OUT_RATE * 2;
  if pOutOpen(hOut, UINT(-1), @fmt, 0, 0, 0) <> 0 then begin OutErr := 'The sound device would not open at 44100 samples/s.'; Notify; Exit; end;
  { the system volume goes to full while the program runs (the frames themselves carry the loudness) }
  v := 0;
  if pGetVol(0, @v) = 0 then begin OldVol := v; HaveOldVol := True; end;
  pSetVol(0, $FFFFFFFF); pSetVol(hOut, $FFFFFFFF);
  OutOk := True; Notify;
  for i := 0 to OUT_NBUF - 1 do playing[i] := False;
  k := 0;
  while not Quit do
  begin
    if playing[k] then
    begin
      while ((OutHdr[k].flags and 1) = 0) and not Quit do Sleep(5);
      pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
      playing[k] := False;
    end;
    if Quit then Break;
    sound := FillOut(OutBuf[k]);
    if sound then
    begin
      { this buffer sounds in about OUT_NBUF buffers' time: keep the microphone shut until it is over }
      QuietUntil := GetTickCount + (OUT_NBUF + 1) * 100 + 80;
      if not OutPlaying then begin OutPlaying := True; Notify; end;
    end
    else if OutPlaying and (LongInt(GetTickCount - QuietUntil) > 0) then begin OutPlaying := False; Notify; end;
    FillChar(OutHdr[k], SizeOf(TWaveHdr), 0);
    OutHdr[k].data := @OutBuf[k][0];
    OutHdr[k].len := OUT_N * 2;
    if pOutPrep(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then
      if pOutWrite(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then playing[k] := True;
    if not playing[k] then Sleep(100);
    k := (k + 1) mod OUT_NBUF;
  end;
  pOutReset(hOut);
  for k := 0 to OUT_NBUF - 1 do if playing[k] then pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
  pOutClose(hOut);
  if HaveOldVol then pSetVol(0, OldVol);
end;

{ ---------- in ---------- }

procedure AudioAddMap(const m: TBitMap);
begin
  EnterCriticalSection(Lock);
  if PendingN < 8 then begin PendingMaps[PendingN] := m; Inc(PendingN); end;
  LeaveCriticalSection(Lock);
end;

function AudioTake(var m: TGotMsg): Boolean;
begin
  EnterCriticalSection(Lock);
  Result := GotHead <> GotTail;
  if Result then begin m := Got[GotTail]; GotTail := (GotTail + 1) mod RXQ; end;
  LeaveCriticalSection(Lock);
end;

function AudioTakeTrain(var t: TTrainResult): Boolean;
begin
  EnterCriticalSection(Lock);
  Result := TrainHead <> TrainTail;
  if Result then begin t := TrainQ[TrainTail]; TrainTail := (TrainTail + 1) mod 4; end;
  LeaveCriticalSection(Lock);
end;

procedure Collect(var r: TRx);
var m: TRxMsg; c: Integer;
begin
  while RxTake(r, m) do
  begin
    EnterCriticalSection(Lock);
    Got[GotHead].ch := r.ch; Got[GotHead].msg := m;
    GotHead := (GotHead + 1) mod RXQ;
    if GotHead = GotTail then GotTail := (GotTail + 1) mod RXQ;
    LeaveCriticalSection(Lock);
    Inc(FramesIn);
    Notify;
  end;
  if r.trainReady then
  begin
    r.trainReady := False;
    EnterCriticalSection(Lock);
    TrainQ[TrainHead].ch := r.ch;
    for c := 0 to MAXCAR - 1 do TrainQ[TrainHead].snr10[c] := r.trainSnr10[c];
    TrainHead := (TrainHead + 1) mod 4;
    LeaveCriticalSection(Lock);
    Notify;
  end;
end;

function InThread(param: Pointer): DWORD; API;
var fmt: TWaveFormat; i, k, n, pk, v, fails0: Integer; conv: array[0..IN_N * 2] of SmallInt;
    t0, now: LongWord; counted: Int64; r100, lastSet: Int64; peakAt: LongWord; m: TBitMap; behind: Boolean;
begin
  Result := 0;
  InOk := False;
  if (not Assigned(pInOpen)) or (pInNum() = 0) then begin InErr := 'No microphone found.'; Notify; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := 44100; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := 88200;
  if pInOpen(hIn, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    InErr := 'The microphone would not open (while the sound plays).';
    Notify; Exit;
  end;
  for k := 0 to IN_NBUF - 1 do
  begin
    FillChar(InHdr[k], SizeOf(TWaveHdr), 0);
    InHdr[k].data := @InBuf[k][0];
    InHdr[k].len := IN_N * 2;
    pInPrep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  end;
  RsInit(Rs, InRate100, Int64(MRATE) * 100, True);
  lastSet := InRate100;
  pInStart(hIn);
  InOk := True; Notify;
  k := 0; counted := 0; t0 := 0; pk := 0; peakAt := GetTickCount; fails0 := 0;
  while not Quit do
  begin
    if (InHdr[k].flags and 1) = 0 then begin Sleep(10); Continue; end;
    n := InHdr[k].recorded div 2;
    now := GetTickCount;
    { behind: every buffer is already full, so sound is being lost while this thread catches up.
      Then this buffer is not listened to (it would only make the lag worse), and the rate is not
      measured (lost sound would make it look slow). }
    behind := True;
    for i := 1 to IN_NBUF - 1 do if (InHdr[(k + i) mod IN_NBUF].flags and 1) = 0 then behind := False;
    if behind then begin Inc(Overruns); t0 := 0; counted := 0; end;
    { the real rate: samples delivered against the clock, from 2 s after the start (when the buffers flow evenly) }
    counted := counted + n;
    if (t0 = 0) and (counted >= 2 * 44100) then begin t0 := now; counted := 0; end
    else if (t0 <> 0) and (now - t0 >= 10000) then
    begin
      r100 := counted * 100000 div (now - t0);
      { only a believable rate (the Jornada 720 measured 43,230 to 43,310 against 44,100) }
      if (r100 >= 4200000) and (r100 <= 4550000) then
      begin
        if Abs(r100 - lastSet) * 1000 > lastSet then          { more than 0.1 % off: use it at once }
        begin
          InRate100 := r100; lastSet := r100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
        end
        else if Abs(r100 - lastSet) * 10000 > lastSet then     { more than 0.01 %: move to it }
        begin
          InRate100 := (InRate100 * 3 + r100) div 4; lastSet := InRate100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
        end;
        RateMeasured := True;
      end
      else RateOdd := r100;
      if now - t0 > 60000 then begin t0 := now; counted := 0; end;    { keep measuring, over the last minute }
    end;
    { loudness for the screen }
    for i := 0 to n - 1 do begin v := Abs(InBuf[k][i]); if v > pk then pk := v; end;
    if now - peakAt >= 500 then begin InPeak := pk; pk := 0; peakAt := now; Notify; end;
    { while the handheld itself plays, the microphone only hears that }
    if LongInt(now - QuietUntil) < 0 then
      for i := 0 to n - 1 do InBuf[k][i] := 0;
    { new maps, from the main thread }
    EnterCriticalSection(Lock);
    for i := 0 to PendingN - 1 do
    begin
      m := PendingMaps[i];
      if m.ch = CH_SD then RxAddMap(RxSD, m) else if m.ch = CH_FD then RxAddMap(RxFD, m);
    end;
    PendingN := 0;
    LeaveCriticalSection(Lock);
    if not behind then
    begin
      i := RsProcess(Rs, InBuf[k], 0, n, conv, 0);
      RxPush(RxSD, conv, 0, i);
      Collect(RxSD);
      if ListenFast then begin RxPush(RxFD, conv, 0, i); Collect(RxFD); end;
    end;
    if RxSD.fails + RxFD.fails <> fails0 then begin fails0 := RxSD.fails + RxFD.fails; FramesBad := fails0; Notify; end;
    InHdr[k].flags := InHdr[k].flags and not DWORD(1);       { done: no longer (it stays prepared) }
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
    k := (k + 1) mod IN_NBUF;
  end;
  pInStop(hIn); pInReset(hIn);
  for k := 0 to IN_NBUF - 1 do pInUnprep(hIn, @InHdr[k], SizeOf(TWaveHdr));
  pInClose(hIn);
end;

procedure AudioStart;
var tid: DWORD;
begin
  if not InitDone then begin InitializeCriticalSection(Lock); InitDone := True; end;
  Quit := False;
  RxInit(RxSD, CH_SD); RxInit(RxFD, CH_FD);
  hOutThread := CreateThread(nil, 0, @OutThread, nil, 0, tid);
  if hOutThread <> 0 then SetThreadPriority(hOutThread, THREAD_PRIORITY_ABOVE_NORMAL);
  hInThread := CreateThread(nil, 0, @InThread, nil, 0, tid);
end;

procedure AudioStop;
var n: Integer;
begin
  Quit := True;
  n := 0;
  if hOutThread <> 0 then while (WaitForSingleObject(hOutThread, 100) <> WAIT_OBJECT_0) and (n < 30) do Inc(n);
  n := 0;
  if hInThread <> 0 then while (WaitForSingleObject(hInThread, 100) <> WAIT_OBJECT_0) and (n < 30) do Inc(n);
end;

end.
