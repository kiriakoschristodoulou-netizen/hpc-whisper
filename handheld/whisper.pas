program whisper;
{ HPC Whisper: type on a Windows CE handheld PC (made on an HP Jornada 720),
  and the text appears on your phone,
  carried by tones too high to hear (20 to 21.5 kHz by default).

  The phone listens with the receiver page (see README). The page finds the
  band and speed by itself, so only the handheld has settings.

  Sound is made in a second thread as a continuous stream (silence between
  messages), so there is no click when a message starts. What you type goes
  into a queue; whenever the sound is free, everything waiting (up to 48
  bytes) goes out as one frame, so fast typing simply makes longer frames.

  Every function not yet seen working on the device is looked up by name at
  run time. Builds for Windows CE (ARM) and for desktop Windows (testing). }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R whisper.res}
uses Windows, wmodem;

const
  VERSION = '1.2';
  CREATOR = 'Kyriakos Christodoulou';
  CLSNAME: UnicodeString = 'HPCWhisper';
  APPNAME: UnicodeString = 'HPC Whisper';
  CFGNAME: UnicodeString = 'whisper.cfg';
  WM_UPDATE = WM_APP + 1;

  RATE = 44100;
  BUF_N = 4410;                    { 100 ms per buffer }
  NBUF = 3;                        { 0.3 s queued: less lag; the phone copes with a stall }
  DOCMAX = 6000;                   { characters kept on screen }
  TEST_TEXT = 'The quick brown fox jumps over the lazy dog. 0123456789' + #10;

  { screen }
  TITLE_H = 22;
  TEXT_Y = 25; TEXT_X = 8;
  STATUS_Y = 166;
  BTN_Y = 186; BTN_H = 25; NBTN = 6;
  BTN_LABEL: array[0..NBTN - 1] of UnicodeString = ('Band', 'Speed', 'Volume', 'Test', 'Clear', 'Exit');
  BTN_KEY: array[0..NBTN - 1] of UnicodeString = ('^B', '^P', '^V', '^T', '^L', '^Q');

  COL_NAVY = $36251B; COL_TEXT = $3C2D23; COL_GREY = $8C8278; COL_HI = $F6EEE8;
  COL_SEND = $3C8200; COL_FAIL = $2828BE; COL_PAPER = $FFFFFF;

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
  HWAVEOUT_ = THandle;

  TNumDevs = function: UINT; API;
  TOpen = function(out h: HWAVEOUT_; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; API;
  THdrFn = function(h: HWAVEOUT_; hdr: PWaveHdr; size: UINT): UINT; API;
  THandleFn = function(h: HWAVEOUT_): UINT; API;
  TSetVol = function(h: HWAVEOUT_; vol: DWORD): UINT; API;
  TGetVol = function(h: HWAVEOUT_; vol: PDWORD): UINT; API;
  TGetModuleFileNameW = function(h: HMODULE; buf: PWideChar; n: DWORD): DWORD; API;

var
  pNumDevs: TNumDevs; pOpen: TOpen;
  pPrepare, pUnprepare, pWrite: THdrFn; pReset, pClose: THandleFn;
  pSetVol: TSetVol; pGetVol: TGetVol;
  pGetModuleFileNameW: TGetModuleFileNameW;
  hCore: HMODULE = 0;
  MissingNames: UnicodeString = '';

  AppInst: HINST;
  hMain: HWND;
  CW, CH: Integer;
  fNorm, fBold, fBig, fMono: HFONT;
  MonoW: Integer = 8; MonoH: Integer = 14;
  Measured: Boolean = False;

  { settings (main thread writes, sound thread reads when a frame starts) }
  Band: Integer = NBANDS - 1;
  Speed: Integer = 2;              { Fast: the least lag; Ctrl+P for Normal or Slow }
  Volume: Integer = 50;
  CfgPath: UnicodeString = '';

  { what you typed, as shown }
  Doc: array[0..DOCMAX - 1] of WideChar;
  DocN: Integer = 0;

  { the queue: main thread adds, sound thread takes }
  { the document as the phone should see it: main thread changes it, sound thread sends it }
  Lock: TRTLCriticalSection;
  Snd: TSender;

  { sound thread state shown on screen }
  SoundOK: Boolean = False;
  SoundErr: UnicodeString = '';
  SendingN: Integer = 0;           { bytes in the frame now playing, 0 = none }
  SendingMs: Integer = 0;
  FramesSent: Integer = 0;
  Quit: Boolean = False;
  hThread: THandle = 0;
  hWave: HWAVEOUT_ = 0;
  OldVol: DWORD = 0;
  HaveOldVol: Boolean = False;
  Hdr: array[0..NBUF - 1] of TWaveHdr;
  Buf: array[0..NBUF - 1, 0..BUF_N - 1] of SmallInt;
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

function KHz(hz: Integer): UnicodeString;           { 20000 -> "20.0" }
begin
  Result := IU(hz div 1000) + '.' + IU((hz mod 1000) div 100);
end;

function BandName(b: Integer): UnicodeString;
begin
  Result := KHz(BAND_HZ[b]) + '-' + KHz(BAND_HZ[b] + 15 * STEP_HZ) + ' kHz';
end;

function MkRect(l, t, r, b: Integer): TRect;
begin
  Result.left := l; Result.top := t; Result.right := r; Result.bottom := b;
end;

function MkFont(h, weight: Integer; const face: UnicodeString): HFONT;
var lf: LOGFONTW; i: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -h;
  lf.lfWeight := weight;
  lf.lfCharSet := DEFAULT_CHARSET;
  for i := 1 to Length(face) do lf.lfFaceName[i-1] := face[i];
  Result := CreateFontIndirectW(@lf);
end;

{ ---------- looking functions up by name ---------- }

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
  if Result = nil then
  begin
    if MissingNames <> '' then MissingNames := MissingNames + ', ';
    MissingNames := MissingNames + US(fn);
  end;
end;

procedure ResolveAll;
const MM = 'winmm.dll'; K = 'kernel32.dll';
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pNumDevs := TNumDevs(Find('waveOutGetNumDevs', MM));
  pOpen := TOpen(Find('waveOutOpen', MM));
  pPrepare := THdrFn(Find('waveOutPrepareHeader', MM));
  pUnprepare := THdrFn(Find('waveOutUnprepareHeader', MM));
  pWrite := THdrFn(Find('waveOutWrite', MM));
  pReset := THandleFn(Find('waveOutReset', MM));
  pClose := THandleFn(Find('waveOutClose', MM));
  pSetVol := TSetVol(Find('waveOutSetVolume', MM));
  pGetVol := TGetVol(Find('waveOutGetVolume', MM));
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', K));
end;

{ ---------- settings file: four bytes next to the program ---------- }

procedure FindCfg;
var buf: array[0..259] of WideChar; n, i, cut: Integer;
begin
  CfgPath := CFGNAME;
  if not Assigned(pGetModuleFileNameW) then Exit;
  n := pGetModuleFileNameW(0, @buf[0], 259);
  if n <= 0 then Exit;
  cut := 0;
  for i := 0 to n - 1 do if buf[i] = '\' then cut := i + 1;
  SetLength(CfgPath, cut);
  for i := 0 to cut - 1 do CfgPath[i + 1] := buf[i];
  CfgPath := CfgPath + CFGNAME;
end;

procedure LoadCfg;
var h: THandle; b: array[0..3] of Byte; got: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 4, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 4) and (b[0] = $57) then
  begin
    if b[1] < NBANDS then Band := b[1];
    if b[2] < NSPEEDS then Speed := b[2];
    if (b[3] >= 10) and (b[3] <= 100) then Volume := b[3];
  end;
  CloseHandle(h);
