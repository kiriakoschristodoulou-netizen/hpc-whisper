program whisper;
{ HPC Whisper: type on a Windows CE handheld PC (made on an HP Jornada 720),
  and the text appears in any app on your phone, carried by tones too high to
  hear (20 to 21.5 kHz by default).

  The phone listens with the HPC Whisper keyboard (or the receiver page, see
  README). It finds the band and speed by itself, so only the handheld has
  settings.

  There is no way back from the phone, so every piece of text is sent several
  times, a little later each time, and on two different bands (wmodem.pas).

  Sound is made in a second thread as a continuous stream (silence between
  messages), so there is no click when a message starts. What you type goes
  into the sender's document; whenever the sound is free, the next frame goes
  out (new text at once, repeats during pauses).

  Every function not yet seen working on the device is looked up by name at
  run time. Builds for Windows CE (ARM) and for desktop Windows (testing). }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R whisper.res}
uses Windows, wmodem, wback;

const
  VERSION = '1.1';
  CREATOR = 'Kyriakos Christodoulou';
  CLSNAME: UnicodeString = 'HPCWhisper';
  APPNAME: UnicodeString = 'HPC Whisper';
  CFGNAME: UnicodeString = 'whisper.cfg';
  WM_UPDATE = WM_APP + 1;

  RATE_WINDOWS = 44100;            { the usual: Windows converts it to the chip's rate }
  RATE_CHIP = 43200;               { the Jornada 720's sound chip really runs at this rate }
  BUF_N = 4410;                    { 100 ms per buffer }
  NBUF = 3;                        { 0.3 s queued: less lag; the phone copes with a stall }
  SHOWMAX = 8000;                  { characters kept on screen }
  TEST_TEXT = 'The quick brown fox jumps over the lazy dog. 0123456789' + #10;

  SCR_TYPE = 0; SCR_SETTINGS = 1; SCR_KEYS = 2; SCR_ABOUT = 3;

  { screen }
  HEAD_H = 30; FOOT_H = 42; PAD = 8;

  { colours are BGR }
  COL_NAVY = $36251B; COL_PAPER = $EEF2F4; COL_CARD = $FFFFFF; COL_INK = $30241D; COL_MUTED = $786F6B;
  COL_LINE = $D0D8DC; COL_GOOD = $1F8A3D; COL_FAIL = $4F60E5; COL_AMBER = $4AA0E8; COL_GREEN_ON_NAVY = $5AC77F;
  COL_KEYBG = $FBE6DC; COL_KEYFG = $B05D2A; COL_HEADKEY = $E6D2C8; COL_PILL_IDLE = $5A4A3C; COL_ROW_SEL = $F6EEE8;

  VK_BACK_ = $08; VK_TAB_ = $09; VK_RETURN_ = $0D; VK_SHIFT_ = $10; VK_CONTROL_ = $11; VK_MENU_ = $12; VK_ESCAPE_ = $1B;
  VK_PRIOR_ = $21; VK_NEXT_ = $22; VK_END_ = $23; VK_HOME_ = $24; VK_LEFT_ = $25; VK_UP_ = $26; VK_RIGHT_ = $27; VK_DOWN_ = $28;
  VK_DELETE_ = $2E;

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
  TRoundRect = function(dc: HDC; l, t, r, b, w, h: Integer): BOOL; API;

var
  pNumDevs: TNumDevs; pOpen: TOpen;
  pPrepare, pUnprepare, pWrite: THdrFn; pReset, pClose: THandleFn;
  pSetVol: TSetVol; pGetVol: TGetVol;
  pGetModuleFileNameW: TGetModuleFileNameW;
  pRoundRect: TRoundRect;
  hCore: HMODULE = 0;
  MissingNames: UnicodeString = '';

  AppInst: HINST;
  hMain: HWND;
  CW, CH: Integer;
  fNorm, fBold, fBig, fMono, fSmall: HFONT;
  MonoW: Integer = 8; MonoH: Integer = 14;
  Measured: Boolean = False;
  Screen: Integer = SCR_TYPE;
  SetSel: Integer = 0;
  ShiftDown, CtrlDown: Boolean;
  CfgPath: UnicodeString = '';

  { settings (main thread writes, sound thread reads when a frame starts) }
  Band: Integer = 2;               { 19.0 - 20.5 kHz }
  Speed: Integer = 2;              { Fast: 20 ms a tone (worked best in tests) }
  Volume: Integer = 50;
  Sends: Integer = DEFAULT_SENDS;  { every piece of text goes out this many times }
  TwoBands: Boolean = True;        { the repeats go on another band }
  ChipRate: Boolean = True;        { play at the chip's own 43,200 instead of 44,100 }
  ReturnOn: Boolean = True;        { listen for the phone's acknowledgements (the return channel) }
  LastAckSeq: LongInt = 0;

  { what you typed, as shown: characters, and keys as characters from the private area }
  Show: array[0..SHOWMAX - 1] of WideChar;
  ShowN: Integer = 0;

  { the document as the phone should see it: main thread changes it, sound thread sends it }
  Lock: TRTLCriticalSection;
  Snd: TSender;

  { sound thread state shown on screen }
  SoundOK: Boolean = False;
  SoundErr: UnicodeString = '';
  SendingN: Integer = 0;           { 1 while a frame is playing }
  FramesSent: Integer = 0;
  Quit: Boolean = False;
  hThread: THandle = 0;
  WantRate: Integer = RATE_CHIP;
  OldVol: DWORD = 0;
  HaveOldVol: Boolean = False;
  hWave: HWAVEOUT_ = 0;
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
  Result := KHz(BAND_HZ[b]) + ' - ' + KHz(BAND_HZ[b] + 15 * STEP_HZ) + ' kHz';
end;

{ the band the repeats use: one kHz away from the first, on the side with room }
function AltBand: Integer;
begin
  if not TwoBands then begin Result := Band; Exit; end;
  if Band >= 2 then Result := Band - 2 else Result := Band + 2;
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
  pNumDevs := TNumDevs(Find('waveOutGetNumDevs', MM, True));
  pOpen := TOpen(Find('waveOutOpen', MM, True));
  pPrepare := THdrFn(Find('waveOutPrepareHeader', MM, True));
  pUnprepare := THdrFn(Find('waveOutUnprepareHeader', MM, True));
  pWrite := THdrFn(Find('waveOutWrite', MM, True));
  pReset := THandleFn(Find('waveOutReset', MM, True));
  pClose := THandleFn(Find('waveOutClose', MM, True));
  pSetVol := TSetVol(Find('waveOutSetVolume', MM, True));
  pGetVol := TGetVol(Find('waveOutGetVolume', MM, True));
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', K, True));
  pRoundRect := TRoundRect(Find('RoundRect', G, False));         { only for looks: plain corners without it }
end;

{ ---------- settings file: next to the program ---------- }

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
var h: THandle; b: array[0..7] of Byte; got: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 8, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 8) and (b[0] = $59) then
  begin
    if b[1] < NBANDS then Band := b[1];
    if b[2] < NSPEEDS then Speed := b[2];
    if (b[3] >= 10) and (b[3] <= 100) then Volume := b[3];
    if (b[4] >= 2) and (b[4] <= MAX_SENDS) then Sends := b[4];
    TwoBands := b[5] <> 0;
    ChipRate := b[6] <> 0;
    ReturnOn := b[7] = 0;
  end;
  CloseHandle(h);
end;

procedure SaveCfg;
var h: THandle; b: array[0..7] of Byte; got: DWORD;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  b[0] := $59; b[1] := Band; b[2] := Speed; b[3] := Volume; b[4] := Sends;
  b[5] := Ord(TwoBands); b[6] := Ord(ChipRate); b[7] := Ord(not ReturnOn);
  got := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, 8, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
end;

{ ---------- what you type ---------- }

procedure ShowAdd(c: WideChar);
begin
  if ShowN >= SHOWMAX then
  begin
    Move(Show[1000], Show[0], (SHOWMAX - 1000) * SizeOf(WideChar));
    Dec(ShowN, 1000);
  end;
  Show[ShowN] := c; Inc(ShowN);
end;

function IsKeyChar(c: WideChar): Boolean; inline;
begin
  Result := (Ord(c) >= KEY_BASE) and (Ord(c) < KEY_BASE + $400);
end;

function Utf8Len(c: WideChar): Integer;
begin
  if Ord(c) < $80 then Result := 1 else if Ord(c) < $800 then Result := 2 else Result := 3;
end;

procedure TypeChar(c: WideChar);
begin
  ShowAdd(c);
  EnterCriticalSection(Lock);
  SnType(Snd, c, GetTickCount);
  LeaveCriticalSection(Lock);
end;

procedure TypeKey(code: Integer);
begin
  ShowAdd(WideChar(KEY_BASE + code));
  EnterCriticalSection(Lock);
  SnKey(Snd, code, GetTickCount);
  LeaveCriticalSection(Lock);
end;

{ as the phone sees it: a character typed since the last key goes; otherwise the phone deletes }
procedure TypeBackspace;
var typed: Boolean;
begin
  EnterCriticalSection(Lock);
  typed := Snd.L > Snd.keyEnd;
  if typed then SnBackspace(Snd, GetTickCount);
  LeaveCriticalSection(Lock);
  if typed then begin if (ShowN > 0) and not IsKeyChar(Show[ShowN - 1]) then Dec(ShowN); end
  else TypeKey(K_BACKSPACE);
end;

procedure TypeDeleteWord;
var typed: Boolean; before, after, cut: Integer;
begin
  EnterCriticalSection(Lock);
  before := Snd.L;
  typed := Snd.L > Snd.keyEnd;
  if typed then SnDeleteWord(Snd, GetTickCount);
  after := Snd.L;
  LeaveCriticalSection(Lock);
  if typed then
  begin
    cut := before - after;                          { bytes that went; the same characters leave the screen }
    while (cut > 0) and (ShowN > 0) and not IsKeyChar(Show[ShowN - 1]) do
    begin
      Dec(cut, Utf8Len(Show[ShowN - 1]));
      Dec(ShowN);
    end;
  end
  else TypeKey(K_BACKSPACE or KEY_CTRL);
end;

procedure TypeText(const s: UnicodeString);
var i: Integer;
begin
  for i := 1 to Length(s) do TypeChar(s[i]);
end;

procedure NewPage;
begin
  ShowN := 0;
  EnterCriticalSection(Lock);
  SnNewDoc(Snd);
  LeaveCriticalSection(Lock);
end;

procedure ResendText;
begin
  EnterCriticalSection(Lock);
  SnResend(Snd, GetTickCount);
  LeaveCriticalSection(Lock);
end;

procedure ApplySends;
begin
  EnterCriticalSection(Lock);
  Snd.target := Sends;
  LeaveCriticalSection(Lock);
end;

{ ---------- the sound thread ---------- }

function OpenSound(rate: Integer): Boolean;
var fmt: TWaveFormat; v: DWORD;
begin
  Result := False;
  if MissingNames <> '' then begin SoundErr := 'Missing: ' + MissingNames; Exit; end;
  if pNumDevs() = 0 then begin SoundErr := 'No sound device found.'; Exit; end;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := rate; fmt.bits := 16;
  fmt.align := 2; fmt.bytesPerSec := rate * 2;
  if pOpen(hWave, WAVE_MAPPER_, @fmt, 0, 0, 0) <> 0 then
  begin
    SoundErr := 'The sound device would not open at ' + IU(rate) + ' samples/s.';
    Exit;
  end;
  SoundErr := '';
  { the system volume goes to full while the program runs (your volume
    setting scales the tones themselves), and back when it closes }
  if not HaveOldVol then
  begin
    v := 0;
    if pGetVol(0, @v) = 0 then begin OldVol := v; HaveOldVol := True; end;
  end;
  pSetVol(0, $FFFFFFFF);
  pSetVol(hWave, $FFFFFFFF);
  Result := True;
end;

function SoundThread(param: Pointer): DWORD; API;
var k, i: Integer; playing: array[0..NBUF - 1] of Boolean; busy, was: Boolean;
    f: TFrame; got: Boolean; rate: Integer;
begin
  Result := 0;
  rate := WantRate;
  SoundOK := OpenSound(rate);
  if (not SoundOK) and (rate <> RATE_WINDOWS) then
  begin
    rate := RATE_WINDOWS; WantRate := rate;
    SoundOK := OpenSound(rate);
  end;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
  if not SoundOK then Exit;
  TmInit(Tm, rate);
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
    { the sound rate was changed in Settings: start again at the new one, between frames }
    if (WantRate <> rate) and not busy then
    begin
      for i := 0 to NBUF - 1 do
        if playing[i] then
        begin
          while ((Hdr[i].flags and WHDR_DONE_) = 0) and not Quit do Sleep(5);
          pUnprepare(hWave, @Hdr[i], SizeOf(TWaveHdr));
          playing[i] := False;
        end;
      pReset(hWave); pClose(hWave);
      rate := WantRate;
      SoundOK := OpenSound(rate);
      if not SoundOK and (rate <> RATE_WINDOWS) then
      begin
        rate := RATE_WINDOWS; WantRate := rate; ChipRate := False;
        SoundOK := OpenSound(rate);
      end;
      PostMessageW(hMain, WM_UPDATE, 0, 0);
      if not SoundOK then Exit;
      TmInit(Tm, rate);
    end;
    { free: the next frame, if the document has something to send (new
      text at once, repeats during pauses) }
    if not busy then
    begin
      EnterCriticalSection(Lock);
      got := SnNext(Snd, GetTickCount, f);
      LeaveCriticalSection(Lock);
      if got then
      begin
        if f.alt then Tm.band := AltBand else Tm.band := Band;
        Tm.speed := Speed; Tm.volume := Volume;
        TmStart(Tm, f);
        SendingN := 1;
        PostMessageW(hMain, WM_UPDATE, 0, 0);
      end;
    end;
    was := busy;
    busy := TmFill(Tm, Buf[k], BUF_N);
    { the phone's acknowledgements (wback listens all the time) }
    if BkSeq <> LastAckSeq then
    begin
      LastAckSeq := BkSeq;
      if ReturnOn then
      begin
        EnterCriticalSection(Lock);
        SnAck(Snd, GetTickCount, BkDoc, BkP, BkG, BkHash);
        LeaveCriticalSection(Lock);
        PostMessageW(hMain, WM_UPDATE, 0, 0);
      end;
    end;
    if was and not busy then
    begin
      if ReturnOn and BkOn then
      begin
        EnterCriticalSection(Lock);
        SnFrameDone(Snd, GetTickCount);
        LeaveCriticalSection(Lock);
      end;
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

{ a rounded box without an outline (plain corners when the handheld has no RoundRect) }
procedure Rounded(dc: HDC; const rc: TRect; col: COLORREF; radius: Integer);
var br: HBRUSH; oldB, oldP: HGDIOBJ;
begin
  if not Assigned(pRoundRect) then begin FillR(dc, rc, col); Exit; end;
  br := CreateSolidBrush(col);
  oldB := SelectObject(dc, br);
  oldP := SelectObject(dc, GetStockObject(NULL_PEN));
  pRoundRect(dc, rc.left, rc.top, rc.right + 1, rc.bottom + 1, radius, radius);
  SelectObject(dc, oldP);
  SelectObject(dc, oldB);
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

function KeyLabel(code: Integer): UnicodeString;
var m: UnicodeString;
begin
  m := '';
  if (code and KEY_CTRL) <> 0 then m := 'Ctrl+';
  if (code and KEY_SHIFT) <> 0 then m := m + 'Shift+';
  case code and $FF of
    K_BACKSPACE: Result := m + 'Bksp'; K_TAB: Result := 'Tab'; K_SHIFT_TAB: Result := 'Shift+Tab'; K_ESC: Result := 'Esc';
    K_PGUP: Result := m + 'PgUp'; K_PGDN: Result := m + 'PgDn'; K_END: Result := m + 'End'; K_HOME: Result := m + 'Home';
    K_LEFT: Result := m + 'Left'; K_UP: Result := m + 'Up'; K_RIGHT: Result := m + 'Right'; K_DOWN: Result := m + 'Down';
    K_DELETE: Result := m + 'Del';
    K_SELALL: Result := 'Ctrl+A'; K_COPY: Result := 'Ctrl+C'; K_PASTE: Result := 'Ctrl+V'; K_CUT: Result := 'Ctrl+X';
    K_UNDO: Result := 'Ctrl+Z'; K_REDO: Result := 'Ctrl+Y';
    K_SEND: Result := 'Send'; K_BACK: Result := 'Back'; K_HOMESCREEN: Result := 'Phone home'; K_RECENTS: Result := 'Recents';
  else Result := 'Key';
  end;
end;

{ ---- the typed text: characters and key labels, wrapped to the width ---- }

const
  MAXTOK = 1600; MAXLINES = 420;

var
  TokCode: array[0..MAXTOK - 1] of Integer;     { a character, or -1 - key code }
  TokCols: array[0..MAXTOK - 1] of Integer;
  TokX: array[0..MAXTOK - 1] of Integer;        { column where the token starts in its line }
  NTok: Integer;
  LineAt: array[0..MAXLINES] of Integer;        { first token of each line }
  NLines: Integer;

function ChipCols(code: Integer): Integer;
begin
  Result := Length(KeyLabel(code)) + 1;           { room for the chip's padding }
end;

procedure Layout(cols: Integer);
var i, first, c, used, lastSp, j: Integer;
begin
  NTok := 0;
  first := ShowN - MAXTOK;
  if first < 0 then first := 0;
  for i := first to ShowN - 1 do
  begin
    if IsKeyChar(Show[i]) then
    begin
      TokCode[NTok] := -1 - (Ord(Show[i]) - KEY_BASE);
      TokCols[NTok] := ChipCols(Ord(Show[i]) - KEY_BASE);
    end
    else begin TokCode[NTok] := Ord(Show[i]); TokCols[NTok] := 1; end;
    Inc(NTok);
  end;
  NLines := 1; LineAt[0] := 0;
  used := 0; lastSp := -1;
  i := 0;
  while i < NTok do
  begin
    c := TokCode[i];
    if c = 10 then
    begin
      TokX[i] := used;
      if NLines >= MAXLINES then Break;
      LineAt[NLines] := i + 1; Inc(NLines);
      used := 0; lastSp := -1; Inc(i); Continue;
    end;
    if (used + TokCols[i] > cols) and (used > 0) then
    begin
      if NLines >= MAXLINES then Break;
      if lastSp >= LineAt[NLines - 1] then
      begin
        { break after the last space, and measure the carried words again }
        LineAt[NLines] := lastSp + 1; Inc(NLines);
        used := 0;
        for j := lastSp + 1 to i - 1 do begin TokX[j] := used; Inc(used, TokCols[j]); end;
        lastSp := -1;
      end
      else begin LineAt[NLines] := i; Inc(NLines); used := 0; lastSp := -1; end;
      Continue;                                    { the token is placed in the new line }
    end;
    TokX[i] := used; Inc(used, TokCols[i]);
    if c = 32 then lastSp := i;
    Inc(i);
  end;
  LineAt[NLines] := NTok;
end;

procedure DrawKeyChip(dc: HDC; x, y: Integer; const lbl: UnicodeString);
var w: Integer; rc: TRect;
begin
  w := TextW(dc, lbl, fSmall) + 10;
  rc := MkRect(x + 1, y + 1, x + w, y + MonoH - 1);
  Rounded(dc, rc, COL_KEYBG, 6);
  Txt(dc, lbl, MkRect(rc.left + 5, rc.top, rc.right, rc.bottom), fSmall, COL_KEYFG, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
end;

procedure DrawDoc(dc: HDC; const card: TRect);
var cols, rows, i, j, first, x, y, endTok, run, lx: Integer; s: UnicodeString; endX: Integer;
begin
  cols := (card.right - card.left - 2 * PAD) div MonoW;
  rows := (card.bottom - card.top - 2 * 6) div MonoH;
  if cols < 10 then cols := 10;
  if rows < 1 then rows := 1;
  Layout(cols);
  if ShowN = 0 then
  begin
    Txt(dc, 'Start typing.', MkRect(card.left + 14, card.top + 12, card.right - 14, card.top + 34), fBig, COL_INK, DT_LEFT or DT_SINGLELINE);
    Txt(dc, 'On the phone, open any app, tap a text field and switch to the HPC Whisper keyboard. ' +
        'Arrows, Ctrl+A C X V Z Y, Tab and the other keys go to the phone too (Alt+K shows them all).',
        MkRect(card.left + 14, card.top + 38, card.right - 14, card.bottom - 6), fNorm, COL_MUTED, DT_LEFT or DT_WORDBREAK);
    Exit;
  end;
  first := NLines - rows;
  if first < 0 then first := 0;
  y := card.top + 6;
  endX := 0;
  for i := first to NLines - 1 do
  begin
    j := LineAt[i];
    endTok := LineAt[i + 1];
    lx := 0;
    while j < endTok do
    begin
      if TokCode[j] = 10 then begin Inc(j); Continue; end;
      x := card.left + PAD + TokX[j] * MonoW;
      if TokCode[j] < 0 then
      begin
        DrawKeyChip(dc, x, y, KeyLabel(-1 - TokCode[j]));
        lx := TokX[j] + TokCols[j];
        Inc(j);
      end
      else
      begin
        run := j;
        s := '';
        while (run < endTok) and (TokCode[run] >= 0) and (TokCode[run] <> 10) do
        begin
          s := s + WideChar(TokCode[run]);
          Inc(run);
        end;
        Txt(dc, s, MkRect(x, y, card.right - 4, y + MonoH), fMono, COL_INK, DT_LEFT or DT_SINGLELINE);
        lx := TokX[j] + Length(s);
        j := run;
      end;
    end;
    if i = NLines - 1 then
    begin
      { the cursor: after the last line's text, unless that line is full }
      x := card.left + PAD + lx * MonoW;
      if x > card.right - PAD then x := card.right - PAD;
      endX := x;
      FillR(dc, MkRect(endX + 1, y + 1, endX + 3, y + MonoH - 1), COL_GOOD);
    end;
    y := y + MonoH;
  end;
end;

{ ---- the header: logo, name, and how the sending is going ---- }

procedure DrawLogo(dc: HDC; x, y: Integer);
var r, c: Integer;
begin
  { a tiny keyboard: three rows of keys }
  for r := 0 to 2 do
    for c := 0 to 5 do
      FillR(dc, MkRect(x + c * 5, y + r * 5, x + c * 5 + 4, y + r * 5 + 4), COL_HEADKEY);
  FillR(dc, MkRect(x + 5, y + 15, x + 25, y + 18), COL_HEADKEY);
end;

function StatusText(out col, fg: COLORREF): UnicodeString;
var waiting, sent: Integer; delivered: Boolean;
begin
  fg := COL_NAVY;
  if not SoundOK then
  begin
    col := COL_FAIL; fg := $FFFFFF;
    if SoundErr <> '' then Result := 'No sound' else Result := 'Opening sound...';
    Exit;
  end;
  EnterCriticalSection(Lock);
  waiting := SnWaiting(Snd);
  sent := SnSent(Snd);
  delivered := SnDelivered(Snd);
  LeaveCriticalSection(Lock);
  if (SendingN > 0) or (waiting > 0) then
  begin
    col := COL_AMBER;
    if waiting > 0 then Result := 'Sending, ' + IU(waiting) + ' waiting' else Result := 'Sending';
  end
  else if Snd.L = 0 then begin col := COL_PILL_IDLE; fg := COL_HEADKEY; Result := 'Ready'; end
  else if delivered then begin col := COL_GREEN_ON_NAVY; Result := 'Delivered'; end
  else if sent >= Snd.target then begin col := COL_GREEN_ON_NAVY; Result := 'Sent ' + #$D7 + IU(sent); end
  else begin col := COL_AMBER; Result := 'Sent ' + #$D7 + IU(sent) + ' of ' + IU(Snd.target); end;
end;

procedure DrawHeader(dc: HDC);
var col, fg: COLORREF; s: UnicodeString; w: Integer; rc: TRect;
begin
  FillR(dc, MkRect(0, 0, CW, HEAD_H), COL_NAVY);
  DrawLogo(dc, 12, 6);
  Txt(dc, APPNAME, MkRect(48, 5, 300, HEAD_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'for your phone', MkRect(150, 8, 330, HEAD_H), fSmall, COL_HEADKEY, DT_LEFT or DT_SINGLELINE);
  s := StatusText(col, fg);
  w := TextW(dc, s, fBold) + 34;
  rc := MkRect(CW - PAD - w, 4, CW - PAD, HEAD_H - 4);
  Rounded(dc, rc, col, 14);
  FillR(dc, MkRect(rc.left + 10, rc.top + 9, rc.left + 17, rc.top + 16), fg);
  Txt(dc, s, MkRect(rc.left + 24, rc.top, rc.right, rc.bottom), fBold, fg, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
end;

{ ---- the buttons at the bottom ---- }

const
  NBTN = 6;
  BTN_LABEL: array[0..NBTN - 1] of UnicodeString = ('Resend', 'New page', 'Send', 'Keys', 'Settings', 'Quit');
  BTN_KEY: array[0..NBTN - 1] of UnicodeString = ('Alt+R', 'Alt+N', 'Alt+S', 'Alt+K', 'Alt+O', 'Alt+Q');

function BtnRect(i: Integer): TRect;
var w, y: Integer;
begin
  w := (CW - 2 * PAD - (NBTN - 1) * 5) div NBTN;
  y := CH - FOOT_H + 4;
  Result := MkRect(PAD + i * (w + 5), y, PAD + i * (w + 5) + w, y + FOOT_H - 8);
end;

procedure DrawButtons(dc: HDC; const labels, keys: array of UnicodeString; n: Integer);
var i: Integer; rc: TRect;
begin
  for i := 0 to n - 1 do
  begin
    rc := BtnRect(i);
    Rounded(dc, rc, COL_LINE, 8);
    Rounded(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD, 8);
    Txt(dc, labels[i], MkRect(rc.left, rc.top + 2, rc.right, rc.top + 17), fBold, COL_NAVY, DT_CENTER or DT_SINGLELINE);
    Txt(dc, keys[i], MkRect(rc.left, rc.top + 16, rc.right, rc.bottom), fSmall, COL_MUTED, DT_CENTER or DT_SINGLELINE);
  end;
end;

procedure DrawType(dc: HDC);
var card: TRect;
begin
  card := MkRect(PAD, HEAD_H + 8, CW - PAD, CH - FOOT_H - 2);
  Rounded(dc, MkRect(card.left - 1, card.top - 1, card.right + 1, card.bottom + 1), COL_LINE, 12);
  Rounded(dc, card, COL_CARD, 12);
  if (not SoundOK) and (SoundErr <> '') then
    Txt(dc, SoundErr, MkRect(card.left + 14, card.bottom - 40, card.right - 14, card.bottom - 6), fNorm, COL_FAIL, DT_LEFT or DT_WORDBREAK)
  else if (ShowN > 0) and (Snd.L > 0) and False then ;
  DrawDoc(dc, card);
  DrawButtons(dc, BTN_LABEL, BTN_KEY, NBTN);
end;

{ ---- settings ---- }

const
  NSET = 9;
  SET_NAME: array[0..NSET - 1] of UnicodeString = ('Repeats', 'Second band for repeats', 'Volume', 'Speed', 'Band', 'Sound rate', 'Return channel', 'Test', 'About');

function SettingValue(i: Integer): UnicodeString;
begin
  case i of
    0: Result := IU(Sends) + ' times';
    1: if TwoBands then Result := 'On (' + KHz(BAND_HZ[AltBand]) + ' kHz)' else Result := 'Off';
    2: Result := IU(Volume) + ' %';
    3: Result := US(SPEED_NAME[Speed]) + ' (' + IU(SPEED_MS[Speed]) + ' ms a tone)';
    4: Result := BandName(Band);
    5: if ChipRate then Result := '43,200 (the chip''s own)' else Result := '44,100 (as Windows says)';
    6: if not ReturnOn then Result := 'Off'
       else if BkOn then Result := 'On, the phone confirms'
       else if BkErr <> '' then Result := 'On, but ' + US(BkErr)
       else Result := 'On';
    7: Result := 'Type a test sentence';
    8: Result := 'HPC Whisper ' + VERSION;
  else Result := '';
  end;
end;

function SettingHint(i: Integer): UnicodeString;
begin
  case i of
    0: Result := 'How many times every piece of text is sent. More is surer, and uses a little more sound after you stop.';
    1: Result := 'Repeats go out one kHz lower, where a weak spot at the first band does not reach them.';
    2: Result := 'Loudness of the tones. The phone can be a metre away; louder only helps in a noisy room.';
    3: Result := 'Normal is the surest; Fast shortens the wait for the text to appear.';
    4: Result := 'The phone finds the band by itself. Change it only if something else is making sound up there.';
    5: Result := 'Leave at 44,100 unless the phone struggles to read the handheld.';
    6: Result := 'The phone confirms what it has received, silently (19.0 to 20.5 kHz); then nothing is repeated needlessly. Without an answer it repeats as set above.';
    7: Result := 'Sends a sentence to the phone, to try it.';
    8: Result := 'Version, credits and how it works.';
  else Result := '';
  end;
end;

procedure ChangeSetting(i, dir: Integer);
begin
  case i of
    0: begin Sends := Sends + dir; if Sends < 2 then Sends := 2; if Sends > MAX_SENDS then Sends := MAX_SENDS; ApplySends; end;
    1: TwoBands := not TwoBands;
    2: begin Volume := Volume + 10 * dir; if Volume < 10 then Volume := 10; if Volume > 100 then Volume := 100; end;
    3: Speed := (Speed + dir + NSPEEDS) mod NSPEEDS;
    4: Band := (Band + dir + NBANDS) mod NBANDS;
    5: begin ChipRate := not ChipRate; if ChipRate then WantRate := RATE_CHIP else WantRate := RATE_WINDOWS; end;
    6: begin ReturnOn := not ReturnOn; if ReturnOn then BkStart else BkStop; end;
    7: if dir = 0 then begin TypeText(TEST_TEXT); Screen := SCR_TYPE; end;
    8: if dir = 0 then Screen := SCR_ABOUT;
  end;
  if i < 7 then SaveCfg;
end;

function SetRowRect(i: Integer): TRect;
begin
  Result := MkRect(PAD, HEAD_H + 3 + i * 15, CW - PAD, HEAD_H + 3 + i * 15 + 15);
end;

procedure DrawSettings(dc: HDC);
var i: Integer; rc: TRect;
begin
  for i := 0 to NSET - 1 do
  begin
    rc := SetRowRect(i);
    if i = SetSel then Rounded(dc, rc, COL_ROW_SEL, 8);
    Txt(dc, SET_NAME[i], MkRect(rc.left + 10, rc.top, rc.left + 230, rc.bottom), fBold, COL_INK, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
    Txt(dc, SettingValue(i), MkRect(rc.left + 240, rc.top, rc.right - 24, rc.bottom), fNorm, COL_NAVY, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
    if (i = SetSel) and (i < 7) then
    begin
      Txt(dc, '<', MkRect(rc.left + 226, rc.top, rc.left + 240, rc.bottom), fBold, COL_MUTED, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
      Txt(dc, '>', MkRect(rc.right - 20, rc.top, rc.right - 4, rc.bottom), fBold, COL_MUTED, DT_LEFT or DT_SINGLELINE or DT_VCENTER);
    end;
  end;
  rc := BtnRect(NBTN - 1);
  Rounded(dc, rc, COL_LINE, 8);
  Rounded(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD, 8);
  Txt(dc, 'Back', MkRect(rc.left, rc.top + 2, rc.right, rc.top + 17), fBold, COL_NAVY, DT_CENTER or DT_SINGLELINE);
  Txt(dc, 'Esc', MkRect(rc.left, rc.top + 16, rc.right, rc.bottom), fSmall, COL_MUTED, DT_CENTER or DT_SINGLELINE);
  Txt(dc, SettingHint(SetSel), MkRect(PAD, CH - FOOT_H + 4, BtnRect(NBTN - 1).left - 8, CH - 4), fSmall, COL_MUTED, DT_LEFT or DT_VCENTER or DT_WORDBREAK);
end;

{ ---- the list of keys ---- }

const
  NKEYS = 9;
  KEYS_A: array[0..NKEYS - 1] of UnicodeString = ('Arrows', 'Home, End', 'Bksp, Del', 'Ctrl+A C X V', 'Ctrl+Z, Ctrl+Y', 'Tab, Esc',
    'Alt+S', 'Alt+B, H, W', 'Alt+R, Alt+N');
  KEYS_B: array[0..NKEYS - 1] of UnicodeString = (
    'Move the cursor; Shift selects, Ctrl jumps a word', 'Start and end of the line; Ctrl: of the whole text',
    'Delete; Ctrl deletes a word', 'Select all, copy, cut, paste', 'Undo, redo', 'Next field (Shift: previous), Esc',
    'Press Send in the app (needs the helper)', 'Back, phone Home, Recent apps (need the helper)',
    'Send the last text again; start a new page');

procedure DrawKeys(dc: HDC);
var i: Integer; y: Integer; rc: TRect;
begin
  y := HEAD_H + 8;
  for i := 0 to NKEYS - 1 do
  begin
    Txt(dc, KEYS_A[i], MkRect(PAD + 10, y, PAD + 150, y + 16), fBold, COL_INK, DT_LEFT or DT_SINGLELINE);
    Txt(dc, KEYS_B[i], MkRect(PAD + 156, y, CW - PAD, y + 16), fNorm, COL_MUTED, DT_LEFT or DT_SINGLELINE);
    Inc(y, 15);
  end;
  rc := BtnRect(NBTN - 1);
  Rounded(dc, rc, COL_LINE, 8);
  Rounded(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD, 8);
  Txt(dc, 'Back', MkRect(rc.left, rc.top + 2, rc.right, rc.top + 17), fBold, COL_NAVY, DT_CENTER or DT_SINGLELINE);
  Txt(dc, 'Esc', MkRect(rc.left, rc.top + 16, rc.right, rc.bottom), fSmall, COL_MUTED, DT_CENTER or DT_SINGLELINE);
  Txt(dc, 'Everything else you type goes to the phone as you type it.', MkRect(PAD, CH - FOOT_H + 4, BtnRect(NBTN - 1).left - 8, CH - 4), fSmall, COL_MUTED, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
end;

procedure DrawAbout(dc: HDC);
var card, rc: TRect; y: Integer;
begin
  card := MkRect(PAD, HEAD_H + 8, CW - PAD, CH - FOOT_H - 2);
  Rounded(dc, MkRect(card.left - 1, card.top - 1, card.right + 1, card.bottom + 1), COL_LINE, 12);
  Rounded(dc, card, COL_CARD, 12);
  y := card.top + 10;
  Txt(dc, APPNAME + '  ' + VERSION, MkRect(card.left + 16, y, card.right - 16, y + 24), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Created by ' + CREATOR + '. Made on, and for, the HP Jornada 720.', MkRect(card.left + 16, y + 24, card.right - 16, y + 42), fNorm, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'What you type here appears in any app on your phone, carried by sound too high to hear. ' +
      'The phone cannot answer, so every text is sent several times, on two bands. ' +
      'Install the HPC Whisper keyboard on the phone, and keep it near the handheld.',
      MkRect(card.left + 16, y + 46, card.right - 16, y + 90), fNorm, COL_INK, DT_LEFT or DT_WORDBREAK);
  Txt(dc, 'A tip will be appreciated:  paypal.com/paypalme/byinnovodesign', MkRect(card.left + 16, y + 92, card.right - 16, y + 110), fBold, COL_KEYFG, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'github.com/kiriakoschristodoulou-netizen/hpc-whisper', MkRect(card.left + 16, y + 112, card.right - 16, y + 128), fSmall, COL_MUTED, DT_LEFT or DT_SINGLELINE);
  rc := BtnRect(NBTN - 1);
  Rounded(dc, rc, COL_LINE, 8);
  Rounded(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_CARD, 8);
  Txt(dc, 'Back', MkRect(rc.left, rc.top + 2, rc.right, rc.top + 17), fBold, COL_NAVY, DT_CENTER or DT_SINGLELINE);
  Txt(dc, 'Esc', MkRect(rc.left, rc.top + 16, rc.right, rc.bottom), fSmall, COL_MUTED, DT_CENTER or DT_SINGLELINE);
end;

procedure Draw(dc: HDC);
begin
  if not Measured then begin MeasureMono(dc); Measured := True; end;
  FillR(dc, MkRect(0, 0, CW, CH), COL_PAPER);
  SetBkMode(dc, TRANSPARENT);
  DrawHeader(dc);
  case Screen of
    SCR_TYPE: DrawType(dc);
    SCR_SETTINGS: DrawSettings(dc);
    SCR_KEYS: DrawKeys(dc);
    SCR_ABOUT: DrawAbout(dc);
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
  BkStop;
  n := 0;
  if hThread <> 0 then
    while (WaitForSingleObject(hThread, 100) <> WAIT_OBJECT_0) and (n < 30) do Inc(n);
  DestroyWindow(hMain);
end;

procedure GoScreen(s: Integer);
begin
  Screen := s;
  if s = SCR_SETTINGS then SetSel := 0;
end;

{ Alt+letter: the program's own commands (Ctrl keys all belong to the phone) }
function OnAlt(vk: Integer): Boolean;
begin
  Result := True;
  case vk of
    Ord('S'): TypeKey(K_SEND);
    Ord('B'): TypeKey(K_BACK);
    Ord('H'): TypeKey(K_HOMESCREEN);
    Ord('W'): TypeKey(K_RECENTS);
    Ord('N'): NewPage;
    Ord('R'): ResendText;
    Ord('K'): if Screen = SCR_KEYS then GoScreen(SCR_TYPE) else GoScreen(SCR_KEYS);
    Ord('O'): if Screen = SCR_SETTINGS then GoScreen(SCR_TYPE) else GoScreen(SCR_SETTINGS);
    Ord('T'): GoScreen(SCR_TYPE);
    Ord('Q'): Leave;
  else Result := False;
  end;
end;

function Mods: Integer;
begin
  Result := 0;
  if ShiftDown then Result := Result or KEY_SHIFT;
  if CtrlDown then Result := Result or KEY_CTRL;
end;

procedure OnKeyDown(vk: Integer);
begin
  if vk = VK_SHIFT_ then begin ShiftDown := True; Exit; end;
  if vk = VK_CONTROL_ then begin CtrlDown := True; Exit; end;
  case Screen of
    SCR_TYPE:
      case vk of
        VK_LEFT_: TypeKey(K_LEFT or Mods); VK_RIGHT_: TypeKey(K_RIGHT or Mods);
        VK_UP_: TypeKey(K_UP or Mods); VK_DOWN_: TypeKey(K_DOWN or Mods);
        VK_HOME_: TypeKey(K_HOME or Mods); VK_END_: TypeKey(K_END or Mods);
        VK_PRIOR_: TypeKey(K_PGUP or Mods); VK_NEXT_: TypeKey(K_PGDN or Mods);
        VK_DELETE_: TypeKey(K_DELETE or Mods);
      end;
    SCR_SETTINGS:
      case vk of
        VK_UP_: if SetSel > 0 then Dec(SetSel);
        VK_DOWN_: if SetSel < NSET - 1 then Inc(SetSel);
        VK_LEFT_: ChangeSetting(SetSel, -1);
        VK_RIGHT_: ChangeSetting(SetSel, 1);
      end;
  end;
end;

procedure OnKeyUp(vk: Integer);
begin
  if vk = VK_SHIFT_ then ShiftDown := False;
  if vk = VK_CONTROL_ then CtrlDown := False;
end;

procedure TypingChar(c: Integer);
begin
  case c of
    8: if CtrlDown then TypeDeleteWord else TypeBackspace;
    127: TypeDeleteWord;                             { Ctrl+Backspace on some keyboards }
    9: if ShiftDown then TypeKey(K_SHIFT_TAB) else TypeKey(K_TAB);
    13: TypeChar(#10);
    27: TypeKey(K_ESC);
    1: TypeKey(K_SELALL);
    3: TypeKey(K_COPY);
    22: TypeKey(K_PASTE);
    24: TypeKey(K_CUT);
    25: TypeKey(K_REDO);
    26: if ShiftDown then TypeKey(K_REDO) else TypeKey(K_UNDO);
  else
    if c >= 32 then TypeChar(WideChar(c));
  end;
end;

procedure OnChar(c: Integer);
begin
  case Screen of
    SCR_TYPE: TypingChar(c);
    SCR_SETTINGS:
      if c = 27 then GoScreen(SCR_TYPE)
      else if (c = 13) or (c = 32) then
      begin
        if SetSel >= 7 then ChangeSetting(SetSel, 0) else ChangeSetting(SetSel, 1);
      end;
    SCR_KEYS:
      if (c = 27) or (c = 13) then GoScreen(SCR_TYPE);
    SCR_ABOUT:
      if (c = 27) or (c = 13) then GoScreen(SCR_SETTINGS);
  end;
end;

procedure Command(i: Integer);
begin
  case i of
    0: ResendText;
    1: NewPage;
    2: TypeKey(K_SEND);
    3: GoScreen(SCR_KEYS);
    4: GoScreen(SCR_SETTINGS);
    5: Leave;
  end;
end;

procedure OnTap(x, y: Integer);
var i: Integer; rc: TRect;
begin
  if y >= CH - FOOT_H then
  begin
    for i := 0 to NBTN - 1 do
    begin
      rc := BtnRect(i);
      if (x >= rc.left) and (x < rc.right) then
      begin
        if Screen = SCR_TYPE then Command(i)
        else if i = NBTN - 1 then begin if Screen = SCR_ABOUT then GoScreen(SCR_SETTINGS) else GoScreen(SCR_TYPE); end;
        Exit;
      end;
    end;
    Exit;
  end;
  if Screen = SCR_SETTINGS then
    for i := 0 to NSET - 1 do
    begin
      rc := SetRowRect(i);
      if (y >= rc.top) and (y < rc.bottom) then
      begin
        SetSel := i;
        if i >= 7 then ChangeSetting(i, 0)
        else if x > CW div 2 + 60 then ChangeSetting(i, 1)
        else if x > CW div 2 - 20 then ChangeSetting(i, -1);
        Exit;
      end;
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
    WM_KEYDOWN:
      begin
        OnKeyDown(wp);
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_KEYUP: OnKeyUp(wp);
    WM_CHAR:
      begin
        OnChar(wp);
        if not Quit then InvalidateRect(wnd, nil, False);
      end;
    WM_SYSKEYDOWN:
      if OnAlt(wp) then begin if not Quit then InvalidateRect(wnd, nil, False); end
      else Result := DefWindowProcW(wnd, msg, wp, lp);
    WM_SYSCHAR: ;                                  { handled as WM_SYSKEYDOWN; no beep }
    WM_KILLFOCUS: begin ShiftDown := False; CtrlDown := False; end;
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
  fBig := MkFont(15, 700, 'Tahoma');
  fSmall := MkFont(11, 400, 'Tahoma');
  fMono := MkFont(14, 400, 'Courier New');
  ResolveAll;
  FindCfg;
  LoadCfg;
  Snd.target := Sends;
  if ChipRate then WantRate := RATE_CHIP else WantRate := RATE_WINDOWS;

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
  if ReturnOn then BkStart;
  while GetMessageW(@m, 0, 0, 0) do
  begin
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end.
