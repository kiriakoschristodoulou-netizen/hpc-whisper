program duplex;
{ Duplex Test: finds out whether this handheld's sound chip can play and record at the same time,
  in which order the two can be opened, and how long switching between them takes.
  The answer decides how a sound link with a return channel (the phone answering) can work.

  Run it, press Enter (or tap Run): a beep of about one second plays near the end of the test.
  The report is shown and can be saved next to the program (duplex-report.txt).
  Builds for Windows CE (ARM) and for desktop Windows (testing). }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R duplex.res}
uses Windows;

const
  VERSION = '1.0';
  CLSNAME: UnicodeString = 'HPCDuplexTest';
  APPNAME: UnicodeString = 'Duplex Test';
  WM_UPDATE = WM_APP + 1;
  ID_TIMER = 1;
  WAVE_MAPPER_ = UINT(-1);
  WHDR_DONE_ = 1;
  RATE = 44100;
  BN = 4410;                       { 100 ms }
  NIN = 16;
  HEAD_H = 30; FOOT_H = 42; PAD = 8;
  COL_NAVY = $36251B; COL_CARD = $FFFFFF; COL_INK = $30241D; COL_MUTED = $786F6B; COL_LINE = $D0D8DC;
  COL_GOOD = $1F8A3D; COL_FAIL = $4F60E5;
  MAXLN = 24;

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
  TGetModuleFileNameW = function(h: HMODULE; buf: PWideChar; n: DWORD): DWORD; API;

var
  pOutNum, pInNum: TNumDevs; pOutOpen, pInOpen: TOpen;
  pOutPrep, pOutUnprep, pOutWrite, pInPrep, pInUnprep, pInAdd: THdrFn;
  pOutReset, pOutClose, pInStart, pInStop, pInReset, pInClose: THandleFn;
  pGetModuleFileNameW: TGetModuleFileNameW;
  hCore: HMODULE = 0;
  Missing: Boolean = False;
  hMain: HWND;
  CW, CH: Integer;
  fNorm, fBold, fBig, fSmall, fMono: HFONT;
  DirPath: UnicodeString = '';
  Note: UnicodeString = '';
  Quit: Boolean = False;

  Ln: array[0..MAXLN - 1] of ShortString;       { the report; written by the test thread only }
  LnOk: array[0..MAXLN - 1] of Byte;            { 0 plain, 1 good, 2 bad }
  LnN: Integer = 0;
  Running: Boolean = False;
  Done: Boolean = False;
  hThread: THandle = 0;

  hOut, hIn: THandle;
  OutHdr: array[0..0] of TWaveHdr;
  OutBuf: array[0..10 * BN - 1] of SmallInt;
  InHdr: array[0..NIN - 1] of TWaveHdr;
  InBuf: array[0..NIN - 1, 0..BN - 1] of SmallInt;

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

function Find(const fn: ShortString; const lib: UnicodeString): Pointer;
begin
  {$ifdef wince}
  Result := FindIn(hCore, fn);
  {$else}
  Result := FindIn(LoadLibraryW(PWideChar(lib)), fn);
  {$endif}
  if Result = nil then Missing := True;
end;

procedure ResolveAll;
const MM = 'winmm.dll';
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pOutNum := TNumDevs(Find('waveOutGetNumDevs', MM));
  pOutOpen := TOpen(Find('waveOutOpen', MM));
  pOutPrep := THdrFn(Find('waveOutPrepareHeader', MM));
  pOutUnprep := THdrFn(Find('waveOutUnprepareHeader', MM));
  pOutWrite := THdrFn(Find('waveOutWrite', MM));
  pOutReset := THandleFn(Find('waveOutReset', MM));
  pOutClose := THandleFn(Find('waveOutClose', MM));
  pInNum := TNumDevs(Find('waveInGetNumDevs', MM));
  pInOpen := TOpen(Find('waveInOpen', MM));
  pInPrep := THdrFn(Find('waveInPrepareHeader', MM));
  pInUnprep := THdrFn(Find('waveInUnprepareHeader', MM));
  pInAdd := THdrFn(Find('waveInAddBuffer', MM));
  pInStart := THandleFn(Find('waveInStart', MM));
  pInStop := THandleFn(Find('waveInStop', MM));
  pInReset := THandleFn(Find('waveInReset', MM));
  pInClose := THandleFn(Find('waveInClose', MM));
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', 'kernel32.dll'));
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

