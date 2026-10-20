program micscan;
{ Mic Scan: finds out how a handheld's microphone really hears sound.

  The phone plays a one-minute test signal (the page scan.html); this program
  records it, measures it (scanlib.pas), shows what it found, and can type
  the report to the phone through HPC Whisper's sound link (wmodem.pas), so
  nothing has to be copied off the handheld.

  Builds for Windows CE (ARM) and for desktop Windows (testing). }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R micscan.res}
uses Windows, wmodem, scanlib;

const
  VERSION = '1.0';
  CREATOR = 'Kyriakos Christodoulou';
  CLSNAME: UnicodeString = 'HPCMicScan';
  APPNAME: UnicodeString = 'Mic Scan';
  WM_UPDATE = WM_APP + 1;
  ID_TIMER = 1;

  IN_RATE = 44100;                 { what the handheld says; the real rate is measured }
  IN_N = 4410;                     { 100 ms per buffer }
  IN_NBUF = 12;
  REC_SECONDS = 75;
  REC_MAX = IN_RATE * REC_SECONDS;
  OUT_RATE = 43200;                { for sending the report: the speaker's real rate }
  BUF_N = 4410; NBUF = 3;

  ST_READY = 0; ST_REC = 1; ST_WORK = 2; ST_RESULT = 3;
  PAGES = 4;

  HEAD_H = 30; FOOT_H = 42; PAD = 8;

  { colours are BGR }
  COL_NAVY = $36251B; COL_PAPER = $EEF2F4; COL_CARD = $FFFFFF; COL_INK = $30241D; COL_MUTED = $786F6B;
  COL_LINE = $D0D8DC; COL_GOOD = $1F8A3D; COL_FAIL = $4F60E5; COL_AMBER = $4AA0E8; COL_GREEN_ON_NAVY = $5AC77F;
  COL_KEYFG = $B05D2A; COL_HEADKEY = $E6D2C8; COL_PILL_IDLE = $5A4A3C; COL_GREY = $B8B0AC;

  WAVE_MAPPER_ = UINT(-1);
  WHDR_DONE_ = 1;

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
  HWAVE_ = THandle;

  TNumDevs = function: UINT; API;
  TOpen = function(out h: HWAVE_; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; API;
  THdrFn = function(h: HWAVE_; hdr: PWaveHdr; size: UINT): UINT; API;
  THandleFn = function(h: HWAVE_): UINT; API;
  TSetVol = function(h: HWAVE_; vol: DWORD): UINT; API;
  TGetModuleFileNameW = function(h: HMODULE; buf: PWideChar; n: DWORD): DWORD; API;
  TRoundRect = function(dc: HDC; l, t, r, b, w, h: Integer): BOOL; API;

var
  pOutNum, pInNum: TNumDevs; pOutOpen, pInOpen: TOpen;
  pOutPrep, pOutUnprep, pOutWrite, pInPrep, pInUnprep, pInAdd: THdrFn;
  pOutReset, pOutClose, pInStart, pInStop, pInReset, pInClose: THandleFn;
  pSetVol: TSetVol;
  pGetModuleFileNameW: TGetModuleFileNameW;
  pRoundRect: TRoundRect;
  hCore: HMODULE = 0;
  MissingNames: UnicodeString = '';

  AppInst: HINST;
  hMain: HWND;
  CW, CH: Integer;
  fNorm, fBold, fBig, fSmall, fMono: HFONT;
  State: Integer = ST_READY;
  Page: Integer = 0;
  Scroll: Integer = 0;
  Note: UnicodeString = '';
  Quit: Boolean = False;
  DirPath: UnicodeString = '';

  { recording }
  Rec: PSamples = nil;
  RecN: LongInt = 0;                 { samples recorded }
  RecStopReq: Boolean = False;
  Cancelled: Boolean = False;
  RecStartTick: LongWord = 0;
  Peak: Integer = 0;                 { loudest of the last buffer, 0..32767 }
  PeakHold: Integer = 0;
  hRecThread: THandle = 0;
  MicErr: UnicodeString = '';
  hIn: HWAVE_ = 0;
  InHdr: array[0..IN_NBUF - 1] of TWaveHdr;
  InBuf: array[0..IN_NBUF - 1, 0..IN_N - 1] of SmallInt;

  { results }
  Res: TScanResult;
  Full, Compact: TLines;
  HaveRes: Boolean = False;

  { sending the report }
  Lock: TRTLCriticalSection;
  Snd: TSender;
  hSendThread: THandle = 0;
  SendActive: Boolean = False;
  SendStop: Boolean = False;
  SendErr: UnicodeString = '';
  hOut: HWAVE_ = 0;
  OutHdr: array[0..NBUF - 1] of TWaveHdr;
  OutBuf: array[0..NBUF - 1, 0..BUF_N - 1] of SmallInt;
  Tm: TToneMaker;

{ ---------- small helpers ---------- }

function US(const s: ShortString): UnicodeString;
var i: Integer;
begin
  SetLength(Result, Length(s));
  for i := 1 to Length(s) do Result[i] := WideChar(Ord(s[i]));
end;

function IU(i: Int64): UnicodeString;
var s: ShortString;
begin
  Str(i, s); Result := US(s);
end;

function MkRect(l, t, r, b: Integer): TRect;
begin
  Result.left := l; Result.top := t; Result.right := r; Result.bottom := b;
end;

function MkFont(h, weight: Integer; const face: UnicodeString): HFONT;
var lf: LOGFONTW; i: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -h; lf.lfWeight := weight; lf.lfCharSet := DEFAULT_CHARSET;
  for i := 1 to Length(face) do lf.lfFaceName[i-1] := face[i];
  Result := CreateFontIndirectW(@lf);
end;

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

function Find(const fn: ShortString; const lib: UnicodeString; needed: Boolean): Pointer;
begin
  {$ifdef wince}
  Result := FindIn(hCore, fn);
  {$else}
  Result := FindIn(LoadLibraryW(PWideChar(lib)), fn);
  {$endif}
  if (Result = nil) and needed then
  begin
    if MissingNames <> '' then MissingNames := MissingNames + ', ';
    MissingNames := MissingNames + US(fn);
  end;
end;

procedure ResolveAll;
const MM = 'winmm.dll'; K = 'kernel32.dll'; G = 'gdi32.dll';
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pOutNum := TNumDevs(Find('waveOutGetNumDevs', MM, False));
  pOutOpen := TOpen(Find('waveOutOpen', MM, False));
  pOutPrep := THdrFn(Find('waveOutPrepareHeader', MM, False));
  pOutUnprep := THdrFn(Find('waveOutUnprepareHeader', MM, False));
  pOutWrite := THdrFn(Find('waveOutWrite', MM, False));
  pOutReset := THandleFn(Find('waveOutReset', MM, False));
  pOutClose := THandleFn(Find('waveOutClose', MM, False));
  pSetVol := TSetVol(Find('waveOutSetVolume', MM, False));
  pInNum := TNumDevs(Find('waveInGetNumDevs', MM, True));
  pInOpen := TOpen(Find('waveInOpen', MM, True));
  pInPrep := THdrFn(Find('waveInPrepareHeader', MM, True));
  pInUnprep := THdrFn(Find('waveInUnprepareHeader', MM, True));
  pInAdd := THdrFn(Find('waveInAddBuffer', MM, True));
  pInStart := THandleFn(Find('waveInStart', MM, True));
  pInStop := THandleFn(Find('waveInStop', MM, True));
  pInReset := THandleFn(Find('waveInReset', MM, True));
  pInClose := THandleFn(Find('waveInClose', MM, True));
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', K, False));
  pRoundRect := TRoundRect(Find('RoundRect', G, False));
end;

procedure FindDir;
var buf: array[0..259] of WideChar; n, i, cut: Integer;
begin
  DirPath := '';
  if not Assigned(pGetModuleFileNameW) then Exit;
  n := pGetModuleFileNameW(0, @buf[0], 259);
  if n <= 0 then Exit;
  cut := 0;
  for i := 0 to n - 1 do if buf[i] = '\' then cut := i + 1;
  SetLength(DirPath, cut);
  for i := 0 to cut - 1 do DirPath[i + 1] := buf[i];
end;

{ ---------- saving ---------- }

function WriteAll(const name: UnicodeString; p: Pointer; n: LongWord): Boolean;
var h: THandle; got: DWORD;
begin
  Result := False;
  h := CreateFileW(PWideChar(DirPath + name), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  Result := WriteFile(h, {$ifdef wince}p{$else}p^{$endif}, n, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = n);
  CloseHandle(h);
end;

procedure SaveFiles;
var hdr: array[0..43] of Byte; txt: AnsiString; i, j: Integer; n, rate: LongWord; h: THandle; got: DWORD; ok1, ok2: Boolean;
  procedure P4(at: Integer; v: LongWord); begin hdr[at] := v and $FF; hdr[at+1] := (v shr 8) and $FF; hdr[at+2] := (v shr 16) and $FF; hdr[at+3] := (v shr 24) and $FF; end;
begin
  if not HaveRes then begin Note := 'Nothing to save yet.'; Exit; end;
  txt := '';
  for i := 0 to Full.n - 1 do txt := txt + AnsiString(Full.s[i]) + #13#10;
  ok1 := WriteAll('micscan-report.txt', @txt[1], Length(txt));
  { the recording as a WAV, at the rate it really had }
  n := RecN * 2;
  rate := Res.rate100 div 100;
  if rate = 0 then rate := IN_RATE;
  Move(PAnsiChar('RIFF')^, hdr[0], 4); P4(4, 36 + n); Move(PAnsiChar('WAVEfmt ')^, hdr[8], 8); P4(16, 16);
  hdr[20] := 1; hdr[21] := 0; hdr[22] := 1; hdr[23] := 0; P4(24, rate); P4(28, rate * 2); hdr[32] := 2; hdr[33] := 0; hdr[34] := 16; hdr[35] := 0;
  Move(PAnsiChar('data')^, hdr[36], 4); P4(40, n);
  ok2 := False;
  h := CreateFileW(PWideChar(DirPath + 'micscan.wav'), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h <> INVALID_HANDLE_VALUE then
  begin
    got := 0; j := 0;
    ok2 := WriteFile(h, {$ifdef wince}@hdr{$else}hdr{$endif}, 44, {$ifdef wince}@got{$else}got{$endif}, nil);
    if ok2 then ok2 := WriteFile(h, {$ifdef wince}Rec{$else}Rec^{$endif}, n, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = n);
    CloseHandle(h);
  end;
  if ok1 and ok2 then Note := 'Saved micscan-report.txt and micscan.wav next to the program.'
  else if ok1 then Note := 'Saved micscan-report.txt; the recording (micscan.wav) did not fit.'
  else Note := 'Could not save here (is the folder read-only?).';
end;

{ ---------- recording and measuring ---------- }

procedure RunAnalysis(nominal: LongInt);
begin
  State := ST_WORK;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
  Analyse(Rec, RecN, nominal, Res);
  BuildReport(Res, Full);
  BuildCompact(Res, Compact);
  HaveRes := True;
  Page := 0; Scroll := 0;
  State := ST_RESULT;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

var LoadRate: LongInt = IN_RATE;

function AnalyseThread(param: Pointer): DWORD; API;
begin
  Result := 0;
  RunAnalysis(LoadRate);
end;

function RecThread(param: Pointer): DWORD; API;
var fmt: TWaveFormat; k, i, pk, v: Integer; open: Boolean; kk: Integer;
begin
  Result := 0;
  MicErr := '';
  open := False;
  if MissingNames <> '' then MicErr := 'Missing: ' + MissingNames
  else if pInNum() = 0 then MicErr := 'No microphone found.'
  else
  begin
    FillChar(fmt, SizeOf(fmt), 0);
    fmt.tag := 1; fmt.channels := 1; fmt.rate := IN_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := IN_RATE * 2;
    if pInOpen(hIn, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then MicErr := 'The microphone would not open.' else open := True;
  end;
  if not open then
  begin
    State := ST_READY;
    PostMessageW(hMain, WM_UPDATE, 0, 0);
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
  RecN := 0;
  k := 0;
  while (not RecStopReq) and (not Quit) and (RecN + IN_N <= REC_MAX) do
  begin
    if (InHdr[k].flags and WHDR_DONE_) = 0 then begin Sleep(10); Continue; end;
    pk := 0;
    for i := 0 to IN_N - 1 do
    begin
      v := InBuf[k][i];
      if v < 0 then v := -v;
      if v > pk then pk := v;
    end;
    Move(InBuf[k][0], Rec^[RecN], IN_N * 2);
    Inc(RecN, IN_N);
    Peak := pk;
    if pk > PeakHold then PeakHold := pk;
    pInUnprep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    FillChar(InHdr[k], SizeOf(TWaveHdr), 0);
    InHdr[k].data := @InBuf[k][0];
    InHdr[k].len := IN_N * 2;
    pInPrep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
    k := (k + 1) mod IN_NBUF;
  end;
  pInStop(hIn); pInReset(hIn);
  for kk := 0 to IN_NBUF - 1 do pInUnprep(hIn, @InHdr[kk], SizeOf(TWaveHdr));
  pInClose(hIn);
  if Quit then Exit;
  if Cancelled then begin Cancelled := False; State := ST_READY; PostMessageW(hMain, WM_UPDATE, 0, 0); Exit; end;
  RunAnalysis(IN_RATE);
end;

procedure LoadRecording;
var h: THandle; hdr: array[0..43] of Byte; got: DWORD; n: LongWord; tid: DWORD; rate: LongWord;
begin
  h := CreateFileW(PWideChar(DirPath + 'micscan.wav'), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then begin Note := 'No micscan.wav next to the program.'; Exit; end;
  got := 0;
  if (not ReadFile(h, {$ifdef wince}@hdr{$else}hdr{$endif}, 44, {$ifdef wince}@got{$else}got{$endif}, nil)) or (got <> 44) then begin CloseHandle(h); Note := 'Not a WAV file.'; Exit; end;
  rate := hdr[24] or (LongWord(hdr[25]) shl 8) or (LongWord(hdr[26]) shl 16);
  n := hdr[40] or (LongWord(hdr[41]) shl 8) or (LongWord(hdr[42]) shl 16) or (LongWord(hdr[43]) shl 24);
  if n > REC_MAX * 2 then n := REC_MAX * 2;
  if Rec = nil then GetMem(Rec, REC_MAX * 2 + 16);
  got := 0;
  ReadFile(h, {$ifdef wince}Rec{$else}Rec^{$endif}, n, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
  RecN := got div 2;
  LoadRate := rate; if LoadRate < 8000 then LoadRate := IN_RATE;
  Note := '';
  if hRecThread <> 0 then begin WaitForSingleObject(hRecThread, 3000); CloseHandle(hRecThread); hRecThread := 0; end;
  hRecThread := CreateThread(nil, 0, @AnalyseThread, nil, 0, tid);
end;

procedure StartRecording;
var tid: DWORD;
begin
  if State = ST_REC then Exit;
  if hRecThread <> 0 then begin WaitForSingleObject(hRecThread, 3000); CloseHandle(hRecThread); hRecThread := 0; end;
  if Rec = nil then GetMem(Rec, REC_MAX * 2 + 16);
  if Rec = nil then begin Note := 'Not enough memory for the recording.'; Exit; end;
  RecStopReq := False; Cancelled := False; PeakHold := 0; Peak := 0; HaveRes := False; Note := ''; MicErr := '';
  RecStartTick := GetTickCount;
  State := ST_REC;
  hRecThread := CreateThread(nil, 0, @RecThread, nil, 0, tid);
  if hRecThread = 0 then begin State := ST_READY; Note := 'The recording thread could not start.'; end
  else SetThreadPriority(hRecThread, THREAD_PRIORITY_ABOVE_NORMAL);
end;

{ ---------- sending the report to the phone ---------- }

function OpenOut: Boolean;
var fmt: TWaveFormat;
begin
  Result := False;
  if (not Assigned(pOutOpen)) or (pOutNum() = 0) then begin SendErr := 'No sound device.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := OUT_RATE; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := OUT_RATE * 2;
  if pOutOpen(hOut, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then
  begin
    fmt.rate := 44100; fmt.bytesPerSec := 88200;
    if pOutOpen(hOut, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then begin SendErr := 'The speaker would not open.'; Exit; end;
  end;
  if Assigned(pSetVol) then begin pSetVol(0, $FFFFFFFF); pSetVol(hOut, $FFFFFFFF); end;
  SendErr := '';
  Result := True;
end;

function SendThread(param: Pointer): DWORD; API;
var k, i: Integer; playing: array[0..NBUF - 1] of Boolean; busy, was, got: Boolean; f: TFrame;
begin
  Result := 0;
  SendActive := True;
  if not OpenOut then begin SendActive := False; PostMessageW(hMain, WM_UPDATE, 0, 0); Exit; end;
  TmInit(Tm, OUT_RATE);
  for i := 0 to NBUF - 1 do playing[i] := False;
  busy := False; k := 0;
  while (not Quit) and (not SendStop) do
  begin
    if playing[k] then
    begin
      while ((OutHdr[k].flags and WHDR_DONE_) = 0) and not Quit do Sleep(5);
      pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
      playing[k] := False;
    end;
    if Quit then Break;
    if not busy then
    begin
      EnterCriticalSection(Lock);
      got := SnNext(Snd, GetTickCount, f);
      LeaveCriticalSection(Lock);
      if got then
      begin
        if f.alt then Tm.band := 0 else Tm.band := 2;
        Tm.speed := 2; Tm.volume := 50;
        TmStart(Tm, f);
        PostMessageW(hMain, WM_UPDATE, 0, 0);
      end
      else
      begin
        EnterCriticalSection(Lock);
        was := (SnSent(Snd) >= Snd.target) and (SnWaiting(Snd) = 0);
        LeaveCriticalSection(Lock);
        if was then Break;                       { everything has gone out as often as asked }
      end;
    end;
    was := busy;
    busy := TmFill(Tm, OutBuf[k], BUF_N);
    if was and not busy then PostMessageW(hMain, WM_UPDATE, 0, 0);
    FillChar(OutHdr[k], SizeOf(TWaveHdr), 0);
    OutHdr[k].data := @OutBuf[k][0];
    OutHdr[k].len := BUF_N * 2;
    if pOutPrep(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then
      if pOutWrite(hOut, @OutHdr[k], SizeOf(TWaveHdr)) = 0 then playing[k] := True;
    if not playing[k] then Sleep(100);
    k := (k + 1) mod NBUF;
  end;
  pOutReset(hOut);
  for k := 0 to NBUF - 1 do if playing[k] then pOutUnprep(hOut, @OutHdr[k], SizeOf(TWaveHdr));
  pOutClose(hOut);
  SendActive := False;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

procedure SendReport;
var i, j: Integer; s: ShortString; tid: DWORD;
begin
  if not HaveRes then Exit;
  if SendActive then begin Note := 'Already sending.'; Exit; end;
  if hSendThread <> 0 then begin WaitForSingleObject(hSendThread, 2000); CloseHandle(hSendThread); hSendThread := 0; end;
  EnterCriticalSection(Lock);
  SnInit(Snd, Byte(GetTickCount));
  Snd.target := 6;
  for i := 0 to Compact.n - 1 do
  begin
    s := Compact.s[i];
    for j := 1 to Length(s) do SnType(Snd, WideChar(Ord(s[j])), GetTickCount);
    SnType(Snd, #10, GetTickCount);
  end;
  LeaveCriticalSection(Lock);
  SendStop := False; SendErr := '';
  Note := 'Sending the report. Open HPC Whisper on the phone, in any text field.';
  hSendThread := CreateThread(nil, 0, @SendThread, nil, 0, tid);
end;

{ ---------- drawing ---------- }

procedure Txt(dc: HDC; const s: UnicodeString; rc: TRect; f: HFONT; col: COLORREF; flags: UINT);
var old: HGDIOBJ;
begin
  if Length(s) = 0 then Exit;
  old := SelectObject(dc, f);
  SetTextColor(dc, col);
  DrawTextW(dc, PWideChar(s), Length(s), rc, flags or DT_NOPREFIX);
  SelectObject(dc, old);
end;

procedure FillR(dc: HDC; const rc: TRect; col: COLORREF);
var br: HBRUSH; r2: TRect;
begin
  r2 := rc;
  br := CreateSolidBrush(col);
  FillRect(dc, r2, br);
  DeleteObject(br);
end;

procedure Rounded(dc: HDC; const rc: TRect; col: COLORREF; radius: Integer);
var br: HBRUSH; oldB, oldP: HGDIOBJ;
begin
  if not Assigned(pRoundRect) then begin FillR(dc, rc, col); Exit; end;
  br := CreateSolidBrush(col);
  oldB := SelectObject(dc, br);
  oldP := SelectObject(dc, GetStockObject(NULL_PEN));
  pRoundRect(dc, rc.left, rc.top, rc.right + 1, rc.bottom + 1, radius, radius);
  SelectObject(dc, oldP); SelectObject(dc, oldB);
  DeleteObject(br);
end;

function TextW(dc: HDC; const s: UnicodeString; f: HFONT): Integer;
var rc: TRect; old: HGDIOBJ;
begin
  Result := 0;
  if Length(s) = 0 then Exit;
  rc := MkRect(0, 0, 2000, 100);
  old := SelectObject(dc, f);
  DrawTextW(dc, PWideChar(s), Length(s), rc, DT_CALCRECT or DT_SINGLELINE or DT_NOPREFIX);
  SelectObject(dc, old);
  Result := rc.right;
end;

function KHz1(hz: Integer): UnicodeString;
begin
  Result := IU(hz div 1000) + '.' + IU((hz mod 1000) div 100);
end;

function D1(v: Integer): UnicodeString;
begin
  if v <= -9000 then begin Result := '-'; Exit; end;
  Result := IU(Abs(v) div 10) + '.' + IU(Abs(v) mod 10);
  if v < 0 then Result := '-' + Result;
end;

procedure DrawLogo(dc: HDC; x, y: Integer);
var i: Integer; h: Integer;
begin
  { a small level meter: bars of different heights }
  for i := 0 to 5 do
  begin
    h := 4 + ((i * 7) mod 4) * 4;
    FillR(dc, MkRect(x + i * 5, y + 18 - h, x + i * 5 + 4, y + 18), COL_HEADKEY);
  end;
end;

procedure DrawHeader(dc: HDC);
var s: UnicodeString; col, fg: COLORREF; w: Integer; rc: TRect;
begin
  FillR(dc, MkRect(0, 0, CW, HEAD_H), COL_NAVY);
  DrawLogo(dc, 12, 6);
  Txt(dc, APPNAME, MkRect(48, 5, 300, HEAD_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'microphone check', MkRect(130, 8, 330, HEAD_H), fSmall, COL_HEADKEY, DT_LEFT or DT_SINGLELINE);
  fg := COL_NAVY;
  case State of
    ST_REC: begin col := COL_AMBER; s := 'Recording ' + IU((GetTickCount - RecStartTick) div 1000) + ' s'; end;
    ST_WORK: begin col := COL_AMBER; s := 'Measuring'; end;
    ST_RESULT: if Res.ok then begin col := COL_GREEN_ON_NAVY; s := 'Done' end else begin col := COL_FAIL; fg := $FFFFFF; s := 'Failed'; end;
  else begin col := COL_PILL_IDLE; fg := COL_HEADKEY; s := 'Ready'; end;
  end;
  if SendActive then begin col := COL_AMBER; fg := COL_NAVY; s := 'Sending'; end;
  w := TextW(dc, s, fBold) + 34;
  rc := MkRect(CW - PAD - w, 4, CW - PAD, HEAD_H - 4);
  Rounded(dc, rc, col, 14);
  FillR(dc, MkRect(rc.left + 10, rc.top + 9, rc.left + 17, rc.top + 16), fg);
  Txt(dc, s, MkRect(rc.left + 24, rc.top, rc.right, rc.bottom), fBold, fg, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
end;

{ ---- the buttons ---- }

var
  BtnN: Integer = 0;
  BtnLabel, BtnKey: array[0..5] of UnicodeString;

procedure SetButtons;
begin
  case State of
    ST_READY: begin
      BtnN := 4;
      BtnLabel[0] := 'Record'; BtnKey[0] := 'Enter';
      BtnLabel[1] := 'Open wav'; BtnKey[1] := 'O';
      BtnLabel[2] := 'About'; BtnKey[2] := 'A';
      BtnLabel[3] := 'Quit'; BtnKey[3] := 'Q';
    end;
    ST_REC: begin
      BtnN := 2;
      BtnLabel[0] := 'Stop, measure'; BtnKey[0] := 'Enter';
      BtnLabel[1] := 'Cancel'; BtnKey[1] := 'Esc';
    end;
    ST_RESULT: begin
      BtnN := 6;
      BtnLabel[0] := 'Previous'; BtnKey[0] := 'Left';
      BtnLabel[1] := 'Next'; BtnKey[1] := 'Right';
      BtnLabel[2] := 'To phone'; BtnKey[2] := 'S';
      BtnLabel[3] := 'Save'; BtnKey[3] := 'W';
      BtnLabel[4] := 'Again'; BtnKey[4] := 'Enter';
      BtnLabel[5] := 'Quit'; BtnKey[5] := 'Q';
    end;
  else BtnN := 0;
  end;
end;

function BtnRect(i: Integer): TRect;
var w, y: Integer;
begin
  w := (CW - 2 * PAD - (BtnN - 1) * 5) div BtnN;
  y := CH - FOOT_H + 4;
  Result := MkRect(PAD + i * (w + 5), y, PAD + i * (w + 5) + w, y + FOOT_H - 8);
end;

procedure DrawButtons(dc: HDC);
var i: Integer; rc: TRect;
begin
  SetButtons;
  for i := 0 to BtnN - 1 do
  begin
    rc := BtnRect(i);
    Rounded(dc, rc, COL_LINE, 8);
    Rounded(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD, 8);
    Txt(dc, BtnLabel[i], MkRect(rc.left, rc.top + 2, rc.right, rc.top + 17), fBold, COL_NAVY, DT_CENTER or DT_SINGLELINE);
    Txt(dc, BtnKey[i], MkRect(rc.left, rc.top + 16, rc.right, rc.bottom), fSmall, COL_MUTED, DT_CENTER or DT_SINGLELINE);
  end;
end;

procedure PaintCard(dc: HDC; const card: TRect);
begin
  Rounded(dc, MkRect(card.left - 1, card.top - 1, card.right + 1, card.bottom + 1), COL_LINE, 12);
  Rounded(dc, card, COL_CARD, 12);
end;

function CardRect: TRect;
begin
  Result := MkRect(PAD, HEAD_H + 8, CW - PAD, CH - FOOT_H - 2);
end;

procedure DrawMsg(dc: HDC);
begin
  if Note <> '' then
    Txt(dc, Note, MkRect(PAD + 6, CH - FOOT_H - 18, CW - PAD - 6, CH - FOOT_H - 2), fSmall, COL_KEYFG, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
end;

{ ---- the screens ---- }

procedure DrawReady(dc: HDC);
var card: TRect; y: Integer;
begin
  card := CardRect;
  PaintCard(dc, card);
  y := card.top + 8;
  Txt(dc, 'How does this handheld hear the phone?', MkRect(card.left + 16, y, card.right - 16, y + 22), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, '1.  Hold the phone''s speaker 2 to 5 cm from the handheld''s microphone, volume at maximum.',
      MkRect(card.left + 16, y + 26, card.right - 16, y + 44), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  Txt(dc, '2.  Press Enter here. On the phone open this page and tap Start:',
      MkRect(card.left + 16, y + 46, card.right - 16, y + 64), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'kiriakoschristodoulou-netizen.github.io/hpc-whisper/scan.html', MkRect(card.left + 36, y + 64, card.right - 16, y + 82), fBold, COL_KEYFG, DT_LEFT or DT_SINGLELINE);
  Txt(dc, '3.  Keep quiet for a minute. When the phone says Done, press Enter to measure.',
      MkRect(card.left + 16, y + 84, card.right - 16, y + 102), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  if MicErr <> '' then
    Txt(dc, MicErr, MkRect(card.left + 16, y + 112, card.right - 16, y + 130), fBold, COL_FAIL, DT_LEFT or DT_SINGLELINE);
end;

procedure DrawRec(dc: HDC);
var card, bar: TRect; secs, w, pk, db: Integer; col: COLORREF;
begin
  card := CardRect;
  PaintCard(dc, card);
  secs := (GetTickCount - RecStartTick) div 1000;
  Txt(dc, 'Recording. Tap Start on the phone now.', MkRect(card.left + 16, card.top + 10, card.right - 16, card.top + 34), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'When the phone says Done, press Enter. It also stops by itself after ' + IU(REC_SECONDS) + ' seconds.',
      MkRect(card.left + 16, card.top + 38, card.right - 16, card.top + 70), fNorm, COL_MUTED, DT_LEFT or DT_WORDBREAK);
  { the level the microphone gives now: 40 dB range }
  pk := Peak;
  if pk < 1 then pk := 1;
  db := 0;
  while (pk > 1) and (db < 90) do begin pk := pk * 7 div 8 ; Inc(db); end;   { rough log scale, 0..90 }
  w := Round(Peak / 32768 * 1);
  bar := MkRect(card.left + 16, card.top + 86, card.right - 16, card.top + 108);
  FillR(dc, bar, COL_PAPER);
  w := 0;
  if Peak > 0 then w := (bar.right - bar.left) * (Ord(db < 90) * (90 - db)) div 90;
  if Peak > 30000 then col := COL_FAIL else col := COL_GOOD;
  FillR(dc, MkRect(bar.left, bar.top, bar.left + w, bar.bottom), col);
  Txt(dc, 'level now (what the microphone hears)', MkRect(card.left + 16, card.top + 112, card.right - 16, card.top + 130), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Loudest so far: ' + IU(PeakHold * 100 div 32768) + ' % of the most it can record', MkRect(card.left + 16, card.top + 130, card.right - 16, card.top + 148), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  if secs > 0 then ;
end;

procedure DrawWork(dc: HDC);
var card: TRect;
begin
  card := CardRect;
  PaintCard(dc, card);
  Txt(dc, 'Measuring the recording...', MkRect(card.left + 16, card.top + 12, card.right - 16, card.top + 40), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'This takes a few seconds.', MkRect(card.left + 16, card.top + 44, card.right - 16, card.top + 70), fNorm, COL_MUTED, DT_LEFT or DT_SINGLELINE);
end;

function LineOf(const L: TLines; i: Integer): UnicodeString;
begin
  if (i >= 0) and (i < L.n) then Result := US(L.s[i]) else Result := '';
end;

procedure DrawSummary(dc: HDC; const card: TRect);
var y, i, lo, hi, best, bi: Integer; ww: UnicodeString;
begin
  y := card.top + 8;
  if not Res.ok then
  begin
    Txt(dc, 'The measurement did not work.', MkRect(card.left + 16, y, card.right - 16, y + 24), fBig, COL_FAIL, DT_LEFT or DT_SINGLELINE);
    Txt(dc, US(Res.err), MkRect(card.left + 16, y + 30, card.right - 16, card.bottom - 6), fNorm, COL_INK, DT_LEFT or DT_WORDBREAK);
    Exit;
  end;
  lo := UsableLowHz(Res); hi := UsableHighHz(Res);
  best := -9990; bi := 0;
  for i := 0 to NTONE - 1 do if Res.toneDb10[i] - Res.noiseDb10[i] > best then begin best := Res.toneDb10[i] - Res.noiseDb10[i]; bi := i; end;
  if lo = 0 then ww := 'No tone was heard clearly and steadily.'
  else ww := 'Usable: ' + KHz1(lo) + ' to ' + KHz1(hi) + ' kHz';
  Txt(dc, ww, MkRect(card.left + 16, y, card.right - 16, y + 24), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, '(20 dB over the background and the level not falling away)', MkRect(card.left + 16, y + 22, card.right - 16, y + 38), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Real sampling rate: ' + IU(Res.rate100 div 100) + ' Hz (Windows says 44,100)', MkRect(card.left + 16, y + 44, card.right - 16, y + 62), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Best tone: ' + KHz1(ToneHz(bi)) + ' kHz, ' + D1(best) + ' dB over the background', MkRect(card.left + 16, y + 62, card.right - 16, y + 80), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  Txt(dc, LineOf(Full, Full.n - 1), MkRect(card.left + 16, y + 80, card.right - 16, y + 98), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Bursts at 19.5 kHz seen (of 6): 20 ms ' + IU(Res.burstSeen[0]) + ', 40 ms ' + IU(Res.burstSeen[1]) + ', 60 ms ' + IU(Res.burstSeen[2]) + ', 100 ms ' + IU(Res.burstSeen[3]),
      MkRect(card.left + 16, y + 98, card.right - 16, y + 116), fNorm, COL_INK, DT_LEFT or DT_SINGLELINE);
end;

procedure DrawResponse(dc: HDC; const card: TRect);
var i, x0, x1, y0, y1, bw, h, db, nz, top: Integer; col: COLORREF; rc: TRect;
begin
  x0 := card.left + 34; x1 := card.right - 10; y0 := card.top + 24; y1 := card.bottom - 22;
  Txt(dc, 'Level of each tone (dBFS) against frequency. Green: usable. Line: background.', MkRect(card.left + 10, card.top + 4, card.right - 10, card.top + 22), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  { scale: -110 dB at the bottom, -10 dB at the top }
  bw := (x1 - x0) div NTONE;
  for i := 0 to 5 do
  begin
    db := -10 - i * 20;
    h := y0 + (y1 - y0) * (-10 - db) div 100;
    FillR(dc, MkRect(x0, h, x1, h + 1), COL_LINE);
    Txt(dc, IU(db), MkRect(card.left + 2, h - 7, x0 - 3, h + 8), fSmall, COL_MUTED, DT_RIGHT or DT_SINGLELINE);
  end;
  for i := 0 to NTONE - 1 do
  begin
    db := Res.toneDb10[i] div 10;
    if db < -110 then db := -110;
    if db > -10 then db := -10;
    top := y0 + (y1 - y0) * (-10 - db) div 100;
    if (Res.toneDb10[i] - Res.noiseDb10[i] >= 200) and (Res.fall10[i] <= 150) then col := COL_GOOD
    else if Res.toneDb10[i] - Res.noiseDb10[i] >= 200 then col := COL_AMBER else col := COL_GREY;
    rc := MkRect(x0 + i * bw + 1, top, x0 + (i + 1) * bw - 1, y1);
    FillR(dc, rc, col);
    nz := Res.noiseDb10[i] div 10;
    if nz < -110 then nz := -110;
    if nz > -10 then nz := -10;
    h := y0 + (y1 - y0) * (-10 - nz) div 100;
    FillR(dc, MkRect(x0 + i * bw, h, x0 + (i + 1) * bw, h + 2), COL_FAIL);
  end;
  for i := 0 to 4 do
    Txt(dc, IU(i * 5) + 'k', MkRect(x0 + (i * 10 - 1) * bw, y1 + 3, x0 + (i * 10 + 5) * bw, y1 + 18), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
end;

procedure DrawGain(dc: HDC; const card: TRect);
var g, k, y0: Integer; hd: UnicodeString; col: COLORREF; v: Integer;
begin
  Txt(dc, 'Level while a tone goes on (dB from its first 0.15 s). A fall means automatic gain.', MkRect(card.left + 10, card.top + 3, card.right - 40, card.top + 18), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'after   0.05     0.1     0.25     0.5       1       1.9 s', MkRect(card.left + 160, card.top + 19, card.right - 8, card.top + 34), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  for g := 0 to NAGC - 1 do
  begin
    y0 := card.top + 34 + g * 24;
    hd := KHz1(AGC_HZ[g]) + ' kHz, ' + IU(AGC_AMP[g]) + '%';
    Txt(dc, hd, MkRect(card.left + 10, y0, card.left + 110, y0 + 18), fBold, COL_INK, DT_LEFT or DT_SINGLELINE);
    Txt(dc, D1(Res.envAbs10[g] div 10 * 10) + ' dBFS', MkRect(card.left + 104, y0 + 2, card.left + 164, y0 + 18), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
    for k := 0 to NENV - 1 do
    begin
      v := Res.envDb10[g, k];
      if v <= -150 then col := COL_FAIL else if v <= -60 then col := COL_AMBER else col := COL_GOOD;
      Txt(dc, D1(v), MkRect(card.left + 166 + k * 52, y0, card.left + 218 + k * 52, y0 + 18), fBold, col, DT_LEFT or DT_SINGLELINE);
    end;
    Txt(dc, 'pause ' + D1(Res.envBack10[g]), MkRect(card.left + 484, y0 + 2, card.right - 6, y0 + 18), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  end;
end;

procedure DrawReportText(dc: HDC; const card: TRect);
var rows, i, y, lh: Integer;
begin
  lh := 14;
  rows := (card.bottom - card.top - 8) div lh;
  if Scroll > Full.n - rows then Scroll := Full.n - rows;
  if Scroll < 0 then Scroll := 0;
  y := card.top + 4;
  for i := Scroll to Scroll + rows - 1 do
  begin
    if i >= Full.n then Break;
    Txt(dc, US(Full.s[i]), MkRect(card.left + 8, y, card.right - 6, y + lh), fSmall, COL_INK, DT_LEFT or DT_SINGLELINE);
    Inc(y, lh);
  end;
end;

procedure DrawResult(dc: HDC);
var card: TRect;
begin
  card := CardRect;
  PaintCard(dc, card);
  case Page of
    0: DrawSummary(dc, card);
    1: if Res.ok then DrawResponse(dc, card);
    2: if Res.ok then DrawGain(dc, card);
    3: DrawReportText(dc, card);
  end;
  Txt(dc, IU(Page + 1) + '/' + IU(PAGES), MkRect(card.right - 50, card.top + 4, card.right - 8, card.top + 20), fSmall, COL_MUTED, DT_RIGHT or DT_SINGLELINE);
end;

procedure DrawAbout(dc: HDC);
var card: TRect; y: Integer;
begin
  card := CardRect;
  PaintCard(dc, card);
  y := card.top + 10;
  Txt(dc, APPNAME + '  ' + VERSION, MkRect(card.left + 16, y, card.right - 16, y + 24), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Part of HPC Whisper. Created by ' + CREATOR + '.', MkRect(card.left + 16, y + 24, card.right - 16, y + 42), fNorm, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'It records a one-minute test sound from the phone and measures how this handheld''s microphone hears it: ' +
      'which frequencies, how loud, whether the level falls while a tone goes on (automatic gain), the real sampling rate, ' +
      'ghost tones and the shortest burst it notices. Press S on the results to type the report to the phone.',
      MkRect(card.left + 16, y + 48, card.right - 16, y + 120), fNorm, COL_INK, DT_LEFT or DT_WORDBREAK);
  Txt(dc, 'Press any key to go back.', MkRect(card.left + 16, y + 126, card.right - 16, y + 144), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
end;

var ShowAbout: Boolean = False;

procedure Draw(dc: HDC);
begin
  FillR(dc, MkRect(0, 0, CW, CH), COL_PAPER);
  SetBkMode(dc, TRANSPARENT);
  DrawHeader(dc);
  if ShowAbout then DrawAbout(dc)
  else
    case State of
      ST_READY: DrawReady(dc);
      ST_REC: DrawRec(dc);
      ST_WORK: DrawWork(dc);
      ST_RESULT: DrawResult(dc);
    end;
  if not ShowAbout then begin DrawMsg(dc); DrawButtons(dc); end;
end;

procedure Paint(wnd: HWND);
var ps: TPaintStruct; dc, mdc: HDC; bmp: HBITMAP; old: HGDIOBJ; rc: TRect;
begin
  dc := BeginPaint(wnd, ps);
  GetClientRect(wnd, rc);
  CW := rc.right; CH := rc.bottom;
  mdc := CreateCompatibleDC(dc);
  bmp := CreateCompatibleBitmap(dc, CW, CH);
  old := SelectObject(mdc, bmp);
  Draw(mdc);
  BitBlt(dc, 0, 0, CW, CH, mdc, 0, 0, SRCCOPY);
  SelectObject(mdc, old);
  DeleteObject(bmp);
  DeleteDC(mdc);
  EndPaint(wnd, ps);
end;

{ ---------- input ---------- }

procedure Leave;
var n: Integer;
begin
  Quit := True; SendStop := True; RecStopReq := True;
  n := 0;
  if hRecThread <> 0 then while (WaitForSingleObject(hRecThread, 100) <> WAIT_OBJECT_0) and (n < 40) do Inc(n);
  n := 0;
  if hSendThread <> 0 then while (WaitForSingleObject(hSendThread, 100) <> WAIT_OBJECT_0) and (n < 40) do Inc(n);
  DestroyWindow(hMain);
end;

procedure Act(cmd: Integer);        { 0 = Enter, 1 = Left, 2 = Right, 3 = S, 4 = W, 5 = Q, 6 = Esc, 7 = A, 8 = Up, 9 = Down }
begin
  if ShowAbout then begin ShowAbout := False; Exit; end;
  if cmd = 5 then begin Leave; Exit; end;
  case State of
    ST_READY:
      case cmd of
        0: StartRecording;
        7: ShowAbout := True;
        10: LoadRecording;
      end;
    ST_REC:
      case cmd of
        0: RecStopReq := True;
        6: begin Cancelled := True; RecStopReq := True; end;
      end;
    ST_RESULT:
      case cmd of
        0: begin State := ST_READY; Note := ''; StartRecording; end;
        1: begin Page := (Page + PAGES - 1) mod PAGES; Scroll := 0; end;
        2: begin Page := (Page + 1) mod PAGES; Scroll := 0; end;
        3: SendReport;
        4: SaveFiles;
        8: if Scroll > 0 then Dec(Scroll);
        9: Inc(Scroll);
        6: begin State := ST_READY; Note := ''; end;
      end;
  end;
end;

procedure OnKey(vk: Integer);
begin
  case vk of
    $0D: Act(0);
    $25: Act(1);
    $27: Act(2);
    $26: Act(8);
    $28: Act(9);
    $1B: Act(6);
    Ord('S'): Act(3);
    Ord('W'): Act(4);
    Ord('Q'): Act(5);
    Ord('A'): Act(7);
    Ord('O'): Act(10);
  else if ShowAbout then ShowAbout := False;
  end;
end;

procedure OnTap(x, y: Integer);
var i: Integer; rc: TRect;
begin
  if ShowAbout then begin ShowAbout := False; Exit; end;
  if y < CH - FOOT_H then Exit;
  SetButtons;
  for i := 0 to BtnN - 1 do
  begin
    rc := BtnRect(i);
    if (x >= rc.left) and (x < rc.right) then
    begin
      case State of
        ST_READY: case i of 0: Act(0); 1: Act(10); 2: Act(7); 3: Act(5); end;
        ST_REC: case i of 0: Act(0); 1: Act(6); end;
        ST_RESULT: case i of 0: Act(1); 1: Act(2); 2: Act(3); 3: Act(4); 4: Act(0); 5: Act(5); end;
      end;
      Exit;
    end;
  end;
end;

function WndProc(wnd: HWND; wmsg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; API;
begin
  Result := 0;
  case wmsg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_UPDATE: InvalidateRect(wnd, nil, False);
    WM_TIMER: InvalidateRect(wnd, nil, False);
    WM_LBUTTONDOWN:
      begin
        OnTap(SmallInt(lp and $FFFF), SmallInt((lp shr 16) and $FFFF));
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_KEYDOWN:
      begin
        OnKey(wp);
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_CLOSE: Leave;
    WM_DESTROY: if wnd = hMain then PostQuitMessage(0);
  else
    Result := DefWindowProcW(wnd, wmsg, wp, lp);
  end;
end;

var
  wc: WNDCLASSW;
  m: MSG;
  wa: TRect;
begin
  AppInst := GetModuleHandleW(nil);
  InitializeCriticalSection(Lock);
  SnInit(Snd, 1);
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
  fNorm := MkFont(12, 400, 'Tahoma');
  fBold := MkFont(12, 700, 'Tahoma');
  fBig := MkFont(15, 700, 'Tahoma');
  fSmall := MkFont(11, 400, 'Tahoma');
  fMono := MkFont(12, 400, 'Courier New');
  ResolveAll;
  FindDir;
  if not SystemParametersInfoW(SPI_GETWORKAREA, 0, @wa, 0) then wa := MkRect(0, 0, 640, 214);
  {$ifndef wince}
  wa := MkRect(40, 40, 680, 254);
  {$endif}
  CW := wa.right - wa.left; CH := wa.bottom - wa.top;
  hMain := CreateWindowExW(0, PWideChar(CLSNAME), PWideChar(APPNAME), WS_POPUP or WS_VISIBLE,
    wa.left, wa.top, CW, CH, 0, 0, AppInst, nil);
  if hMain = 0 then Halt(2);
  ShowWindow(hMain, SW_SHOW);
  UpdateWindow(hMain);
  SetForegroundWindow(hMain);
  SetTimer(hMain, ID_TIMER, 250, nil);
  while GetMessageW(@m, 0, 0, 0) do
  begin
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end.