end;

procedure SaveCfg;
var h: THandle; b: array[0..3] of Byte; got: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  b[0] := $57; b[1] := Band; b[2] := Speed; b[3] := Volume;
  got := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, 4, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
end;

{ ---------- the queue ---------- }

procedure SendChar(c: WideChar);
begin
  EnterCriticalSection(Lock);
  SnType(Snd, c, GetTickCount);
  LeaveCriticalSection(Lock);
end;

procedure SendBackspace;
begin
  EnterCriticalSection(Lock);
  SnBackspace(Snd, GetTickCount);
  LeaveCriticalSection(Lock);
end;

procedure SendNewDocument;
begin
  EnterCriticalSection(Lock);
  SnNewDoc(Snd);
  LeaveCriticalSection(Lock);
end;

{ bytes typed that have not gone out even once }
function Waiting: Integer;
begin
  EnterCriticalSection(Lock);
  Result := Snd.L - Snd.liveFrom;
  LeaveCriticalSection(Lock);
end;

{ ---------- the sound thread ---------- }

function OpenSound: Boolean;
var fmt: TWaveFormat; v: DWORD;
begin
  Result := False;
  if MissingNames <> '' then begin SoundErr := 'Missing: ' + MissingNames; Exit; end;
  if pNumDevs() = 0 then begin SoundErr := 'No sound device found.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := RATE; fmt.bits := 16;
  fmt.align := 2; fmt.bytesPerSec := RATE * 2;
  if pOpen(hWave, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then
  begin
    SoundErr := 'The sound device would not open at 44100 samples/s.';
    Exit;
  end;
  { the system volume goes to full while the program runs (your volume
    setting scales the tones themselves), and back when it closes }
  v := 0;
  if pGetVol(0, @v) = 0 then begin OldVol := v; HaveOldVol := True; end;
  pSetVol(0, $FFFFFFFF);
  pSetVol(hWave, $FFFFFFFF);
  Result := True;
end;

function SoundThread(param: Pointer): DWORD; API;
var k, i, n: Integer; playing: array[0..NBUF - 1] of Boolean; busy, was: Boolean;
    f: TFrame; got: Boolean;
begin
  Result := 0;
  SoundOK := OpenSound;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
  if not SoundOK then Exit;
  TmInit(Tm, RATE);
  for i := 0 to NBUF - 1 do playing[i] := False;
  busy := False;
  k := 0;
  while not Quit do
  begin
    if playing[k] then
    begin
      while ((Hdr[k].flags and WHDR_DONE_) = 0) and not Quit do Sleep(5);
      pUnprepare(hWave, @Hdr[k], SizeOf(TWaveHdr));
      playing[k] := False;
    end;
    if Quit then Break;
    { free: the next frame, if the document has something to send (new
      text at once, repeats during pauses) }
    if not busy then
    begin
      EnterCriticalSection(Lock);
      got := SnNext(Snd, GetTickCount, f);
      LeaveCriticalSection(Lock);
      if got then
      begin
        Tm.band := Band; Tm.speed := Speed; Tm.volume := Volume;
        TmStart(Tm, f);
        SendingN := 1; SendingMs := FrameMs(f, Speed);
        PostMessageW(hMain, WM_UPDATE, 0, 0);
      end;
    end;
    was := busy;
    busy := TmFill(Tm, Buf[k], BUF_N);
    if was and not busy then
    begin
      SendingN := 0; Inc(FramesSent);
      PostMessageW(hMain, WM_UPDATE, 0, 0);
    end;
    FillChar(Hdr[k], SizeOf(TWaveHdr), 0);
    Hdr[k].data := @Buf[k][0];
    Hdr[k].len := BUF_N * 2;
    if pPrepare(hWave, @Hdr[k], SizeOf(TWaveHdr)) = 0 then
      if pWrite(hWave, @Hdr[k], SizeOf(TWaveHdr)) = 0 then playing[k] := True;
    if not playing[k] then Sleep(100);           { writing failed: do not spin }
    k := (k + 1) mod NBUF;
  end;
  pReset(hWave);
  for k := 0 to NBUF - 1 do if playing[k] then pUnprepare(hWave, @Hdr[k], SizeOf(TWaveHdr));
  pClose(hWave);
  if HaveOldVol then pSetVol(0, OldVol);
end;

{ ---------- the text ---------- }

procedure DocAdd(c: WideChar);
begin
  if DocN >= DOCMAX then
  begin
    Move(Doc[1000], Doc[0], (DOCMAX - 1000) * SizeOf(WideChar));
    Dec(DocN, 1000);
  end;
  Doc[DocN] := c; Inc(DocN);
end;

procedure TypeText(const s: UnicodeString);
var i: Integer;
begin
  for i := 1 to Length(s) do
  begin
    DocAdd(s[i]);
    SendChar(s[i]);
  end;
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

function BtnRect(i: Integer): TRect;
var w: Integer;
begin
  w := (CW - 16 - (NBTN - 1) * 5) div NBTN;
  Result := MkRect(8 + i * (w + 5), BTN_Y, 8 + i * (w + 5) + w, BTN_Y + BTN_H);
end;

procedure MeasureMono(dc: HDC);
var rc: TRect; old: HGDIOBJ; s: UnicodeString;
begin
  s := 'MMMMMMMMMMMMMMMMMMMM';
  rc := MkRect(0, 0, 1000, 100);
  old := SelectObject(dc, fMono);
  DrawTextW(dc, PWideChar(s), Length(s), rc, DT_CALCRECT or DT_SINGLELINE or DT_NOPREFIX);
  SelectObject(dc, old);
  if rc.right > 20 then MonoW := (rc.right + 10) div 20;
  if rc.bottom > 8 then MonoH := rc.bottom;
end;

{ the end of the text, wrapped to the width, as many lines as fit }
procedure DrawDoc(dc: HDC);
const MAXL = 400;
var cols, rows, i, j, nl, start, x: Integer;
    ls, ln: array[0..MAXL - 1] of Integer;     { line starts and lengths }
    line: UnicodeString; y: Integer;
begin
  cols := (CW - 2 * TEXT_X) div MonoW;
  rows := (STATUS_Y - 2 - TEXT_Y) div MonoH;
  if cols < 10 then cols := 10;
  { wrap the last part of the document only (enough for the screen) }
  start := DocN - cols * rows * 2;
  if start < 0 then start := 0;
  while (start > 0) and (Doc[start - 1] <> #10) do Dec(start);
  nl := 0; i := start;
  ls[0] := start; ln[0] := 0;
  while i < DocN do
  begin
    if Doc[i] = #10 then
    begin
      Inc(nl); if nl >= MAXL then Break;
      ls[nl] := i + 1; ln[nl] := 0;
    end
    else
    begin
      if ln[nl] >= cols then
      begin
        { break at the last space, if there is one }
        j := ls[nl] + ln[nl] - 1;
        while (j > ls[nl]) and (Doc[j] <> ' ') do Dec(j);
        Inc(nl); if nl >= MAXL then Break;
        if (j > ls[nl - 1]) and (Doc[j] = ' ') then
        begin
          ln[nl - 1] := j + 1 - ls[nl - 1];
          ls[nl] := j + 1; ln[nl] := i - (j + 1);
        end
        else begin ls[nl] := i; ln[nl] := 0; end;
      end;
      Inc(ln[nl]);
    end;
    Inc(i);
  end;
  if nl >= MAXL then nl := MAXL - 1;
  { draw the last rows }
  j := nl - rows + 1; if j < 0 then j := 0;
  y := TEXT_Y;
  for i := j to nl do
  begin
    SetLength(line, ln[i]);
    for x := 0 to ln[i] - 1 do line[x + 1] := Doc[ls[i] + x];
    Txt(dc, line, MkRect(TEXT_X, y, CW - TEXT_X, y + MonoH), fMono, COL_TEXT, DT_LEFT or DT_SINGLELINE);
    if i = nl then
    begin
      { the cursor }
      x := TEXT_X + ln[i] * MonoW;
      if x > CW - TEXT_X - 2 then x := CW - TEXT_X - 2;
      FillR(dc, MkRect(x + 1, y + 1, x + 3, y + MonoH - 1), COL_SEND);
    end;
    y := y + MonoH;
  end;
  if DocN = 0 then
    Txt(dc, 'Start typing. Open the receiver page on your phone, tap Listen, and hold it near this handheld.',
        MkRect(TEXT_X + 12, TEXT_Y, CW - TEXT_X, TEXT_Y + 40), fNorm, COL_GREY, DT_LEFT or DT_WORDBREAK);
end;

procedure Draw(dc: HDC);
var i, w: Integer; rc: TRect; s: UnicodeString; col: COLORREF;
begin
  if not Measured then begin MeasureMono(dc); Measured := True; end;
  FillR(dc, MkRect(0, 0, CW, CH), COL_PAPER);
  SetBkMode(dc, TRANSPARENT);
  FillR(dc, MkRect(0, 0, CW, TITLE_H), COL_NAVY);
  Txt(dc, APPNAME + ' ' + VERSION {$ifndef wince} + '  (desktop test build)'{$endif},
      MkRect(8, 3, 400, TITLE_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'by ' + CREATOR, MkRect(300, 5, CW - 8, TITLE_H), fNorm, $E6D2C8, DT_RIGHT or DT_SINGLELINE);

  DrawDoc(dc);

  { status line }
  FillR(dc, MkRect(0, STATUS_Y - 2, CW, STATUS_Y - 1), $E0D8D0);
  s := BandName(Band) + '   ' + US(SPEED_NAME[Speed]) + ' (' + IU(SPEED_MS[Speed]) + ' ms)   Volume ' + IU(Volume) + '%';
  Txt(dc, s, MkRect(8, STATUS_Y + 1, CW - 8, STATUS_Y + 17), fNorm, COL_GREY, DT_LEFT or DT_SINGLELINE);
  w := Waiting;
  if not SoundOK then
  begin
    if SoundErr = '' then s := 'Opening sound...' else s := SoundErr;
    col := COL_FAIL;
  end
  else if SendingN > 0 then
  begin
    if w > 0 then s := 'Sending, ' + IU(w) + ' waiting' else s := 'Sending';
    col := COL_SEND;
  end
  else if w > 0 then begin s := IU(w) + ' waiting'; col := COL_SEND; end
  else begin s := 'Ready   (' + IU(FramesSent) + ' sent)'; col := COL_GREY; end;
  Txt(dc, s, MkRect(8, STATUS_Y + 1, CW - 8, STATUS_Y + 17), fBold, col, DT_RIGHT or DT_SINGLELINE);

  for i := 0 to NBTN - 1 do
  begin
    rc := BtnRect(i);
    FillR(dc, rc, COL_NAVY);
    FillR(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_HI);
    Txt(dc, BTN_LABEL[i], MkRect(rc.left + 8, rc.top + 5, rc.right - 8, rc.bottom), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
    Txt(dc, BTN_KEY[i], MkRect(rc.left + 8, rc.top + 5, rc.right - 8, rc.bottom), fNorm, COL_GREY, DT_RIGHT or DT_SINGLELINE);
  end;
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
  SaveCfg;
  Quit := True;
  n := 0;
  if hThread <> 0 then
    while (WaitForSingleObject(hThread, 100) <> WAIT_OBJECT_0) and (n < 30) do Inc(n);
  DestroyWindow(hMain);
end;

procedure Command(c: Integer);
begin
  case c of
    0: begin Band := (Band + 1) mod NBANDS; SaveCfg; end;
    1: begin Speed := (Speed + 1) mod NSPEEDS; SaveCfg; end;
    2: begin Volume := Volume + 10; if Volume > 100 then Volume := 10; SaveCfg; end;
    3: TypeText(TEST_TEXT);
    4: begin DocN := 0; SendNewDocument; end;      { a fresh page, here and on the phone }
    5: Leave;
  end;
end;

procedure OnTap(x, y: Integer);
var i: Integer; rc: TRect;
begin
  for i := 0 to NBTN - 1 do
  begin
    rc := BtnRect(i);
    if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then begin Command(i); Exit; end;
  end;
end;

procedure OnChar(c: Integer);
begin
  case c of
    2: Command(0);                 { Ctrl+B }
    16: Command(1);                { Ctrl+P }
    22: Command(2);                { Ctrl+V }
    20: Command(3);                { Ctrl+T }
    12: Command(4);                { Ctrl+L }
    17: Command(5);                { Ctrl+Q }
    8:
      if DocN > 0 then
      begin
        Dec(DocN);
        SendBackspace;
      end;
    13: begin DocAdd(#10); SendChar(#10); end;
    9: TypeText(' ');
  else
    if c >= 32 then begin DocAdd(WideChar(c)); SendChar(WideChar(c)); end;
  end;
end;

function WndProc(wnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; API;
begin
  Result := 0;
  case msg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_UPDATE: InvalidateRect(wnd, nil, False);
    WM_LBUTTONDOWN:
      begin
        OnTap(SmallInt(lp and $FFFF), SmallInt((lp shr 16) and $FFFF));
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_CHAR:
      begin
        OnChar(wp);
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_CLOSE: Leave;
    WM_DESTROY: if wnd = hMain then PostQuitMessage(0);
  else
    Result := DefWindowProcW(wnd, msg, wp, lp);
  end;
end;

var
  wc: WNDCLASSW;
  m: MSG;
  wa: TRect;
  tid: DWORD;
begin
  AppInst := GetModuleHandleW(nil);
  InitializeCriticalSection(Lock);
  SnInit(Snd, Byte(GetTickCount));                  { a new document id each start }
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
  fBig := MkFont(14, 700, 'Tahoma');
  fMono := MkFont(14, 400, 'Courier New');
  ResolveAll;
  FindCfg;
  LoadCfg;

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
  hThread := CreateThread(nil, 0, @SoundThread, nil, 0, tid);
  if hThread <> 0 then SetThreadPriority(hThread, THREAD_PRIORITY_ABOVE_NORMAL);   { sound must never wait for drawing }
  if hThread = 0 then begin SoundErr := 'The sound thread could not start.'; InvalidateRect(hMain, nil, False); end;
  while GetMessageW(@m, 0, 0, 0) do
  begin
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end.