{ ---------- the report (ShortStrings only: used from the test thread) ---------- }

function N2(v: Int64): ShortString;
begin
  Str(v, Result);
end;

procedure Say(const s: ShortString; kind: Integer);
begin
  if LnN < MAXLN then begin Ln[LnN] := s; LnOk[LnN] := kind; Inc(LnN); end;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

{ ---------- the sound steps ---------- }

procedure Fmt(var f: TWaveFormat);
begin
  FillChar(f, SizeOf(f), 0);
  f.tag := 1; f.channels := 1; f.rate := RATE; f.bits := 16; f.align := 2; f.bytesPerSec := RATE * 2;
end;

function OpenOut(out ms: LongWord): UINT;
var f: TWaveFormat; t0: LongWord;
begin
  Fmt(f); t0 := GetTickCount;
  Result := pOutOpen(hOut, WAVE_MAPPER_, @f, 0, 0, 0);
  ms := GetTickCount - t0;
end;

procedure CloseOut(out ms: LongWord);
var t0: LongWord;
begin
  t0 := GetTickCount;
  pOutReset(hOut); pOutClose(hOut);
  ms := GetTickCount - t0;
end;

function OpenIn(out ms: LongWord): UINT;
var f: TWaveFormat; t0: LongWord;
begin
  Fmt(f); t0 := GetTickCount;
  Result := pInOpen(hIn, WAVE_MAPPER_, @f, 0, 0, 0);
  ms := GetTickCount - t0;
end;

procedure CloseIn(out ms: LongWord);
var t0: LongWord;
begin
  t0 := GetTickCount;
  pInReset(hIn); pInClose(hIn);
  ms := GetTickCount - t0;
end;

{ starts recording into the NIN buffers (the microphone must be open) }
procedure RecStart;
var k: Integer;
begin
  for k := 0 to NIN - 1 do
  begin
    FillChar(InHdr[k], SizeOf(TWaveHdr), 0);
    InHdr[k].data := @InBuf[k][0];
    InHdr[k].len := BN * 2;
    pInPrep(hIn, @InHdr[k], SizeOf(TWaveHdr));
    pInAdd(hIn, @InHdr[k], SizeOf(TWaveHdr));
  end;
  pInStart(hIn);
end;

procedure RecEnd;
var k: Integer;
begin
  pInStop(hIn); pInReset(hIn);
  for k := 0 to NIN - 1 do pInUnprep(hIn, @InHdr[k], SizeOf(TWaveHdr));
end;

function BufPeak(k: Integer): Integer;
var i, v: Integer;
begin
  Result := 0;
  for i := 0 to BN - 1 do
  begin
    v := InBuf[k][i]; if v < 0 then v := -v;
    if v > Result then Result := v;
  end;
end;

{ one second of a tone at hz, to the open speaker; returns when it has been queued }
procedure PlayTone(hz: Integer);
var i: Integer; ph, w: Double;
begin
  w := 2 * Pi * hz / RATE; ph := 0;
  for i := 0 to 10 * BN - 1 do
  begin
    OutBuf[i] := Round(12000 * Sin(ph));
    ph := ph + w;
  end;
  FillChar(OutHdr[0], SizeOf(TWaveHdr), 0);
  OutHdr[0].data := @OutBuf[0];
  OutHdr[0].len := 10 * BN * 2;
  pOutPrep(hOut, @OutHdr[0], SizeOf(TWaveHdr));
  pOutWrite(hOut, @OutHdr[0], SizeOf(TWaveHdr));
