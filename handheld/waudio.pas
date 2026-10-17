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

uses Windows, w3core, w3dsp, w3rx, w3tx, wlog;

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
  { play at the rate the sound chip really runs at (measured from the microphone, which runs on the same
    clock), so that Windows does not convert: the HP Jornada 720's chip runs at about 43,200, and Windows
    turned 44,100 into that by dropping samples, which tore the silent channel apart (the phone read 6 of 23
    frames; 16 dB at best, 46 dB without). Off: 44,100 always. }
  SpeakerNative: Boolean = True;
  RateTrusted: Boolean = False;        { the microphone's rate is known well enough to play at (kept, Pair, or a minute measured) }
  OutRateNote: UnicodeString = 'at 44,100/s';  { what the speaker plays at, in words }
  { state, for the screen }
  OutOk, InOk: Boolean;                { the device opened at least once }
  OutErr, InErr: UnicodeString;
  OutPlaying: Boolean;                 { a turn of sound is going }
  InPeak: Integer;                     { loudest sample of the last half second }
  RateMeasured: Boolean;
  FramesOut, FramesIn, FramesBad: Integer;
  Overruns: Integer;                   { buffers not listened to: the processor fell behind }
  FastPauses: Integer;                 { times the fast receiver paused to leave the processor to the rest }
  { pieces of a file from the phone: begun (their header read), and lost after that; when the last one began }
  FilePieces, FileLost: Integer;
  FilePieceAt: LongWord;
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
{ the rate the speaker should play at, from the measured one; called by the main thread when nothing is queued }
procedure AudioChooseRate;
{ queue a frame (TxRate samples/s); False when the queue is full }
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
  RateSamples: Int64 = 0; RateMs: Int64 = 0; LastSet: Int64 = 0; RefusedRate: Integer = 0; RateLogged: Boolean = False;
  { marker watch }
  MkCoef, MkCoefL, MkCoefH: LongInt; MkS1, MkS2, MkL1, MkL2, MkH1, MkH2: Int64; MkN: Integer; MkBg: Int64 = 0; MkRun: Integer = 0; MkRunPos: Int64;

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
  if Result then Log('talk: playing a sound of ' + LI(Int64(Length(Cur)) * 1000 div TxRate) + ' ms');
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
var m: TRxMsg; c, k: Integer;
begin
  while RxTake(r, m) do
  begin
    EnterCriticalSection(Lock);
    Got[GotHead].ch := r.ch; Got[GotHead].msg := m;
    GotHead := (GotHead + 1) mod RXQ;
    if GotHead = GotTail then GotTail := (GotTail + 1) mod RXQ;
    LeaveCriticalSection(Lock);
    Inc(FramesIn);
    Log('heard ' + LChan(r.ch) + ' ' + LDescribe(m.typ, m.data, m.len) + ', quality ' + LI(m.snr10 div 10) + ' dB, '
      + LI(m.fixed) + ' bytes corrected');
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
    c := 0; for k := 0 to Chans[r.ch].n - 1 do c := c + r.trainSnr10[k];
    Log('heard ' + LChan(r.ch) + ' TRAIN, average quality ' + LI(c div Chans[r.ch].n div 10) + ' dB');
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

{ the 2 kHz marker of the pairing check: 10 ms blocks, at least 150 ms clearly above the background, and a
  pure tone: far above 1.6 and 2.4 kHz (a key click or a voice fills those too, and set it off: 3.7 logs) }
procedure WatchMarker(const b: array of SmallInt; n: Integer; firstPos: Int64);
var i: Integer; s0: Int64; p, pl, ph: Int64;
  function Pow(var s1, s2: Int64; c: LongInt): Int64;
  begin
    s1 := s1 div 16; s2 := s2 div 16;
    Result := (s1 * s1 + s2 * s2 - (Int64(c) * s1 div 65536) * s2) div MkN + 1;
    s1 := 0; s2 := 0;
  end;
begin
  for i := 0 to n - 1 do
  begin
    s0 := b[i] + (Int64(MkCoef) * MkS1) div 65536 - MkS2;
    MkS2 := MkS1; MkS1 := s0;
    s0 := b[i] + (Int64(MkCoefL) * MkL1) div 65536 - MkL2;
    MkL2 := MkL1; MkL1 := s0;
    s0 := b[i] + (Int64(MkCoefH) * MkH1) div 65536 - MkH2;
    MkH2 := MkH1; MkH1 := s0;
    Inc(MkN);
    if MkN >= IN_RATE div 100 then
    begin
      p := Pow(MkS1, MkS2, MkCoef); pl := Pow(MkL1, MkL2, MkCoefL); ph := Pow(MkH1, MkH2, MkCoefH);
      MkN := 0;
      if MkBg = 0 then MkBg := p;
      if (p > MkBg * 10) and (p > 4 * (pl + ph)) then
      begin
        if MkRun = 0 then MkRunPos := firstPos + i - IN_RATE div 100;
        Inc(MkRun);
        { a test sound has two markers and a 2 kHz step: only its first counts (the others moved the
          reading 2.7 s late, so a test sound was never read: device test, 16 October 2026) }
        if (MkRun = 15) and ((PairMarkAt = 0) or (LongInt(GetTickCount - PairMarkAt) > 4500)) then
        begin PairMarkPos := MkRunPos; PairMarkAt := GetTickCount; Log('pair: a 2 kHz marker heard'); Notify; end;
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
  if (not Assigned(pOutOpen)) or (pOutNum() = 0) then begin OutErr := 'No sound device found.'; Log('speaker: no sound device'); Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := TxRate; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := TxRate * 2;
  if pOutOpen(hOut, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    Inc(OpenOutFails);
    OutErr := 'The speaker would not open at ' + UnicodeString(LI(TxRate)) + ' samples/s.';
    Log('speaker: would not open at ' + LI(TxRate) + '/s');
    if TxRate <> 44100 then begin RefusedRate := TxRate; Log('speaker: back to 44,100 from the next sound'); end;
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
  if (not Assigned(pInOpen)) or (pInNum() = 0) then begin InErr := 'No microphone found.'; Log('microphone: none found'); Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := IN_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := IN_RATE * 2;
  if pInOpen(hIn, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    Inc(OpenInFails);
    InErr := 'The microphone would not open.';
    Log('microphone: would not open');
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

{ a measurement of the microphone's rate (x 100), over spanMs of listening in all. The first one replaces the
  rate the handheld claims. Once the rate is known, a reading more than 0.25 % away is only shown (RateOdd):
  a reading that far off comes from a moment the processor was held up. But a reading over a whole minute
  or more of listening is the best there is, and wins (a rate kept from before may have been wrong).
  Small changes (under 0.01 %) are left out: every change moves the receiver's tones a little. }
procedure SetRate(r100: Int64; spanMs: Int64);
begin
  if (RateSource > 0) and (spanMs < 60000) and (Abs(r100 - InRate100) * 400 > InRate100) then
  begin
    if Abs(RateOdd - r100) * 2000 > r100 then Log('microphone rate: an odd reading of ' + LI(r100 div 100) + ' not used (kept ' + LI(InRate100 div 100) + ')');
    RateOdd := r100; Exit;
  end;
  RateOdd := 0;
  if RateSource = 0 then RateSource := 1
  else if Abs(r100 - InRate100) * 10000 <= InRate100 then Exit;
  if spanMs >= 60000 then begin RateSource := 1; RateTrusted := True; end;
  InRate100 := r100;
  LastSet := InRate100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
  Log('microphone rate now ' + LI(InRate100 div 100) + '.' + LI((InRate100 mod 100) div 10) + ' (over ' + LI(spanMs div 1000) + ' s of listening)');
end;

{ Pair measured the rate against the phone's clock: it wins, whatever was measured }
procedure AudioCalibrate(r100: Int64);
begin
  InRate100 := r100; RateSource := 2; RateOdd := 0; RateTrusted := True;
  Log('microphone rate calibrated by Pair: ' + LI(r100 div 100));
  LastSet := r100; RsSetRates(Rs, InRate100, Int64(MRATE) * 100);
end;

var
  { the diagnostics log: how busy listening keeps the processor, over each 5 s }
  StAt: LongWord = 0; StBufs: Integer = 0; StBusy: Integer = 0; StMax: Integer = 0; StBehind: Integer = 0;
  StFastBufs: Integer = 0; PrevFast: Boolean = False;
  FastPauseUntil: LongWord = 0; FastWinAt: LongWord = 0; FastMs: Integer = 0;
  PrevHdrs, PrevFails, PrevTrigs, PrevStarts, PrevFrames, PrevGated: array[0..1] of Integer;
  LastHdrFile: array[0..1] of Boolean;

procedure LogRx(var r: TRx; i: Integer);
begin
  if r.hdrs <> PrevHdrs[i] then
  begin
    PrevHdrs[i] := r.hdrs;
    LastHdrFile[i] := (r.hdrTyp = T_FILE_OFFER) or (r.hdrTyp = T_FILE_DATA);
    if LastHdrFile[i] then begin Inc(FilePieces); FilePieceAt := GetTickCount; Notify; end;
    Log(LChan(r.ch) + ' frame coming: ' + LType(r.hdrTyp) + ', ' + LI(r.hdrLen) + ' bytes, '
      + LI(r.hdrSym) + ' symbols (' + LI(Int64(r.hdrSym) * NSYM * 1000 div MRATE) + ' ms)');
  end;
  if r.fails <> PrevFails[i] then
  begin
    PrevFails[i] := r.fails;
    Log(LChan(r.ch) + ' frame lost: ' + r.lastFail);
    { after the header (a header failure means no file piece began); compared by hand: no memcmp on the device }
    if LastHdrFile[i] and not ((Length(r.lastFail) = 6) and (r.lastFail[1] = 'h')) then begin Inc(FileLost); Notify; end;
    LastHdrFile[i] := False;
  end;
end;

procedure LogStats(now: LongWord);
begin
  if StBufs > 0 then
    Log('listening ' + LI((now - StAt) div 100 div 10) + '.' + LI((now - StAt) div 100 mod 10) + ' s: ' + LI(StBufs) + ' buffers, processor '
      + LI(StBusy div StBufs) + '% busy (worst buffer ' + LI(StMax) + ' ms of 100), skipped ' + LI(StBehind)
      + ', fast receiver on for ' + LI(StFastBufs) + ', loudest ' + LI(InPeak * 100 div 32768) + '%; SD seen '
      + LI(RxSD.trigs - PrevTrigs[0]) + ' found ' + LI(RxSD.starts - PrevStarts[0]) + ' read ' + LI(RxSD.frames - PrevFrames[0])
      + ', not ours ' + LI(RxSD.gated - PrevGated[0]) + '; FD seen ' + LI(RxFD.trigs - PrevTrigs[1]) + ' found ' + LI(RxFD.starts - PrevStarts[1]) + ' read ' + LI(RxFD.frames - PrevFrames[1]) + ', not ours ' + LI(RxFD.gated - PrevGated[1]));
  PrevTrigs[0] := RxSD.trigs; PrevStarts[0] := RxSD.starts; PrevFrames[0] := RxSD.frames;
  PrevTrigs[1] := RxFD.trigs; PrevStarts[1] := RxFD.starts; PrevFrames[1] := RxFD.frames;
  PrevGated[0] := RxSD.gated; PrevGated[1] := RxFD.gated;
  StAt := now; StBufs := 0; StBusy := 0; StMax := 0; StBehind := 0; StFastBufs := 0;
end;

var
  SessT0, SessLast: LongWord; SessCount, SessCountAt: Int64; SessOn: Boolean; RateAt: LongWord = 0;
  PeakAt: LongWord; Pk: Integer;
  Conv: array[0..IN_N * 2] of SmallInt;

procedure EndSession;
var ms: Int64;
begin
  if SessOn then
  begin
    ms := SessLast - SessT0;
    if ms >= 1000 then begin RateSamples := RateSamples + SessCountAt; RateMs := RateMs + ms; end;
  end;
  SessOn := False; SessCount := 0; SessCountAt := 0;
end;

{ one full microphone buffer, if there is one; False when there was none }
function ListenOnce: Boolean;
var k, n, i, v, busy: Integer; now, t1, t2: LongWord; behind, fresh: Boolean; m: TBitMap; r100, ms: Int64;
begin
  Result := False;
  k := InK;
  if (InHdr[k].flags and 1) = 0 then Exit;
  Result := True;
  n := InHdr[k].recorded div 2;
  now := GetTickCount;
  behind := True;
  for i := 1 to IN_NBUF - 1 do if (InHdr[(k + i) mod IN_NBUF].flags and 1) = 0 then behind := False;
  if behind then
  begin
    Inc(Overruns);
    if StBehind = 0 then Log('listening fell behind: a buffer of sound was skipped (the processor is too busy)');
    Inc(StBehind);
  end;
  if StAt = 0 then StAt := now;
  if ListenFast <> PrevFast then
  begin
    PrevFast := ListenFast;
    if ListenFast then Log('fast receiver on') else Log('fast receiver off');
  end;
  { the rate: samples against the clock, from half a second into each listening turn, over all of them.
    Only whole buffers count, and only one that has just arrived gives the time (no other one waiting
    behind it): a buffer taken late, after the processor was held up, made the microphone look fast
    (43,600 for 43,200: 3.7, device log). The samples counted after the first such buffer, up to the last
    such one, over the time between them. }
  fresh := (InHdr[(k + 1) mod IN_NBUF].flags and 1) = 0;
  if not SessOn then
  begin
    SessCount := SessCount + n;
    if (SessCount >= IN_RATE div 2) and fresh then begin SessOn := True; SessT0 := now; SessLast := now; SessCount := 0; SessCountAt := 0; end;
  end
  else if behind then begin EndSession; SessCount := 0; end
  else
  begin
    SessCount := SessCount + n;
    if fresh then begin SessLast := now; SessCountAt := SessCount; end;
    ms := SessLast - SessT0;
    if (ms >= 1000) and (RateMs + ms >= 8000) and (now - RateAt >= 2000) then
    begin
      RateAt := now;
      r100 := (RateSamples + SessCountAt) * 100000 div (RateMs + ms);
      { what the sound card claims, give or take 5 %: anything else is a broken measurement }
      if (r100 * 20 >= Int64(IN_RATE) * 100 * 19) and (r100 * 20 <= Int64(IN_RATE) * 100 * 21) then
      begin SetRate(r100, RateMs + ms); RateMeasured := True; end
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
    t1 := GetTickCount;
    i := RsProcess(Rs, InBuf[k], 0, n, Conv, 0);
    RxPush(RxSD, Conv, 0, i);
    Collect(RxSD);
    { the fast receiver, within a budget: if it takes more than half the processor over a second, it pauses
      for three (the screen and typing come first; a frame in that time is lost, and asked for again) }
    if ListenFast and (LongInt(now - FastPauseUntil) >= 0) then
    begin
      t2 := GetTickCount;
      RxPush(RxFD, Conv, 0, i); Collect(RxFD); Inc(StFastBufs);
      FastMs := FastMs + Integer(GetTickCount - t2);
    end;
    if now - FastWinAt >= 1000 then
    begin
      if FastMs > 500 then
      begin
        FastPauseUntil := now + 3000; Inc(FastPauses);
        Log('fast receiver paused for 3 s: it took ' + LI(FastMs) + ' ms of the last ' + LI(now - FastWinAt) + ' (the processor is needed elsewhere)');
      end;
      FastWinAt := now; FastMs := 0;
    end;
    if RxSD.fails + RxFD.fails <> FramesBad then begin FramesBad := RxSD.fails + RxFD.fails; Notify; end;
    busy := GetTickCount - t1;
    Inc(StBufs); Inc(StBusy, busy); if busy > StMax then StMax := busy;
    LogRx(RxSD, 0); LogRx(RxFD, 1);
  end;
  if now - StAt >= 5000 then LogStats(now);
  InHdr[k].flags := InHdr[k].flags and not DWORD(1);
  pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  InK := (k + 1) mod IN_NBUF;
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
    tailLeft := TAIL_MS * TxRate div 1000;                   { the silence counts from the last sound }
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
  Log('talk: microphone closed, speaker opening');
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
  leadPos := 0; tailLeft := TAIL_MS * TxRate div 1000; peak := 0;
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
  if OutErr <> '' then Log('talk: the speaker stopped taking sound');
  Log('talk: turn over after ' + LI(LastTurnMs) + ' ms, loudest ' + LI(LastTurnPeak) + '%; listening again');
  EnterCriticalSection(Lock);
  if QTail = QHead then Sounding := False;
  LeaveCriticalSection(Lock);
  Notify;
end;

function AudioThread(param: Pointer): DWORD; API;
var idle: Boolean; last, now: LongWord;
begin
  Result := 0;
  last := GetTickCount;
  while not Quit do
  begin
    now := GetTickCount;
    if now - last > 700 then Log('sound thread: ' + LI(now - last) + ' ms without a turn of its loop (it was held up)');
    last := now;
    LogTick(False);
    if not QueueEmpty then
    begin
      Talk;
      last := GetTickCount;
      Continue;
    end;
    if not InOpen then
    begin
      if not OpenIn then begin Notify; Sleep(500); Continue; end;
      Log('microphone open, listening');
    end;
    idle := not ListenOnce;
    if idle then Sleep(10);
  end;
  CloseOut;
  EndSession;
  CloseIn;
  if HaveOldVol then pSetVol(0, OldVol);
  Log('sound thread: stopped');
end;

function AudioThreadRtl(param: Pointer): PtrInt;
begin
  Result := AudioThread(param);
end;

{ the lead-in: a quiet tone, faded in and out (inaudible; it only wakes the sound path). 21.7 kHz, or just
  under half the rate, for a chip that runs slower }
procedure MakeLead;
var i, ramp, f: Integer;
begin
  f := 21700;
  if f > TxRate div 2 - 300 then f := TxRate div 2 - 300;
  SetLength(Lead, LEAD_MS * TxRate div 1000);
  ramp := TxRate div 100;
  for i := 0 to High(Lead) do
  begin
    Lead[i] := (1200 * SinI(Integer((Int64(f) * i * 65536 div TxRate) and $FFFF))) div 16384;
    if i < ramp then Lead[i] := Lead[i] * i div ramp;
    if High(Lead) - i < ramp then Lead[i] := Lead[i] * (High(Lead) - i) div ramp;
  end;
end;

procedure AudioChooseRate;
var want: Integer; fmt: TWaveFormat; h: THandle; ok: Boolean;
begin
  want := 44100;
  if SpeakerNative and RateTrusted and (InRate100 > 0) then want := Integer((InRate100 + 50) div 100);
  if want = RefusedRate then want := 44100;
  { what the screen says, and the log once: why this rate }
  if want = 44100 then
  begin
    if not SpeakerNative then OutRateNote := 'at 44,100/s, converted by Windows (Settings)'
    else if RefusedRate <> 0 then OutRateNote := 'at 44,100/s: the card does not take its own rate (' + UnicodeString(LI(RefusedRate)) + ')'
    else OutRateNote := 'at 44,100/s until the chip''s own rate is known (Pair, or a minute of listening; ' + UnicodeString(LI(RateMs div 1000)) + ' s so far)';
  end;
  if (want = TxRate) and not RateLogged then
  begin
    RateLogged := True;
    Log('speaker: plays at ' + LI(TxRate) + '/s (own rate wanted ' + LI(Ord(SpeakerNative)) + ', rate trusted ' + LI(Ord(RateTrusted))
      + ', microphone ' + LI(InRate100 div 100) + ', measured over ' + LI(RateMs div 1000) + ' s, refused ' + LI(RefusedRate) + ')');
  end;
  if want = TxRate then Exit;
  RateLogged := False;
  if want <> 44100 then
  begin
    { does the sound card take it? (asked without opening it) }
    ok := False;
    if Assigned(pOutOpen) then
    begin
      FillChar(fmt, SizeOf(fmt), 0);
      fmt.tag := 1; fmt.channels := 1; fmt.rate := want; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := want * 2;
      ok := pOutOpen(h, UINT(-1), @fmt, 0, 0, 1 { WAVE_FORMAT_QUERY }) = 0;
    end;
    if not ok then
    begin
      RefusedRate := want;
      Log('speaker: the sound card does not take ' + LI(want) + '/s; it stays at 44,100 (converted by Windows)');
      OutRateNote := 'at 44,100/s: the card does not take its own rate (' + UnicodeString(LI(want)) + ')';
      if TxRate <> 44100 then begin TxRate := 44100; MakeLead; end;
      Exit;
    end;
  end;
  TxRate := want;
  MakeLead;
  if want = 44100 then
  begin
    if SpeakerNative then OutRateNote := 'at 44,100/s until the chip''s own rate is known'
    else OutRateNote := 'at 44,100/s, converted by Windows (Settings)';
  end
  else OutRateNote := 'at ' + UnicodeString(LI(want)) + '/s, the sound chip''s own rate';
  Log('speaker: plays at ' + LI(want) + '/s from now on');
end;

procedure AudioStart;
var rtid: TThreadID;
begin
  if not InitDone then begin InitializeCriticalSection(Lock); InitDone := True; end;
  Quit := False;
  RxInit(RxSD, CH_SD); RxInit(RxFD, CH_FD);
  if InRate100 <= 0 then InRate100 := Int64(IN_RATE) * 100;     { not known yet: what it claims }
  RsInit(Rs, InRate100, Int64(MRATE) * 100, True);
  LastSet := InRate100;
  if InRate100 > 0 then RateTrusted := RateSource > 0;           { a rate kept from before (or Pair) }
  MakeLead;
  AudioChooseRate;
  MkCoef := 2 * CosI(Integer((Int64(2000) * 65536 div IN_RATE) and $FFFF)) * 4;
  MkCoefL := 2 * CosI(Integer((Int64(1600) * 65536 div IN_RATE) and $FFFF)) * 4;
  MkCoefH := 2 * CosI(Integer((Int64(2400) * 65536 div IN_RATE) and $FFFF)) * 4;
  { started through the Pascal runtime, not straight from Windows: then the runtime knows there are two
    threads and guards its memory (both threads make and free sound buffers and text). Started from Windows
    directly, as up to 3.6, the two shared the runtime's memory lists unguarded. }
  hThread := THandle(BeginThread(@AudioThreadRtl, nil, rtid));
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
