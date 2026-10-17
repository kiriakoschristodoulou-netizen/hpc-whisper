unit waudio;
{ Whisper Tools: the handheld's sound, both ways, taking turns.

  The Jornada 720's sound chip cannot play and record at once: with the
  microphone open, nothing came out of the speaker (device test, 16 October
  2026). So one thread does both in turn. LISTEN: the microphone is open and
  the speaker closed. TALK: the microphone is closed, the speaker opens, plays
  a short inaudible lead-in (so that whatever the chip does while it wakes up
  happens before the frame), then every queued frame, then a moment of
  silence, and closes again.

  The microphone runs at its own real rate (the Jornada 720 says 44,100 but
  delivers about 43,230): it is measured against the clock, over all the
  listening turns together, and the sound converted to the modem rate with
  it. The last 6 seconds of what the microphone heard are kept for the
  pairing check, and a 2 kHz marker of the check is watched for all the time.

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
  IN_RATE = 44100;
  IN_N = 4410;
  IN_NBUF = 6;
  OUTQ = 16;
  RXQ = 32;
  RING_N = IN_RATE * 6;               { the last 6 seconds of the microphone }
  LEAD_MS = 150;                      { lead-in before each turn of sound }
  TAIL_MS = 150;                      { silence after it }

type
  TSamplesArr = TSamples;
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
  InRate100: Int64 = 0;                { the microphone's real rate x 100 (0 = not known: the rate it claims) }
  RateSource: Integer = 0;             { 0 = what it claims, 1 = measured, 2 = calibrated by Pair (then saved) }
  ListenFast: Boolean = False;         { also listen on the fast down channel (files, remote, link check) }
  FullDuplex: Boolean = False;         { keep the microphone open while playing (sound chips that can) }
  { state, for the screen }
  OutOk, InOk: Boolean;                { the device opened at least once }
  OutErr, InErr: UnicodeString;
  OutPlaying: Boolean;                 { a turn of sound is going }
  InPeak: Integer;                     { loudest sample of the last half second }
  RateMeasured: Boolean;
  FramesOut, FramesIn, FramesBad: Integer;
  Overruns: Integer;                   { buffers not listened to: the processor fell behind }
  RateOdd: Int64;                      { an unbelievable rate measurement (x 100), 0 = none }
  Turns: Integer;                      { turns of sound played }
  LastTurnAt: LongWord;                { when the last one ended (GetTickCount) }
  LastTurnPeak: Integer;               { its loudest sample, % of full scale }
  LastTurnMs: Integer;                 { how long it lasted }
  OpenOutFails, OpenInFails: Integer;
  { the pairing check's marker: when it was heard, and where in the ring it starts }
  PairMarkAt: LongWord = 0;
  PairMarkPos: Int64 = 0;
  MissingNames: UnicodeString = '';

procedure AudioResolve;
procedure AudioStart;
procedure AudioStop;
{ the microphone's rate (x 100) measured by Pair against the phone's clock }
procedure AudioCalibrate(r100: Int64);
{ queue a frame (44,100 samples/s); False when the queue is full }
function AudioSend(const x: TSamplesArr): Boolean;
function AudioQueued: Integer;                       { frames waiting or sounding; 0 = quiet }
function AudioTake(var m: TGotMsg): Boolean;         { a message heard }
function AudioTakeTrain(var t: TTrainResult): Boolean;
procedure AudioAddMap(const m: TBitMap);             { a map for what the phone sends }
{ copies what the microphone heard, from ring position pos (total samples counted from the start), n samples;
  returns how many were still there }
function AudioRingCopy(pos: Int64; var x: array of SmallInt; n: Integer): Integer;
function AudioRingPos: Int64;

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
  OutOpen, InOpen: Boolean;
  hThread: THandle;
  OldVol: DWORD; HaveOldVol: Boolean = False;
  OutHdr: array[0..OUT_NBUF - 1] of TWaveHdr;
  OutBuf: array[0..OUT_NBUF - 1, 0..OUT_N - 1] of SmallInt;
  OutBusy: array[0..OUT_NBUF - 1] of Boolean;
  InHdr: array[0..IN_NBUF - 1] of TWaveHdr;
  InBuf: array[0..IN_NBUF - 1, 0..IN_N - 1] of SmallInt;
  InK: Integer;
  Q: array[0..OUTQ - 1] of TSamplesArr;
  QHead, QTail: Integer;
  Cur: TSamplesArr; CurPos: Integer;
  Sounding: Boolean;                   { main thread's view: a turn is going or about to }
  RxSD, RxFD: TRx;
  Rs: TResampler;
  Got: array[0..RXQ - 1] of TGotMsg;
  GotHead, GotTail: Integer;
  TrainQ: array[0..3] of TTrainResult;
  TrainHead, TrainTail: Integer;
  PendingMaps: array[0..7] of TBitMap;
  PendingN: Integer = 0;
  InitDone: Boolean = False;
  Ring: array[0..RING_N - 1] of SmallInt;
  RingPos: Int64 = 0;                  { samples written so far }
  Lead: TSamplesArr;
  { rate measurement over all listening turns }
  RateSamples: Int64 = 0; RateMs: Int64 = 0; LastSet: Int64 = 0;
  { marker watch }
  MkCoef: LongInt; MkS1, MkS2: Int64; MkN: Integer; MkBg: Int64 = 0; MkRun: Integer = 0; MkRunPos: Int64;

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

{ ---------- the queue (main thread adds, sound thread takes) ---------- }

function AudioSend(const x: TSamplesArr): Boolean;
var nx: Integer;
begin
  EnterCriticalSection(Lock);
  nx := (QHead + 1) mod OUTQ;
  Result := nx <> QTail;
  if Result then begin Q[QHead] := x; QHead := nx; Sounding := True; end;
  LeaveCriticalSection(Lock);
end;

function AudioQueued: Integer;
begin
  EnterCriticalSection(Lock);
  Result := (QHead - QTail + OUTQ) mod OUTQ;
  if (Result = 0) and Sounding then Result := 1;    { still playing, or the speaker not yet closed }
  LeaveCriticalSection(Lock);
end;

function TakeFrame: Boolean;
begin
  EnterCriticalSection(Lock);
  Result := QTail <> QHead;
  if Result then
  begin
    Cur := Q[QTail]; SetLength(Q[QTail], 0);
    QTail := (QTail + 1) mod OUTQ;
    CurPos := 0;
    Inc(FramesOut);
  end;
  LeaveCriticalSection(Lock);
end;

function QueueEmpty: Boolean;
begin
  EnterCriticalSection(Lock);
  Result := QTail = QHead;
  LeaveCriticalSection(Lock);
end;

{ ---------- received messages (sound thread adds, main thread takes) ---------- }

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

{ ---------- the ring of what the microphone heard ---------- }

function AudioRingPos: Int64;
begin
  EnterCriticalSection(Lock);
  Result := RingPos;
  LeaveCriticalSection(Lock);
end;

function AudioRingCopy(pos: Int64; var x: array of SmallInt; n: Integer): Integer;
var i: Integer; p: Int64;
begin
  EnterCriticalSection(Lock);
  if pos < RingPos - RING_N then pos := RingPos - RING_N;
  if pos < 0 then pos := 0;
  Result := 0;
  for i := 0 to n - 1 do
  begin
    p := pos + i;
    if p >= RingPos then Break;
    x[i] := Ring[p mod RING_N];
    Inc(Result);
  end;
  LeaveCriticalSection(Lock);
end;

{ the 2 kHz marker of the pairing check: 10 ms blocks, at least 150 ms clearly above the background }
procedure WatchMarker(const b: array of SmallInt; n: Integer; firstPos: Int64);
var i: Integer; s0: Int64; p: Int64;
begin
  for i := 0 to n - 1 do
  begin
    s0 := b[i] + (Int64(MkCoef) * MkS1) div 65536 - MkS2;
    MkS2 := MkS1; MkS1 := s0;
    Inc(MkN);
    if MkN >= IN_RATE div 100 then
    begin
      MkS1 := MkS1 div 16; MkS2 := MkS2 div 16;
      p := (MkS1 * MkS1 + MkS2 * MkS2 - (Int64(MkCoef) * MkS1 div 65536) * MkS2) div MkN + 1;
      MkS1 := 0; MkS2 := 0; MkN := 0;
      if MkBg = 0 then MkBg := p;
      if p > MkBg * 10 then
      begin
        if MkRun = 0 then MkRunPos := firstPos + i - IN_RATE div 100;
        Inc(MkRun);
        { a test sound has two markers and a 2 kHz step: only its first counts (the others moved the
          reading 2.7 s late, so a test sound was never read: device test, 16 October 2026) }
        if (MkRun = 15) and ((PairMarkAt = 0) or (LongInt(GetTickCount - PairMarkAt) > 4500)) then
        begin PairMarkPos := MkRunPos; PairMarkAt := GetTickCount; Notify; end;
      end
      else
      begin
        MkRun := 0;
        MkBg := MkBg + (p - MkBg) div 16;                     { the background, slowly }
      end;
    end;
  end;
end;

{ ---------- the devices ---------- }

function OpenOut: Boolean;
var fmt: TWaveFormat; v: DWORD; k: Integer;
begin
  Result := False;
  if (not Assigned(pOutOpen)) or (pOutNum() = 0) then begin OutErr := 'No sound device found.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := OUT_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := OUT_RATE * 2;
  if pOutOpen(hOut, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    Inc(OpenOutFails);
    OutErr := 'The speaker would not open at 44,100 samples/s.';
    Exit;
  end;
  { the system volume goes to full while the program runs (the frames themselves carry the loudness) }
  if not HaveOldVol then
  begin
    v := 0;
    if pGetVol(0, @v) = 0 then begin OldVol := v; HaveOldVol := True; end;
  end;
  pSetVol(0, $FFFFFFFF); pSetVol(hOut, $FFFFFFFF);
  for k := 0 to OUT_NBUF - 1 do OutBusy[k] := False;
  OutOpen := True; OutOk := True; OutErr := '';
  Result := True;
end;

procedure CloseOut;
var k: Integer;
begin
  if not OutOpen then Exit;
  pOutReset(hOut);
  for k := 0 to OUT_NBUF - 1 do if OutBusy[k] then begin pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr)); OutBusy[k] := False; end;
  pOutClose(hOut);
  OutOpen := False;
end;

function OpenIn: Boolean;
var fmt: TWaveFormat; k: Integer;
begin
  Result := False;
  if (not Assigned(pInOpen)) or (pInNum() = 0) then begin InErr := 'No microphone found.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := IN_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := IN_RATE * 2;
  if pInOpen(hIn, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    Inc(OpenInFails);
    InErr := 'The microphone would not open.';
    Exit;
  end;
  for k := 0 to IN_NBUF - 1 do
  begin
    FillChar(InHdr[k], SizeOf(TWaveHdr), 0);
    InHdr[k].data := @InBuf[k][0];
    InHdr[k].len := IN_N * 2;
    pInPrep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  end;
  pInStart(hIn);
  InK := 0;
  InOpen := True; InOk := True; InErr := '';
  Result := True;
end;

procedure CloseIn;
var k: Integer;
begin
  if not InOpen then Exit;
  pInStop(hIn); pInReset(hIn);
  for k := 0 to IN_NBUF - 1 do pInUnprep(hIn, @InHdr[k], SizeOf(TWaveHdr));
  pInClose(hIn);
  InOpen := False;
end;

{ ---------- listening ---------- }

{ a measurement of the microphone's rate (x 100). The first ones replace the rate the handheld claims; once
  the rate is known (measured or calibrated by Pair), a measurement more than 1 % away is only shown (RateOdd),
  and closer ones are smoothed in. }
procedure SetRate(r100: Int64);
begin
  if (RateSource > 0) and (Abs(r100 - InRate100) * 100 > InRate100) then begin RateOdd := r100; Exit; end;
  RateOdd := 0;
  if RateSource = 0 then begin InRate100 := r100; RateSource := 1; end
  else if Abs(r100 - InRate100) * 10000 > InRate100 then InRate100 := (InRate100 * 3 + r100) div 4
  else Exit;
  LastSet := InRate100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
end;

{ Pair measured the rate against the phone's clock: it wins, whatever was measured }
procedure AudioCalibrate(r100: Int64);
begin
  InRate100 := r100; RateSource := 2; RateOdd := 0;
  RateSamples := 0; RateMs := 0;                    { measurements start again from here }
  LastSet := r100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
end;

var
  SessT0, SessLast: LongWord; SessCount: Int64; SessOn: Boolean;
  PeakAt: LongWord; Pk: Integer;
  Conv: array[0..IN_N * 2] of SmallInt;

{ one full microphone buffer, if there is one; False when there was none }
function ListenOnce: Boolean;
var k, n, i, v: Integer; now: LongWord; behind: Boolean; m: TBitMap; r100, ms: Int64;
begin
  Result := False;
  k := InK;
  if (InHdr[k].flags and 1) = 0 then Exit;
  Result := True;
  n := InHdr[k].recorded div 2;
  now := GetTickCount;
  behind := True;
  for i := 1 to IN_NBUF - 1 do if (InHdr[(k + i) mod IN_NBUF].flags and 1) = 0 then behind := False;
  if behind then Inc(Overruns);
  { the rate: samples against the clock, from half a second into each listening turn, over all of them.
    Only whole buffers count, each at the moment it arrived: the samples counted after the first buffer
    arrived, over the time to the last one (counting to the moment the microphone closed instead left out
    the part-filled last buffer, and made every turn look slow: 43,064 for about 43,230). }
  if not SessOn then
  begin
    SessCount := SessCount + n;
    if SessCount >= IN_RATE div 2 then begin SessOn := True; SessT0 := now; SessLast := now; SessCount := 0; end;
  end
  else if behind then begin SessOn := False; SessCount := 0; end
  else
  begin
    SessCount := SessCount + n; SessLast := now;
    ms := now - SessT0;
    if (ms >= 1000) and (RateMs + ms >= 8000) then
    begin
      r100 := (RateSamples + SessCount) * 100000 div (RateMs + ms);
      { what the sound card claims, give or take 5 %: anything else is a broken measurement }
      if (r100 * 20 >= Int64(IN_RATE) * 100 * 19) and (r100 * 20 <= Int64(IN_RATE) * 100 * 21) then
      begin SetRate(r100); RateMeasured := True; end
      else RateOdd := r100;
    end;
  end;
  { loudness for the screen }
  for i := 0 to n - 1 do begin v := Abs(InBuf[k][i]); if v > Pk then Pk := v; end;
  if now - PeakAt >= 500 then begin InPeak := Pk; Pk := 0; PeakAt := now; Notify; end;
  { the ring and the marker watch }
  EnterCriticalSection(Lock);
  for i := 0 to n - 1 do Ring[(RingPos + i) mod RING_N] := InBuf[k][i];
  WatchMarker(InBuf[k], n, RingPos);
  RingPos := RingPos + n;
  for i := 0 to PendingN - 1 do
  begin
    m := PendingMaps[i];
    if m.ch = CH_SD then RxAddMap(RxSD, m) else if m.ch = CH_FD then RxAddMap(RxFD, m);
  end;
  PendingN := 0;
  LeaveCriticalSection(Lock);
  if not behind then
  begin
    i := RsProcess(Rs, InBuf[k], 0, n, Conv, 0);
    RxPush(RxSD, Conv, 0, i);
    Collect(RxSD);
    if ListenFast then begin RxPush(RxFD, Conv, 0, i); Collect(RxFD); end;
    if RxSD.fails + RxFD.fails <> FramesBad then begin FramesBad := RxSD.fails + RxFD.fails; Notify; end;
  end;
  InHdr[k].flags := InHdr[k].flags and not DWORD(1);
  pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  InK := (k + 1) mod IN_NBUF;
end;

procedure EndSession;
var ms: Int64;
begin
  if SessOn then
  begin
    ms := SessLast - SessT0;
    if ms >= 1000 then begin RateSamples := RateSamples + SessCount; RateMs := RateMs + ms; end;
  end;
  SessOn := False; SessCount := 0;
end;

{ ---------- a turn of sound ---------- }

{ fills one buffer from the lead-in, the queue, and the silence after; False when there is nothing left at all }
function FillTurn(var b: array of SmallInt; var leadPos, tailLeft, peak: Integer): Boolean;
var i, take, n, v: Integer;
begin
  i := 0;
  while i < OUT_N do
  begin
    if leadPos < Length(Lead) then
    begin
      take := Length(Lead) - leadPos; if take > OUT_N - i then take := OUT_N - i;
      for n := 0 to take - 1 do b[i + n] := Lead[leadPos + n];
      Inc(leadPos, take); Inc(i, take);
      Continue;
    end;
    if CurPos >= Length(Cur) then
    begin
      SetLength(Cur, 0); CurPos := 0;
      if not TakeFrame then Break;
    end;
    take := Length(Cur) - CurPos; if take > OUT_N - i then take := OUT_N - i;
    for n := 0 to take - 1 do
    begin
      v := Cur[CurPos + n];
      b[i + n] := v;
      if Abs(v) > peak then peak := Abs(v);
    end;
    Inc(CurPos, take); Inc(i, take);
    tailLeft := TAIL_MS * OUT_RATE div 1000;                 { the silence counts from the last sound }
  end;
  { then silence }
  n := i;
  while (n < OUT_N) and (tailLeft > 0) do begin b[n] := 0; Inc(n); Dec(tailLeft); end;
  Result := n > 0;
  for i := n to OUT_N - 1 do b[i] := 0;
end;

procedure Talk;
var k, leadPos, tailLeft, peak, playing, i: Integer; t0: LongWord; more: Boolean;
begin
  if not FullDuplex then begin EndSession; CloseIn; end;
  if not OpenOut then
  begin
    { no speaker: drop what was queued, listen again }
    EnterCriticalSection(Lock);
    while QTail <> QHead do begin SetLength(Q[QTail], 0); QTail := (QTail + 1) mod OUTQ; end;
    Sounding := False;
    LeaveCriticalSection(Lock);
    Notify;
    Sleep(300);
    Exit;
  end;
  OutPlaying := True; Notify;
  t0 := GetTickCount;
  leadPos := 0; tailLeft := TAIL_MS * OUT_RATE div 1000; peak := 0;
  k := 0; more := True;
  while not Quit do
  begin
    if OutBusy[k] then
    begin
      while ((OutHdr[k].flags and 1) = 0) and not Quit do Sleep(5);
      pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
      OutBusy[k] := False;
    end;
    if Quit then Break;
    if more then more := FillTurn(OutBuf[k], leadPos, tailLeft, peak);
    if more then
    begin
      FillChar(OutHdr[k], SizeOf(TWaveHdr), 0);
      OutHdr[k].data := @OutBuf[k][0];
      OutHdr[k].len := OUT_N * 2;
      if pOutPrep(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then
        if pOutWrite(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then OutBusy[k] := True;
      if not OutBusy[k] then begin OutErr := 'The speaker stopped taking sound.'; Break; end;
    end
    else
    begin
      { nothing more: wait for what is playing, then close }
      playing := 0;
      for i := 0 to OUT_NBUF - 1 do if OutBusy[i] then Inc(playing);
      if playing = 0 then Break;
    end;
    k := (k + 1) mod OUT_NBUF;
  end;
  CloseOut;
  Inc(Turns);
  LastTurnAt := GetTickCount; LastTurnMs := LastTurnAt - t0;
  LastTurnPeak := peak * 100 div 32768;
  OutPlaying := False;
  EnterCriticalSection(Lock);
  if QTail = QHead then Sounding := False;
  LeaveCriticalSection(Lock);
  Notify;
end;

function AudioThread(param: Pointer): DWORD; API;
var idle: Boolean;
begin
  Result := 0;
  while not Quit do
  begin
    if not QueueEmpty then
    begin
      Talk;
      Continue;
    end;
    if not InOpen then
      if not OpenIn then begin Notify; Sleep(500); Continue; end;
    idle := not ListenOnce;
    if idle then Sleep(10);
  end;
  CloseOut;
  EndSession;
  CloseIn;
  if HaveOldVol then pSetVol(0, OldVol);
end;

procedure AudioStart;
var tid: DWORD; i: Integer; ramp: Integer;
begin
  if not InitDone then begin InitializeCriticalSection(Lock); InitDone := True; end;
  Quit := False;
  RxInit(RxSD, CH_SD); RxInit(RxFD, CH_FD);
  if InRate100 <= 0 then InRate100 := Int64(IN_RATE) * 100;     { not known yet: what it claims }
  RsInit(Rs, InRate100, Int64(MRATE) * 100, True);
  LastSet := InRate100;
  { the lead-in: a quiet 21.7 kHz tone, faded in and out (inaudible; it only wakes the sound path) }
  SetLength(Lead, LEAD_MS * OUT_RATE div 1000);
  ramp := OUT_RATE div 100;
  for i := 0 to High(Lead) do
  begin
    Lead[i] := (1200 * SinI(Integer((Int64(21700) * i * 65536 div OUT_RATE) and $FFFF))) div 16384;
    if i < ramp then Lead[i] := Lead[i] * i div ramp;
    if High(Lead) - i < ramp then Lead[i] := Lead[i] * (High(Lead) - i) div ramp;
  end;
  MkCoef := 2 * CosI(Integer((Int64(2000) * 65536 div IN_RATE) and $FFFF)) * 4;
  hThread := CreateThread(nil, 0, @AudioThread, nil, 0, tid);
  if hThread <> 0 then SetThreadPriority(hThread, THREAD_PRIORITY_ABOVE_NORMAL);
end;

procedure AudioStop;
var n: Integer;
begin
  Quit := True;
  n := 0;
  if hThread <> 0 then while (WaitForSingleObject(hThread, 100) <> WAIT_OBJECT_0) and (n < 40) do Inc(n);
end;

end.