end;

procedure WaitOutDone(maxMs: Integer);
var t0: LongWord;
begin
  t0 := GetTickCount;
  while ((OutHdr[0].flags and WHDR_DONE_) = 0) and (Integer(GetTickCount - t0) < maxMs) do Sleep(10);
  pOutUnprep(hOut, @OutHdr[0], SizeOf(TWaveHdr));
end;

{ record while a tone plays: the order decides what is opened first; returns False when something did not open }
function RecordWhilePlaying(micFirst: Boolean; hz: Integer; out silent, tone: Integer): Boolean;
var ms: LongWord; k, p: Integer; r: UINT;
begin
  Result := False; silent := 0; tone := 0;
  if micFirst then
  begin
    if OpenIn(ms) <> 0 then Exit;
    RecStart;
    Sleep(150);
    r := OpenOut(ms);
    if r <> 0 then begin RecEnd; CloseIn(ms); Exit; end;
  end
  else
  begin
    if OpenOut(ms) <> 0 then Exit;
    r := OpenIn(ms);
    if r <> 0 then begin CloseOut(ms); Exit; end;
    RecStart;
    Sleep(150);
  end;
  Sleep(350);                                   { about half a second of silence recorded }
  PlayTone(hz);
  Sleep(1100);
  WaitOutDone(500);
  Sleep(100);
  { buffers: 0..4 silence, 5..14 tone (the clock of the two streams is not exact: skip the edges) }
  for k := 1 to 3 do begin p := BufPeak(k); if p > silent then silent := p; end;
  for k := 7 to 12 do begin p := BufPeak(k); if p > tone then tone := p; end;
  RecEnd; CloseIn(ms);
  CloseOut(ms);
  Result := True;
end;

procedure Verdict(const what: ShortString; ok: Boolean; code: UINT; ms: LongWord);
begin
  if ok then Say(what + ': opens in ' + N2(ms) + ' ms', 1)
  else Say(what + ': FAILED (error ' + N2(code) + ')', 2);
end;

function TestThread(param: Pointer): DWORD; API;
var ms, ms2: LongWord; r, r2: UINT; si, to_, i: Integer; ok, a, b, c, d: Boolean;
    tOut, tIn, tOutC, tInC, t0: LongWord; cyc: Integer; hz: Integer;
begin
  Result := 0;
  LnN := 0; Done := False;
  if Missing or (pOutNum() = 0) or (pInNum() = 0) then
  begin
    Say('No sound functions or devices found.', 2);
    Done := True; Running := False; Exit;
  end;
  Say('1 Each device alone', 0);
  r := OpenOut(ms); Verdict('  Speaker', r = 0, r, ms);
  if r = 0 then begin CloseOut(ms2); Say('  Speaker closes in ' + N2(ms2) + ' ms', 0); end;
  r := OpenIn(ms); Verdict('  Microphone', r = 0, r, ms);
  if r = 0 then begin CloseIn(ms2); Say('  Microphone closes in ' + N2(ms2) + ' ms', 0); end;

  Say('2 Both open at once', 0);
  a := False; b := False;
  r := OpenOut(ms);
  if r = 0 then
  begin
    r2 := OpenIn(ms2);
    a := r2 = 0;
    if a then begin CloseIn(ms2); Say('  Speaker first, then microphone: works', 1); end
    else Say('  Speaker first, then microphone: FAILED (error ' + N2(r2) + ')', 2);
    CloseOut(ms);
  end;
  r := OpenIn(ms);
  if r = 0 then
  begin
    r2 := OpenOut(ms2);
    b := r2 = 0;
    if b then begin CloseOut(ms2); Say('  Microphone first, then speaker: works', 1); end
    else Say('  Microphone first, then speaker: FAILED (error ' + N2(r2) + ')', 2);
    CloseIn(ms);
  end;

  hz := 19000;
  Say('3 Recording while a 19 kHz beep plays', 0);
  c := False;
  if b then
  begin
    c := RecordWhilePlaying(True, hz, si, to_);
    if c then Say('  Microphone first: quiet ' + N2(si) + ', beep ' + N2(to_) + ' (of 32767)', 0);
  end;
  if (not c) and a then
  begin
    c := RecordWhilePlaying(False, hz, si, to_);
    if c then Say('  Speaker first: quiet ' + N2(si) + ', beep ' + N2(to_) + ' (of 32767)', 0);
  end;
  if c then
  begin
    if to_ >= si * 4 then Say('  The microphone hears the beep: FULL DUPLEX WORKS', 1)
    else Say('  The microphone did not clearly hear the beep', 2);
  end
  else Say('  Could not record while playing.', 2);

  Say('4 Switching (5 turns: speaker, then microphone)', 0);
  tOut := 0; tIn := 0; tOutC := 0; tInC := 0; ok := True;
  for cyc := 1 to 5 do
  begin
    t0 := GetTickCount;
    r := OpenOut(ms);
    if r <> 0 then begin ok := False; Break; end;
    tOut := tOut + ms;
    CloseOut(ms); tOutC := tOutC + ms;
    r := OpenIn(ms);
    if r <> 0 then begin ok := False; Break; end;
    tIn := tIn + ms;
    CloseIn(ms); tInC := tInC + ms;
  end;
  if ok then
  begin
    Say('  Speaker opens in ' + N2(tOut div 5) + ' ms, closes in ' + N2(tOutC div 5) + ' ms', 0);
    Say('  Microphone opens in ' + N2(tIn div 5) + ' ms, closes in ' + N2(tInC div 5) + ' ms', 0);
    Say('  A full switch speaker to microphone: about ' + N2((tOutC + tIn) div 5) + ' ms', 0);
  end
  else Say('  A switch failed (error ' + N2(r) + ')', 2);

  d := c;
  if d then Say('Result: play and record can run together.', 1)
  else if a or b then Say('Result: both open, but recording while playing did not work.', 2)
  else Say('Result: only one at a time: the return channel must take turns.', 2);
  Done := True; Running := False;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

procedure StartTest;
var tid: DWORD;
begin
  if Running then Exit;
  Running := True; Done := False; LnN := 0; Note := '';
  hThread := CreateThread(nil, 0, @TestThread, nil, 0, tid);
  if hThread = 0 then begin Running := False; Note := 'The test could not start.'; end;
end;

procedure SaveReport;
var txt: AnsiString; i: Integer; h: THandle; got: DWORD; ok: Boolean;
begin
  if not Done then begin Note := 'Run the test first.'; Exit; end;
  txt := 'Duplex Test ' + AnsiString(VERSION) + #13#10;
  for i := 0 to LnN - 1 do txt := txt + AnsiString(Ln[i]) + #13#10;
  ok := False;
  h := CreateFileW(PWideChar(DirPath + 'duplex-report.txt'), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h <> INVALID_HANDLE_VALUE then
  begin
    got := 0;
    ok := WriteFile(h, {$ifdef wince}@txt[1]{$else}txt[1]{$endif}, Length(txt), {$ifdef wince}@got{$else}got{$endif}, nil);
    CloseHandle(h);
  end;
  if ok then Note := 'Saved duplex-report.txt next to the program.' else Note := 'Could not save here.';
end;

{ ---------- drawing ---------- }

function US(const s: ShortString): UnicodeString;
var i: Integer;
begin
  SetLength(Result, Length(s));
  for i := 1 to Length(s) do Result[i] := WideChar(Ord(s[i]));
end;

procedure Txt(dc: HDC; const s: UnicodeString; rc: TRect; f: HFONT; col: COLORREF; flags: UINT);
var old: HGDIOBJ;
begin
  if Length(s) = 0 then Exit;
  old := SelectObject(dc, f);
  SetBkMode(dc, TRANSPARENT);
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

procedure Draw(dc: HDC);
var i, y: Integer; rc: TRect; col: COLORREF; lab: UnicodeString;
begin
  FillR(dc, MkRect(0, 0, CW, CH), $EEF2F4);
  FillR(dc, MkRect(0, 0, CW, HEAD_H), COL_NAVY);
  Txt(dc, APPNAME + '  ' + US(VERSION), MkRect(PAD, 5, 400, HEAD_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
  FillR(dc, MkRect(PAD, HEAD_H + 6, CW - PAD, CH - FOOT_H - 2), COL_CARD);
  if (LnN = 0) and (not Running) then
  begin
    Txt(dc, 'Does this handheld''s sound chip play and record at the same time?', MkRect(PAD + 10, HEAD_H + 14, CW - PAD - 10, HEAD_H + 40), fBold, COL_INK, DT_LEFT or DT_WORDBREAK);
    Txt(dc, 'The test takes about 10 seconds and plays a one second beep. Press Enter or tap Run. Keep the volume low.', MkRect(PAD + 10, HEAD_H + 46, CW - PAD - 10, CH - FOOT_H - 8), fNorm, COL_MUTED, DT_LEFT or DT_WORDBREAK);
  end
  else
  begin
    y := HEAD_H + 10;
    for i := 0 to LnN - 1 do
    begin
      case LnOk[i] of 1: col := COL_GOOD; 2: col := COL_FAIL; else col := COL_INK; end;
      Txt(dc, US(Ln[i]), MkRect(PAD + 8, y, CW - PAD - 4, y + 13), fSmall, col, DT_LEFT or DT_SINGLELINE);
      Inc(y, 13);
    end;
    if Running then Txt(dc, 'running...', MkRect(PAD + 8, y, CW - PAD - 4, y + 13), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  end;
  { buttons }
  for i := 0 to 2 do
  begin
    rc := MkRect(PAD + i * (CW div 3), CH - FOOT_H + 4, PAD + i * (CW div 3) + (CW div 3) - 16, CH - 4);
    FillR(dc, rc, COL_LINE);
    FillR(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD);
    case i of 0: lab := 'Run'; 1: lab := 'Save'; else lab := 'Quit'; end;
    Txt(dc, lab, rc, fBold, COL_NAVY, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  end;
  if Note <> '' then Txt(dc, Note, MkRect(PAD + 8, CH - FOOT_H - 18, CW - PAD, CH - FOOT_H - 3), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
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

procedure Leave;
var n: Integer;
begin
  Quit := True;
  n := 0;
  if (hThread <> 0) and Running then while (WaitForSingleObject(hThread, 100) <> WAIT_OBJECT_0) and (n < 100) do Inc(n);
  DestroyWindow(hMain);
end;

procedure OnKey(vk: Integer);
begin
  case vk of
    $0D: StartTest;
    Ord('S'): SaveReport;
    Ord('Q'): Leave;
  end;
end;

procedure OnTap(x, y: Integer);
begin
  if y < CH - FOOT_H then Exit;
  case (x - PAD) div (CW div 3) of
    0: StartTest;
    1: SaveReport;
    2: Leave;
  end;
end;

function WndProc(wnd: HWND; wmsg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; API;
begin
  Result := 0;
  case wmsg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_UPDATE, WM_TIMER: InvalidateRect(wnd, nil, False);
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
  FillChar(wc, SizeOf(wc), 0);
  wc.style := CS_HREDRAW or CS_VREDRAW;
  wc.lpfnWndProc := @WndProc;
  wc.hInstance := GetModuleHandleW(nil);
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
    wa.left, wa.top, CW, CH, 0, 0, GetModuleHandleW(nil), nil);
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
