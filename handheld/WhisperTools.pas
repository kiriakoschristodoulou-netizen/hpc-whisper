program WhisperTools;
{ Whisper Tools 3.8, for Windows CE handheld PCs (made on an HP Jornada 720).

  Type here and the text goes into any app on your phone, with Tab, the
  arrows, Ctrl+C and the other keys; the phone confirms what has arrived.
  Files go both ways, and the phone's screen can be shown here (the picture
  remote). It all travels as sound: silent tones above 20 kHz for typing,
  and a soft hiss for files and the remote (docs/FORMAT3.md).

  Screens: Alt+1 Type, Alt+2 Files, Alt+3 Remote, Alt+4 Link, Alt+5
  Settings. The program's own shortcuts are on Alt, so that every Ctrl
  combination reaches the phone.

  Every function not yet seen working on the device is looked up by name at
  run time. Builds for Windows CE (ARM) and for desktop Windows (testing). }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R WhisperTools.res}
uses Windows, w3core, w3dsp, w3tx, w3rx, waudio, wtext, wfile, wscreen, wwav, wimg, winf, wmodem, wpair, wlog;

const
  VERSION = '3.8';
  CREATOR = 'Kyriakos Christodoulou';
  CLSNAME: UnicodeString = 'WhisperTools';
  APPNAME: UnicodeString = 'Whisper Tools';
  CFGNAME: UnicodeString = 'WhisperTools.cfg';
  WM_AUDIO = WM_APP + 1;
  TIMER_ID = 1; TIMER_MS = 40;

  SHOWMAX = 8000;                   { characters kept on the Type screen }
  TITLE_H = 22; STATUS_H = 18;

  SCR_TYPE = 0; SCR_FILES = 1; SCR_REMOTE = 2; SCR_LINK = 3; SCR_SETTINGS = 4; NSCR = 5; SCR_HOME = 9;
  SCR_NAME: array[0..NSCR - 1] of UnicodeString = ('Type', 'Files', 'Remote', 'Link', 'Settings');

  COL_NAVY = $36251B; COL_TEXT = $3C2D23; COL_GREY = $8C8278; COL_HI = $F6EEE8; COL_LINE = $E0D8D0;
  COL_GOOD = $3C8200; COL_FAIL = $2828BE; COL_PAPER = $FFFFFF; COL_KEY = $B07040; COL_SEL = $F0E0D0;

  MAX_SEND_FILE = 4 * 1024 * 1024;
  MAX_IN_FILE = 8 * 1024 * 1024;
  MAX_VIEW_H = 2400;

  VK_PRIOR_ = $21; VK_NEXT_ = $22; VK_END_ = $23; VK_HOME_ = $24; VK_LEFT_ = $25; VK_UP_ = $26; VK_RIGHT_ = $27; VK_DOWN_ = $28;
  VK_DELETE_ = $2E; VK_SHIFT_ = $10; VK_CONTROL_ = $11; VK_MENU_ = $12; VK_ESCAPE_ = $1B; VK_RETURN_ = $0D; VK_TAB_ = $09;

type
  TGetModuleFileNameW = function(h: HMODULE; buf: PWideChar; n: DWORD): DWORD; API;
  TSetTimer = function(wnd: HWND; id: PtrUInt; ms: UINT; fn: Pointer): PtrUInt; API;
  TKillTimer = function(wnd: HWND; id: PtrUInt): BOOL; API;
  TCreateDIBSection = function(dc: HDC; bi: Pointer; usage: UINT; bits: PPointer; section: THandle; offset: DWORD): HBITMAP; API;
  TCreateDirectoryW = function(path: PWideChar; sa: Pointer): BOOL; API;
  TDeleteFileW = function(path: PWideChar): BOOL; API;
  TPtrProc = procedure(p: Pointer); API;
  TFindData = record
    attrs: DWORD;
    created, accessed, written: array[0..1] of DWORD;
    sizeHi, sizeLo: DWORD;
    {$ifdef wince} oid: DWORD; {$else} res0, res1: DWORD; {$endif}
    name: array[0..259] of WideChar;
    {$ifndef wince} alt: array[0..13] of WideChar; {$endif}
  end;
  TFindFirstFileW = function(path: PWideChar; data: Pointer): THandle; API;
  TFindNextFileW = function(h: THandle; data: Pointer): BOOL; API;
  TFindClose = function(h: THandle): BOOL; API;

  TEntry = record
    name: UnicodeString;
    folder: Boolean;
    size: LongWord;
  end;

  TTransfer = record
    used, out, finished, ok: Boolean;
    name: UnicodeString;
    size, permille: Integer;
    state: UnicodeString;
  end;

var
  pGetModuleFileNameW: TGetModuleFileNameW;
  pSetTimer: TSetTimer; pKillTimer: TKillTimer;
  pCreateDIBSection: TCreateDIBSection; pCreateDirectoryW: TCreateDirectoryW; pDeleteFileW: TDeleteFileW;
  pFindFirstFileW: TFindFirstFileW; pFindNextFileW: TFindNextFileW; pFindClose: TFindClose;
  pGlobalMemoryStatus: TPtrProc;
  hCore: HMODULE = 0;
  Missing: UnicodeString = '';

  AppInst: HINST;
  hMain: HWND;
  CW, CH: Integer;
  ScreenDC: HDC = 0;
  fNorm, fBold, fBig, fMono, fSmall: HFONT;
  MonoW: Integer = 8; MonoH: Integer = 14;
  Measured: Boolean = False;
  Screen: Integer = SCR_HOME;
  HomeSel: Integer = 0;
  Quitting: Boolean = False;
  ShiftDown, CtrlDown: Boolean;
  ProgDir: UnicodeString = '';
  CfgPath: UnicodeString = '';

  { settings }
  Classic: Boolean = False;         { the version 2 tones, for older phone apps }
  WideSilent: Boolean = False;      { the wide silent channel (18.2-21.2 kHz): faster, but some people hear it }
  FastFiles: Boolean = True;        { files from here on the fast channel (a soft hiss); silent is slow }
  FastLevel: Integer = 1;           { 0 = 1/8, 1 = 1/4, 2 = 1/2 of full loudness }
  OnCard: Boolean = False;          { received files on the storage card }
  TypingOnFast: Boolean = False;    { the pairing check: the silent band does not reach the phone }
  FastAlways: Boolean = False;      { the pairing check: the phone's silent band does not reach here, so it answers on the fast one }
  Band: Integer = NBANDS - 1;       { classic }
  Speed: Integer = 2;
  Volume: Integer = 50;
  SetSel: Integer = 0;

  { typing }
  Ts: TTextSender;
  Show: array[0..SHOWMAX - 1] of WideChar;      { what was typed, as shown (keys as private-area characters) }
  ShowN: Integer = 0;
  ClassicSnd: TSender;
  ClassicLock: TRTLCriticalSection;

  { the link }
  FuMap: TBitMap;                    { what the phone measured on the fast channel up }
  HaveFuMap: Boolean = False;
  FdMap: TBitMap; HaveFdMap: Boolean = False;     { what we measured on the fast channel down }
  MapNo: Integer = 1;
  PhoneHeard: LongWord = 0;          { when the phone was last heard (format 3) }
  PhoneAnswers: Boolean = False;     { the phone has answered at least once }
  PhoneHello: Boolean = False;
  Answers: array[0..7] of record ch, typ, n: Integer; p: array[0..95] of Byte; end;
  AnswerN: Integer = 0;
  LastFromPhone: LongWord = 0;
  CheckState: UnicodeString = '';
  FuSpeed, FdSpeed: UnicodeString;
  HelloAt: LongWord = 0;
  FastUntil: LongWord = 0;          { the fast receiver listens until then }
  { the pairing check }
  PairState: Integer = 0;           { 0 none, 1 playing ours, 2 listening for the phone's, 3 done }
  PairDeadline: LongWord = 0;
  PairMine, PairTheirs: TPairResult; { how this handheld hears the phone; how the phone hears this handheld }
  HaveMine, HaveTheirs, PairPlayed, PairReported: Boolean;
  LastMarkSeen: LongWord = 0;
  PairNote: UnicodeString = '';
  SpeakerNote: UnicodeString = '';

  { files }
  Folder: UnicodeString = '';
  Entries: array of TEntry;
  NEntries: Integer = 0;
  FileSel: Integer = 0; FileTop: Integer = 0;
  Outgoing: array[0..15] of record s: TFileSend; t: Integer; end;
  NOut: Integer = 0;
  Incoming: record r: TFileRecv; active: Boolean; t: Integer; doneAt: LongWord; end;
  UnknownId: Integer = -1; UnknownAt: LongWord = 0;
  Trans: array[0..15] of TTransfer;
  NTrans: Integer = 0;
  NextFileId: Integer = 1;
  FileNote: UnicodeString = '';

  { viewers }
  Viewing: Integer = 0;              { 0 none, 1 picture, 2 text }
  ViewBmp: HBITMAP = 0; ViewW, ViewH, ViewY: Integer;
  ViewTitle: UnicodeString;
  ViewText: UnicodeString; ViewLines: array of Integer; ViewLine: Integer;
  Playing: Boolean = False;
  PlayData: TByteArr;
  PlayWav: TWav;
  PlayPos: Int64; PlayStep: Int64;   { linear interpolation to 44,100, in 1/65536 }
  PlayPrev, PlayCur: Integer;
  PlayBuf: array[0..8191] of SmallInt;
  PlayBufN, PlayBufI: Integer;
  PlayName: UnicodeString;

  { remote }
  Scr: TScreen;
  RemoteOn: Boolean = False;         { the phone says it shows its screen }
  RemoteMode: Integer = 1;           { 0 whole screen, 1 zoom, 2 zoom x2 }
  RemoteBmp: HBITMAP = 0; RemoteBits: PWord = nil;
  RemoteAsked: LongWord = 0;
  PenX, PenY: Integer; PenAt: LongWord; PenDown: Boolean = False;
  ScreenMsgs: Integer = 0;

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

function KHz(hz: Integer): UnicodeString;
begin
  Result := IU(hz div 1000) + '.' + IU((hz mod 1000) div 100);
end;

function SizeText(b: Int64): UnicodeString;
begin
  if b < 1024 then Result := IU(b) + ' bytes'
  else if b < 1024 * 1024 then Result := IU((b + 512) div 1024) + ' KB'
  else Result := IU(b div (1024 * 1024)) + '.' + IU((b mod (1024 * 1024)) * 10 div (1024 * 1024)) + ' MB';
end;

function TimeText(s: Integer): UnicodeString;
begin
  if s < 60 then Result := IU(s) + ' s' else Result := 'about ' + IU((s + 30) div 60) + ' min';
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
  for i := 1 to Length(face) do lf.lfFaceName[i - 1] := face[i];
  Result := CreateFontIndirectW(@lf);
end;

function Lower(c: WideChar): WideChar;
begin
  if (c >= 'A') and (c <= 'Z') then Result := WideChar(Ord(c) + 32) else Result := c;
end;

function EndsCI(const s, tail: UnicodeString): Boolean;
var i, o: Integer;
begin
  Result := False;
  if Length(s) < Length(tail) then Exit;
  o := Length(s) - Length(tail);
  for i := 1 to Length(tail) do if Lower(s[o + i]) <> Lower(tail[i]) then Exit;
  Result := True;
end;

function SameW(const a, b: UnicodeString): Boolean;
var i: Integer;
begin
  Result := False;
  if Length(a) <> Length(b) then Exit;
  for i := 1 to Length(a) do if a[i] <> b[i] then Exit;
  Result := True;
end;

function LessCI(const a, b: UnicodeString): Boolean;
var i, n: Integer; x, y: WideChar;
begin
  n := Length(a); if Length(b) < n then n := Length(b);
  for i := 1 to n do
  begin
    x := Lower(a[i]); y := Lower(b[i]);
    if x <> y then begin Result := x < y; Exit; end;
  end;
  Result := Length(a) < Length(b);
end;

function ToUtf8(const s: UnicodeString): TByteArr;
var i, n, u: Integer;
begin
  SetLength(Result, Length(s) * 3);
  n := 0;
  for i := 1 to Length(s) do
  begin
    u := Ord(s[i]);
    if u < $80 then begin Result[n] := u; Inc(n); end
    else if u < $800 then begin Result[n] := $C0 or (u shr 6); Result[n + 1] := $80 or (u and $3F); Inc(n, 2); end
    else begin Result[n] := $E0 or (u shr 12); Result[n + 1] := $80 or ((u shr 6) and $3F); Result[n + 2] := $80 or (u and $3F); Inc(n, 3); end;
  end;
  SetLength(Result, n);
end;

function FromUtf8(p: PByte; n: Integer): UnicodeString;
var i, u, k: Integer;
begin
  SetLength(Result, n);
  k := 0; i := 0;
  while i < n do
  begin
    u := p[i];
    if (u >= $E0) and (i + 2 < n) then begin u := ((u and 15) shl 12) or ((p[i + 1] and 63) shl 6) or (p[i + 2] and 63); Inc(i, 3); end
    else if (u >= $C0) and (i + 1 < n) then begin u := ((u and 31) shl 6) or (p[i + 1] and 63); Inc(i, 2); end
    else Inc(i);
    Inc(k); Result[k] := WideChar(u);
  end;
  SetLength(Result, k);
end;

{ a name the file system takes, from what the other side sent }
function SafeName(const s: UnicodeString): UnicodeString;
var i: Integer; c: WideChar;
begin
  Result := '';
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if (c = '\') or (c = '/') or (c = ':') or (c = '*') or (c = '?') or (c = '"') or (c = '<') or (c = '>') or (c = '|') or (Ord(c) < 32) then c := '_';
    Result := Result + c;
    if Length(Result) >= 100 then Break;
  end;
  while (Length(Result) > 0) and ((Result[1] = '.') or (Result[1] = ' ')) do Delete(Result, 1, 1);
  if Length(Result) = 0 then Result := 'file';
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
    if Missing <> '' then Missing := Missing + ', ';
    Missing := Missing + US(fn);
  end;
end;

procedure ResolveAll;
const K = 'kernel32.dll'; U = 'user32.dll'; G = 'gdi32.dll';
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', K));
  pSetTimer := TSetTimer(Find('SetTimer', U));
  pKillTimer := TKillTimer(Find('KillTimer', U));
  pCreateDIBSection := TCreateDIBSection(Find('CreateDIBSection', G));
  pCreateDirectoryW := TCreateDirectoryW(Find('CreateDirectoryW', K));
  pDeleteFileW := TDeleteFileW(Find('DeleteFileW', K));
  pFindFirstFileW := TFindFirstFileW(Find('FindFirstFileW', K));
  pFindNextFileW := TFindNextFileW(Find('FindNextFileW', K));
  pFindClose := TFindClose(Find('FindClose', K));
  pGlobalMemoryStatus := TPtrProc(Find('GlobalMemoryStatus', K));
  AudioResolve;
end;

function MemoryFor(bytes: Int64): Boolean;
type TMemStat = record len, load: DWORD; totalPhys, availPhys, totalPage, availPage, totalVirt, availVirt: PtrUInt; end;
var m: TMemStat;
begin
  Result := True;
  if not Assigned(pGlobalMemoryStatus) then Exit;
  FillChar(m, SizeOf(m), 0);
  m.len := SizeOf(m);
  pGlobalMemoryStatus(@m);
  if m.availPhys > 0 then Result := Int64(m.availPhys) > bytes + 1024 * 1024;
end;

{ ---------- settings: a few bytes next to the program ---------- }

procedure FindDirs;
var buf: array[0..259] of WideChar; n, i, cut: Integer;
begin
  ProgDir := '';
  if Assigned(pGetModuleFileNameW) then
  begin
    n := pGetModuleFileNameW(0, @buf[0], 259);
    cut := 0;
    for i := 0 to n - 1 do if buf[i] = '\' then cut := i + 1;
    SetLength(ProgDir, cut);
    for i := 0 to cut - 1 do ProgDir[i + 1] := buf[i];
  end;
  CfgPath := ProgDir + CFGNAME;
end;

{ the loudness of the silent channel (peak, of 32767): chosen by Pair, from what the phone heard (LevelSource 1),
  or a moderate one until then. The speaker distorts when driven hard, and its amplifier may give up. }
var SilentPeak: Integer = 14500; LevelSource: Integer = 0;

procedure LoadCfg;
var h: THandle; b: array[0..15] of Byte; got: DWORD; r: LongWord;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 4, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 4) and (b[0] = $57) then
  begin
    if b[1] < NBANDS then Band := b[1];
    if b[2] < NSPEEDS then Speed := b[2];
    if (b[3] >= 10) and (b[3] <= 100) then Volume := b[3];
    { version 3 adds a second part }
    got := 0;
    if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 6, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 6) and (b[0] = $33) then
    begin
      Classic := b[1] <> 0; WideSilent := b[2] <> 0; FastFiles := b[3] <> 0;
      if b[4] <= 2 then FastLevel := b[4];
      OnCard := b[5] <> 0;
      got := 0;
      if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 3, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 3) and (b[0] = $34) then
      begin
        TypingOnFast := b[1] <> 0; FastAlways := b[2] <> 0;
        got := 0;
        if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 8, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 8) and (b[0] = $36) then
        begin
          r := b[1] or (LongWord(b[2]) shl 8) or (LongWord(b[3]) shl 16) or (LongWord(b[4]) shl 24);
          { 2 = calibrated by Pair, 3 = measured (since 3.8); 1 = measured by an older version, whose
            measurement could be thrown off by a busy processor: not used }
          if (r > 0) and (b[5] in [2, 3]) and (Int64(r) * 20 >= Int64(IN_RATE) * 100 * 19) and (Int64(r) * 20 <= Int64(IN_RATE) * 100 * 21) then
          begin InRate100 := r; if b[5] = 3 then RateSource := 1 else RateSource := 2; end;
          if (b[6] >= 20) and (b[6] <= 230) and (b[7] = 1) then begin SilentPeak := b[6] * 128; LevelSource := 1; end;
          got := 0;
          if ReadFile(h, {$ifdef wince}@b{$else}b{$endif}, 2, {$ifdef wince}@got{$else}got{$endif}, nil) and (got = 2) and (b[0] = $38) then
            SpeakerNative := b[1] = 0;
        end;
      end;
    end;
  end;
  CloseHandle(h);
end;

procedure SaveCfg;
var h: THandle; b: array[0..22] of Byte; got: DWORD; r: LongWord;
begin
  h := CreateFileW(PWideChar(CfgPath), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  b[0] := $57; b[1] := Band; b[2] := Speed; b[3] := Volume;
  b[4] := $33; b[5] := Ord(Classic); b[6] := Ord(WideSilent); b[7] := Ord(FastFiles); b[8] := FastLevel; b[9] := Ord(OnCard);
  b[10] := $34; b[11] := Ord(TypingOnFast); b[12] := Ord(FastAlways);
  { this handheld's own measurements: the microphone's rate (x 100) and the silent loudness }
  if RateSource > 0 then r := LongWord(InRate100) else r := 0;
  b[13] := $36; b[14] := r and 255; b[15] := (r shr 8) and 255; b[16] := (r shr 16) and 255; b[17] := r shr 24;
  if RateSource = 1 then b[18] := 3 else b[18] := RateSource;
  b[19] := SilentPeak div 128; b[20] := LevelSource;
  b[21] := $38; b[22] := Ord(not SpeakerNative);
  got := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, 23, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
end;

function InFolder: UnicodeString;
begin
  {$ifdef wince}
  if OnCard then Result := '\Storage Card\Whisper Tools\' else Result := '\My Documents\Whisper Tools\';
  {$else}
  Result := ProgDir + 'Whisper Tools\';
  {$endif}
end;

procedure MakeInFolder;
var f: UnicodeString;
begin
  if not Assigned(pCreateDirectoryW) then Exit;
  f := InFolder;
  pCreateDirectoryW(PWideChar(Copy(f, 1, Length(f) - 1)), nil);
end;

{ ---------- files on the handheld ---------- }

function ReadWhole(const path: UnicodeString; maxSize: Integer; var d: TByteArr): Boolean;
var f: File; n: Int64;
begin
  Result := False;
  SetLength(d, 0);
  {$I-}
  Assign(f, path); FileMode := 0; Reset(f, 1);
  if IOResult <> 0 then Exit;
  n := FileSize(f);
  if (n < 0) or (n > maxSize) or not MemoryFor(n) then begin Close(f); IOResult; Exit; end;
  SetLength(d, n);
  if n > 0 then BlockRead(f, d[0], n);
  Close(f);
  Result := IOResult = 0;
  {$I+}
end;

function WriteWhole(const path: UnicodeString; p: PByte; n: Integer): Boolean;
var f: File;
begin
  {$I-}
  Assign(f, path); Rewrite(f, 1);
  if IOResult <> 0 then begin Result := False; Exit; end;
  if n > 0 then BlockWrite(f, p^, n);
  Close(f);
  Result := IOResult = 0;
  {$I+}
end;

function Exists(const path: UnicodeString): Boolean;
var f: File;
begin
  {$I-}
  Assign(f, path); FileMode := 0; Reset(f, 1);
  Result := IOResult = 0;
  if Result then Close(f);
  IOResult;
  {$I+}
end;

{ "name.jpg", or "name (2).jpg" when that exists }
function FreeName(const folder, name: UnicodeString): UnicodeString;
var dot, i, k: Integer; base, ext: UnicodeString;
begin
  Result := name;
  if not Exists(folder + name) then Exit;
  dot := 0;
  for i := 1 to Length(name) do if name[i] = '.' then dot := i;
  if dot > 1 then begin base := Copy(name, 1, dot - 1); ext := Copy(name, dot, 99); end
  else begin base := name; ext := ''; end;
  for k := 2 to 99 do
  begin
    Result := base + ' (' + IU(k) + ')' + ext;
    if not Exists(folder + Result) then Exit;
  end;
end;

procedure ListFolder;
var h: THandle; fd: TFindData; nm: UnicodeString; i, j: Integer; t: TEntry;
begin
  NEntries := 0;
  SetLength(Entries, 64);
  if Length(Folder) > 1 then
  begin
    Entries[0].name := '..'; Entries[0].folder := True; Entries[0].size := 0; NEntries := 1;
  end;
  if Assigned(pFindFirstFileW) and Assigned(pFindNextFileW) and Assigned(pFindClose) then
  begin
    FillChar(fd, SizeOf(fd), 0);
    h := pFindFirstFileW(PWideChar(Folder + '*'), @fd);
    if h <> INVALID_HANDLE_VALUE then
    begin
      repeat
        nm := PWideChar(@fd.name[0]);
        if not SameW(nm, '.') and not SameW(nm, '..') then
        begin
          if NEntries >= Length(Entries) then SetLength(Entries, NEntries * 2);
          Entries[NEntries].name := nm;
          Entries[NEntries].folder := (fd.attrs and $10) <> 0;
          Entries[NEntries].size := fd.sizeLo;
          Inc(NEntries);
        end;
        FillChar(fd, SizeOf(fd), 0);
      until (not pFindNextFileW(h, @fd)) or (NEntries > 2000);
      pFindClose(h);
    end;
  end;
  { folders first, then by name }
  for i := 1 to NEntries - 1 do
  begin
    t := Entries[i]; j := i - 1;
    while (j >= 0) and (not SameW(Entries[j].name, '..')) and
          ((t.folder and not Entries[j].folder) or ((t.folder = Entries[j].folder) and LessCI(t.name, Entries[j].name))) do
    begin
      Entries[j + 1] := Entries[j]; Dec(j);
    end;
    Entries[j + 1] := t;
  end;
  if FileSel >= NEntries then FileSel := NEntries - 1;
  if FileSel < 0 then FileSel := 0;
end;

procedure OpenFolder(const f: UnicodeString);
begin
  Folder := f;
  FileSel := 0; FileTop := 0;
  ListFolder;
end;

{ ---------- sending ---------- }

{ the channel for typing and answers: silent, or the fast one when the pairing check found the silent band
  too weak for this pair }
function SilentCh: Integer;
begin
  if TypingOnFast then Result := CH_FU
  else if WideSilent then Result := CH_SUW else Result := CH_SU;
end;

function FastLevelQ15: Integer;
begin
  case FastLevel of 0: Result := 4096; 2: Result := 16384; else Result := 8192; end;
end;

{ makes a frame and queues it; False when the queue is full }
function SendMsg(ch, typ: Integer; const p: array of Byte; n: Integer): Boolean;
var m: TBitMap; x: TSamples; lvl: Integer;
begin
  if ch = CH_FU then
  begin
    if HaveFuMap then m := FuMap else StdMap(ch, m);
    lvl := FastLevelQ15;
  end
  else begin StdMap(ch, m); lvl := SilentPeak; end;
  if typ = T_TRAIN then x := MakeTrain(ch, lvl)
  else x := MakeFrame(ch, m, typ, p, n, lvl);
  Result := AudioSend(x);
  if Result then Log('send ' + LChan(ch) + ' ' + LDescribe(typ, p, n) + ', loudness ' + LI(lvl) + ', ' + LI(Int64(Length(x)) * 1000 div TxRate) + ' ms at ' + LI(TxRate) + '/s')
  else Log('send ' + LChan(ch) + ' ' + LType(typ) + ': NOT SENT, the queue is full');
end;

{ an answer to the phone (MAP, FILE_NEED, HELLO): sent when the channel is free }
procedure Answer(typ: Integer; const p: array of Byte; n: Integer);
var i: Integer;
begin
  if AnswerN > High(Answers) then begin Log('answer ' + LType(typ) + ' dropped: too many answers waiting'); Exit; end;
  Log('answer ' + LType(typ) + ' waits for its turn (' + LI(AnswerN + 1) + ' waiting)');
  Answers[AnswerN].ch := SilentCh; Answers[AnswerN].typ := typ; Answers[AnswerN].n := n;
  for i := 0 to n - 1 do Answers[AnswerN].p[i] := p[i];
  Inc(AnswerN);
end;

procedure SayHello(reply: Boolean);
var p: array[0..3] of Byte;
begin
  p[0] := 3;
  p[1] := (1 shl CH_SD) or (1 shl CH_FD);                              { what this handheld hears }
  p[2] := (1 shl CH_SU) or (1 shl CH_SUW) or (1 shl CH_FU);            { and plays }
  p[3] := Ord(reply);
  Answer(T_HELLO, p, 4);
end;

{ ---------- the record of transfers, for the Files screen ---------- }

function NewTransfer(isOut: Boolean; const name: UnicodeString; size: Integer): Integer;
var i: Integer;
begin
  if NTrans > High(Trans) then
  begin
    for i := 0 to NTrans - 2 do Trans[i] := Trans[i + 1];
    Dec(NTrans);
    for i := 0 to NOut - 1 do Dec(Outgoing[i].t);
    Dec(Incoming.t);
  end;
  Result := NTrans; Inc(NTrans);
  Trans[Result].used := True; Trans[Result].out := isOut; Trans[Result].finished := False; Trans[Result].ok := False;
  Trans[Result].name := name; Trans[Result].size := size; Trans[Result].permille := 0;
  Trans[Result].state := 'Waiting';
end;

procedure SetTrans(t: Integer; const st: UnicodeString; permille: Integer; fin, ok: Boolean);
begin
  if (t < 0) or (t >= NTrans) then Exit;
  Trans[t].state := st; Trans[t].permille := permille; Trans[t].finished := fin; Trans[t].ok := ok;
end;

{ ---------- the typing document as shown ---------- }

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
  Result := (Ord(c) >= KEY_BASE) and (Ord(c) < KEY_BASE + $100);
end;

procedure TypeChar(c: WideChar);
begin
  ShowAdd(c);
  if Classic then
  begin
    EnterCriticalSection(ClassicLock);
    if c = #9 then SnType(ClassicSnd, ' ', GetTickCount) else SnType(ClassicSnd, c, GetTickCount);
    LeaveCriticalSection(ClassicLock);
  end
  else TsType(Ts, c, GetTickCount);
end;

procedure TypeKey(code: Integer);
begin
  if Classic then Exit;                              { the older phone apps know only text }
  ShowAdd(WideChar(KEY_BASE + code));
  TsKey(Ts, code, GetTickCount);
end;

procedure TypeBackspace;
begin
  if Classic then
  begin
    if ShowN > 0 then Dec(ShowN);
    EnterCriticalSection(ClassicLock);
    SnBackspace(ClassicSnd, GetTickCount);
    LeaveCriticalSection(ClassicLock);
    Exit;
  end;
  { as the phone sees it: a character typed since the last key goes; otherwise the phone deletes }
  if Ts.L > Ts.keyEnd then
  begin
    if (ShowN > 0) and not IsKeyChar(Show[ShowN - 1]) then Dec(ShowN);
    TsBackspace(Ts, GetTickCount);
  end
  else TypeKey(K_BACKSPACE);
end;

procedure NewPage;
begin
  ShowN := 0;
  TsNewDoc(Ts);
  EnterCriticalSection(ClassicLock);
  SnNewDoc(ClassicSnd);
  LeaveCriticalSection(ClassicLock);
end;

{ the next frame of classic tones, as sound, when there is one }
function ClassicSamples(var x: TSamples): Boolean;
var f: TFrame; tm: TToneMaker; buf: array[0..4409] of SmallInt; n, i: Integer; more: Boolean;
begin
  Result := False;
  if not Classic then Exit;
  EnterCriticalSection(ClassicLock);
  Result := SnNext(ClassicSnd, GetTickCount, f);
  LeaveCriticalSection(ClassicLock);
  if not Result then Exit;
  TmInit(tm, TxRate);
  tm.band := Band; tm.speed := Speed; tm.volume := Volume;
  TmStart(tm, f);
  SetLength(x, 0); n := 0;
  repeat
    for i := 0 to High(buf) do buf[i] := 0;
    more := TmFill(tm, buf, Length(buf));
    SetLength(x, n + Length(buf));
    for i := 0 to High(buf) do x[n + i] := buf[i];
    Inc(n, Length(buf));
  until (not more) or (n > TxRate * 5);
end;

{ ---------- files: sending ---------- }

function KindOf(const name: UnicodeString): Integer;
begin
  if EndsCI(name, '.jpg') or EndsCI(name, '.jpeg') or EndsCI(name, '.png') or EndsCI(name, '.bmp') or EndsCI(name, '.gif') then Result := KIND_PICTURE
  else if EndsCI(name, '.wav') then Result := KIND_SOUND
  else if EndsCI(name, '.txt') or EndsCI(name, '.htm') or EndsCI(name, '.html') or EndsCI(name, '.csv') then Result := KIND_TEXT
  else if EndsCI(name, '.pwd') or EndsCI(name, '.doc') or EndsCI(name, '.pxl') or EndsCI(name, '.epub') or EndsCI(name, '.pdf') then Result := KIND_DOCUMENT
  else Result := KIND_OTHER;
end;

function Compressed(const name: UnicodeString): Boolean;
begin
  Result := EndsCI(name, '.jpg') or EndsCI(name, '.jpeg') or EndsCI(name, '.png') or EndsCI(name, '.gif') or EndsCI(name, '.zip')
    or EndsCI(name, '.epub') or EndsCI(name, '.mp3') or EndsCI(name, '.cab');
end;

{ compresses with zlib when that helps: the phone unpacks it on arrival }
function Deflated(const d: TByteArr; var z: TByteArr): Boolean; forward;

procedure SendFile(const path, name: UnicodeString);
var d, z: TByteArr; kind: Integer;
begin
  if NOut > High(Outgoing) then begin FileNote := 'Too many files waiting.'; Exit; end;
  if not ReadWhole(path, MAX_SEND_FILE, d) then begin FileNote := name + ' cannot be read (or is over 4 MB).'; Exit; end;
  kind := KindOf(name);
  if (not Compressed(name)) and (Length(d) > 64) and Deflated(d, z) and (Length(z) < Length(d) * 9 div 10) then
  begin
    d := z; kind := kind or KIND_ZLIB;
  end;
  FsInit(Outgoing[NOut].s, NextFileId, ToUtf8(name), kind, d);
  NextFileId := (NextFileId + 1) and $FFFF;
  Outgoing[NOut].t := NewTransfer(True, name, Length(d));
  Inc(NOut);
  FileNote := '';
end;

procedure CancelSending;
var p: array[0..1] of Byte; i: Integer;
begin
  if NOut = 0 then Exit;
  p[0] := Outgoing[0].s.id shr 8; p[1] := Outgoing[0].s.id and 255;
  if FastFiles then SendMsg(CH_FU, T_FILE_CANCEL, p, 2) else SendMsg(SilentCh, T_FILE_CANCEL, p, 2);
  SetTrans(Outgoing[0].t, 'Cancelled', Trans[Outgoing[0].t].permille, True, False);
  for i := 0 to NOut - 2 do Outgoing[i] := Outgoing[i + 1];
  Dec(NOut);
end;

{ ---------- files: receiving ---------- }

procedure FinishIncoming;
var name, path: UnicodeString; d: PByte; n: LongWord; ok: Boolean;
begin
  Incoming.active := False;
  FilePieceAt := 0;
  Incoming.doneAt := GetTickCount;
  name := SafeName(FromUtf8(@Incoming.r.nameUtf8[0], Length(Incoming.r.nameUtf8)));
  MakeInFolder;
  name := FreeName(InFolder, name);
  path := InFolder + name;
  if (Incoming.r.kind and KIND_ZLIB) <> 0 then
  begin
    d := InflateAll(@Incoming.r.data[0], Length(Incoming.r.data), MAX_IN_FILE, n);
    if d = nil then begin SetTrans(Incoming.t, 'Arrived damaged', 1000, True, False); Log('file: all packets here, but it would not unpack'); Exit; end;
    ok := WriteWhole(path, d, n);
    FreeMem(d);
  end
  else if Length(Incoming.r.data) > 0 then ok := WriteWhole(path, @Incoming.r.data[0], Length(Incoming.r.data))
  else ok := WriteWhole(path, nil, 0);
  SetLength(Incoming.r.data, 0);
  Trans[Incoming.t].name := name;
  if ok then Log('file: complete and saved') else Log('file: complete, but it could not be saved');
  if ok then SetTrans(Incoming.t, 'Saved in ' + InFolder, 1000, True, True)
  else SetTrans(Incoming.t, 'Could not be saved (is there room?)', 1000, True, False);
  if (Screen = SCR_FILES) and SameW(Folder, InFolder) then ListFolder;
end;

procedure OnOffer(const p: array of Byte; n: Integer);
var id: Integer; nm: UnicodeString;
begin
  FastUntil := GetTickCount + 30000;               { the packets follow on the fast channel }
  id := FrIdOf(p, n);
  if (Incoming.r.id = id) and (Incoming.active or (GetTickCount - Incoming.doneAt < 120000)) and (Length(Incoming.r.got) > 0) then
  begin
    Log('file: the offer again (' + LI(Incoming.r.count) + ' of ' + LI(Incoming.r.packets) + ' packets here)');
    FrOffer(Incoming.r, GetTickCount);
    Exit;
  end;
  if Incoming.active then
  begin
    { a new file while one is still coming: the old one is given up }
    SetTrans(Incoming.t, 'Interrupted', Trans[Incoming.t].permille, True, False);
    Incoming.active := False;
  end;
  if (n >= 6) and not MemoryFor((LongInt(p[2]) shl 24) or (p[3] shl 16) or (p[4] shl 8) or p[5]) then
  begin
    FileNote := 'A file from the phone is too large for the free memory.';
    Log('file: offer refused, not enough free memory');
    Exit;
  end;
  if not FrFromOffer(Incoming.r, p, n, GetTickCount, MAX_IN_FILE) then begin Log('file: offer not understood or too large'); Exit; end;
  Log('file: receiving a new one, ' + LI(Incoming.r.packets) + ' packets');
  FilePieces := 0; FileLost := 0;
  Incoming.active := True;
  nm := SafeName(FromUtf8(@Incoming.r.nameUtf8[0], Length(Incoming.r.nameUtf8)));
  Incoming.t := NewTransfer(False, nm, Incoming.r.size);
  SetTrans(Incoming.t, 'Receiving', 0, False, False);
  if UnknownId = id then UnknownId := -1;
end;

procedure OnData(const p: array of Byte; n: Integer);
var id, before: Integer;
begin
  id := FrIdOf(p, n);
  if (Length(Incoming.r.got) = 0) or (Incoming.r.id <> id) then
  begin
    Log('file: a packet of a file not offered (id ' + LI(id) + '): will ask for the offer');
    UnknownId := id; UnknownAt := GetTickCount;
    Exit;
  end;
  before := Incoming.r.count;
  FrData(Incoming.r, p, n, GetTickCount);
  if Incoming.r.count <> before then Log('file: packet kept, ' + LI(Incoming.r.count) + ' of ' + LI(Incoming.r.packets))
  else Log('file: packet not kept (a repeat, or the wrong size)');
  if Incoming.active and (Incoming.r.count <> before) then
    SetTrans(Incoming.t, 'Receiving', Incoming.r.count * 1000 div Incoming.r.packets, False, False);
end;

{ ---------- the link check ---------- }

procedure CheckLink;
var p: array[0..0] of Byte;
begin
  FastUntil := GetTickCount + 20000;
  SayHello(False);
  { the fast channel up: TRAIN, the phone answers with a map; the fast channel down: the phone sends TRAIN when asked }
  SendMsg(CH_FU, T_TRAIN, p, 0);
  p[0] := CH_FD;
  Answer(T_CHECK, p, 1);
  CheckState := 'Checking: a soft hiss from each side, for a few seconds...';
  FuSpeed := ''; FdSpeed := '';
end;

function SpeedText(const m: TBitMap): UnicodeString;
var bits, k: Integer;
begin
  bits := MapBits(m);
  k := bits * MRATE div NSYM * 85 div 100;                { bit/s after error protection, about }
  Result := 'about ' + IU(k div 1000) + '.' + IU((k mod 1000) div 100) + ' kbit/s (' + IU(bits) + ' bits a symbol)';
end;

procedure RemoteView; forward;

{ ---------- what the phone said ---------- }

procedure OnTrain(const t: TTrainResult);
var m: TBitMap; b: array[0..63] of Byte; n: Integer;
begin
  if t.ch <> CH_FD then Exit;
  MapNo := MapNo mod 31 + 1;
  MapFromSnr(CH_FD, MapNo, t.snr10, m);
  if MapBits(m) >= 8 then
  begin
    FdMap := m; HaveFdMap := True;
    AudioAddMap(m);
    n := MapToMsg(m, b);
    Answer(T_MAP, b, n);
    FdSpeed := SpeedText(m);
  end
  else FdSpeed := 'too weak: raise the phone''s media volume, or bring it closer';
end;

procedure OnPhone(const g: TGotMsg);
var m: TBitMap; typ, n: Integer;
begin
  typ := g.msg.typ; n := g.msg.len;
  PhoneHeard := GetTickCount;
  PhoneAnswers := True;
  case typ of
    T_TEXT_ACK: begin TsAck(Ts, g.msg.data, n, GetTickCount); Log('text: ' + LI(TsUnconfirmed(Ts)) + ' characters not yet confirmed'); end;
    T_MAP:
      if MapFromMsg(g.msg.data, n, m) and (m.ch = CH_FU) then
      begin
        FuMap := m; HaveFuMap := True;
        FuSpeed := SpeedText(m);
      end;
    T_HELLO:
      begin
        PhoneHello := True;
        if (n >= 4) and ((g.msg.data[3] and 1) = 0) then
        begin
          HaveFuMap := False;                  { a phone that has just started knows no maps }
          if GetTickCount - HelloAt > 3000 then begin HelloAt := GetTickCount; SayHello(True); end;
        end;
      end;
    T_CHECK: if (n >= 1) and (g.msg.data[0] = CH_FU) then begin FastUntil := GetTickCount + 20000; SendMsg(CH_FU, T_TRAIN, g.msg.data, 0); end;
    T_TRAIN: ;
    PAIR_REPORT:
      if PairReportRead(g.msg.data, n, PairTheirs) then
      begin
        HaveTheirs := True;
        { the phone tells how it hears this handheld: typing stays silent only if the silent band gets through }
        TypingOnFast := (PairBand10(PairTheirs, 20200, 21200) < 150) and (PairBand10(PairTheirs, 1000, 12000) >= 150);
        { and which loudness of the ladder came through cleanest }
        if (PairTheirs.ladder >= 0) and (PairTheirs.ladder <= High(PAIR_LADDER)) then
        begin SilentPeak := PAIR_LADDER[PairTheirs.ladder]; LevelSource := 1; end;
        SaveCfg;
        Log('pair: the phone''s report: typing on the fast channel ' + LI(Ord(TypingOnFast)) + ', silent loudness ' + LI(SilentPeak));
      end;
    T_FILE_OFFER: OnOffer(g.msg.data, n);
    T_FILE_DATA: OnData(g.msg.data, n);
    T_FILE_NEED: if NOut > 0 then FsNeed(Outgoing[0].s, g.msg.data, n);
    T_FILE_CANCEL:
      if Incoming.active and (FrIdOf(g.msg.data, n) = Incoming.r.id) then
      begin
        Incoming.active := False;
        SetTrans(Incoming.t, 'Cancelled on the phone', Trans[Incoming.t].permille, True, False);
      end;
    T_SCREEN:
      if ScrApply(Scr, g.msg.data, n) then
      begin
        Inc(ScreenMsgs);
        RemoteOn := True;
        if Screen = SCR_REMOTE then InvalidateRect(hMain, nil, False);
      end;
    T_INPUT:
      if n >= 1 then
      begin
        if g.msg.data[0] = 6 then begin RemoteOn := True; RemoteView; end
        else if g.msg.data[0] = 7 then RemoteOn := False;
      end;
  end;
end;

function Deflated(const d: TByteArr; var z: TByteArr): Boolean;
var n: LongWord;
begin
  Result := False;
  if not MemoryFor(Length(d) + 1024) then Exit;
  SetLength(z, Length(d) + Length(d) div 8 + 64);
  n := DeflateBuf(@d[0], Length(d), @z[0], Length(z));
  if n = 0 then begin SetLength(z, 0); Exit; end;
  SetLength(z, n);
  Result := True;
end;

{ ---------- the sound player (WAV files) ---------- }

procedure StopPlaying;
begin
  Playing := False;
  SetLength(PlayData, 0);
end;

function PlayNext: Integer;            { the next sample of the file, or -100000 at the end }
begin
  if PlayBufI >= PlayBufN then
  begin
    PlayBufN := WavRead(PlayWav, PlayBuf, Length(PlayBuf));
    PlayBufI := 0;
    if PlayBufN = 0 then begin Result := -100000; Exit; end;
  end;
  Result := PlayBuf[PlayBufI]; Inc(PlayBufI);
end;

procedure StartPlaying(const path, name: UnicodeString);
var v: Integer;
begin
  StopPlaying;
  if not ReadWhole(path, MAX_IN_FILE, PlayData) or (Length(PlayData) < 44) then begin FileNote := name + ' cannot be read.'; Exit; end;
  if not WavOpen(PlayWav, @PlayData[0], Length(PlayData)) then
  begin
    FileNote := name + ': this kind of WAV cannot be played here (PCM and IMA ADPCM can).';
    SetLength(PlayData, 0); Exit;
  end;
  PlayStep := Int64(PlayWav.rate) * 65536 div TxRate;
  PlayPos := 0; PlayBufN := 0; PlayBufI := 0;
  v := PlayNext; if v = -100000 then v := 0; PlayPrev := v;
  v := PlayNext; if v = -100000 then v := 0; PlayCur := v;
  PlayName := name;
  Playing := True;
  FileNote := 'Playing ' + name + ' (' + TimeText(WavSeconds(PlayWav)) + '). Esc stops.';
end;

{ keeps a little sound queued while playing }
procedure FeedPlayer;
var x: TSamples; i, v: Integer; ended: Boolean;
begin
  if not Playing then Exit;
  while Playing and (AudioQueued < 3) do
  begin
    SetLength(x, 4410);
    ended := False;
    for i := 0 to 4409 do
    begin
      if ended then begin x[i] := 0; Continue; end;
      v := PlayPrev + Integer((Int64(PlayCur - PlayPrev) * PlayPos) div 65536);
      x[i] := v div 2;                               { half loudness: the speaker is close to your ear }
      PlayPos := PlayPos + PlayStep;
      while PlayPos >= 65536 do
      begin
        PlayPos := PlayPos - 65536;
        PlayPrev := PlayCur;
        v := PlayNext;
        if v = -100000 then begin ended := True; Break; end;
        PlayCur := v;
      end;
    end;
    AudioSend(x);
    if ended then begin StopPlaying; FileNote := 'Played ' + PlayName + '.'; end;
  end;
end;

{ ---------- viewers ---------- }

function MakeBitmap(pix: PWord; w, h: Integer): HBITMAP;
type TBI = record hdr: BITMAPINFOHEADER; mask: array[0..2] of DWORD; end;
var bi: TBI; bits: Pointer; y, stride: Integer;
begin
  Result := 0;
  if not Assigned(pCreateDIBSection) then Exit;
  FillChar(bi, SizeOf(bi), 0);
  bi.hdr.biSize := SizeOf(BITMAPINFOHEADER);
  bi.hdr.biWidth := w; bi.hdr.biHeight := h;
  bi.hdr.biPlanes := 1; bi.hdr.biBitCount := 16;
  bi.hdr.biCompression := BI_BITFIELDS;
  bi.mask[0] := $F800; bi.mask[1] := $07E0; bi.mask[2] := $001F;
  bits := nil;
  Result := pCreateDIBSection(ScreenDC, @bi, DIB_RGB_COLORS, @bits, 0, 0);
  if (Result = 0) or (bits = nil) then begin Result := 0; Exit; end;
  stride := ((w * 2 + 3) div 4) * 4;
  if pix <> nil then
    for y := 0 to h - 1 do Move((pix + y * w)^, (PByte(bits) + (h - 1 - y) * stride)^, w * 2);
end;

procedure CloseViewer;
begin
  if ViewBmp <> 0 then DeleteObject(ViewBmp);
  ViewBmp := 0; Viewing := 0; ViewText := ''; SetLength(ViewLines, 0);
end;

function ContentH: Integer;
begin
  Result := CH - TITLE_H - STATUS_H;
end;

procedure ViewPicture(const path, name: UnicodeString);
var d: TByteArr; w, h, tw, th: Integer; pix: PWord;
begin
  CloseViewer;
  if not ReadWhole(path, MAX_IN_FILE, d) then begin FileNote := name + ' cannot be read.'; Exit; end;
  if not ImageSize(@d[0], Length(d), w, h) then begin FileNote := name + ': not a picture this program can show (JPEG, PNG).'; Exit; end;
  tw := w; th := h;
  if tw > CW then begin th := Int64(h) * CW div w; tw := CW; end;     { as wide as the screen at most, then scroll }
  if th > MAX_VIEW_H then begin tw := Int64(tw) * MAX_VIEW_H div th; th := MAX_VIEW_H; end;
  if tw < 1 then tw := 1; if th < 1 then th := 1;
  if not MemoryFor(Int64(tw) * th * 4) then begin FileNote := name + ' is too large for the free memory.'; Exit; end;
  GetMem(pix, tw * th * 2);
  if pix = nil then begin FileNote := 'Not enough memory for ' + name + '.'; Exit; end;
  if DecodeImage(@d[0], Length(d), tw, th, $FFFFFF, pix) then ViewBmp := MakeBitmap(pix, tw, th);
  FreeMem(pix);
  if ViewBmp = 0 then begin FileNote := name + ' could not be decoded.'; Exit; end;
  ViewW := tw; ViewH := th; ViewY := 0;
  ViewTitle := name + '   ' + IU(w) + ' x ' + IU(h);
  Viewing := 1;
end;

procedure WrapText(cols: Integer);
var i, start, last, n: Integer;
begin
  SetLength(ViewLines, 0);
  n := 0; start := 1;
  while start <= Length(ViewText) do
  begin
    i := start; last := -1;
    while (i <= Length(ViewText)) and (ViewText[i] <> #10) and (i - start < cols) do
    begin
      if ViewText[i] = ' ' then last := i;
      Inc(i);
    end;
    if (i <= Length(ViewText)) and (ViewText[i] <> #10) and (last > start) then i := last + 1;
    if n >= Length(ViewLines) then SetLength(ViewLines, n * 2 + 64);
    ViewLines[n] := start; Inc(n);
    if (i <= Length(ViewText)) and (ViewText[i] = #10) then Inc(i);
    start := i;
    if n > 20000 then Break;
  end;
  if n >= Length(ViewLines) then SetLength(ViewLines, n + 1);
  ViewLines[n] := Length(ViewText) + 1;
  SetLength(ViewLines, n + 1);
end;

procedure ViewTextFile(const path, name: UnicodeString);
var d: TByteArr; i, k: Integer;
begin
  CloseViewer;
  if not ReadWhole(path, 256 * 1024, d) then begin FileNote := name + ' cannot be read (or is over 256 KB).'; Exit; end;
  if Length(d) = 0 then ViewText := '' else ViewText := FromUtf8(@d[0], Length(d));
  { line ends to #10, tabs to spaces }
  k := 0;
  for i := 1 to Length(ViewText) do
    if ViewText[i] <> #13 then
    begin
      Inc(k);
      if ViewText[i] = #9 then ViewText[k] := ' ' else ViewText[k] := ViewText[i];
    end;
  SetLength(ViewText, k);
  WrapText((CW - 16) div MonoW);
  ViewLine := 0;
  ViewTitle := name;
  Viewing := 2;
end;

procedure OpenEntry;
var e: TEntry; path: UnicodeString; i: Integer;
begin
  if (FileSel < 0) or (FileSel >= NEntries) then Exit;
  e := Entries[FileSel];
  if e.folder then
  begin
    if SameW(e.name, '..') then
    begin
      i := Length(Folder) - 1;
      while (i > 0) and (Folder[i] <> '\') do Dec(i);
      OpenFolder(Copy(Folder, 1, i));
    end
    else OpenFolder(Folder + e.name + '\');
    Exit;
  end;
  path := Folder + e.name;
  if EndsCI(e.name, '.jpg') or EndsCI(e.name, '.jpeg') or EndsCI(e.name, '.png') then ViewPicture(path, e.name)
  else if EndsCI(e.name, '.wav') then StartPlaying(path, e.name)
  else if EndsCI(e.name, '.txt') or EndsCI(e.name, '.csv') or EndsCI(e.name, '.htm') or EndsCI(e.name, '.html') or EndsCI(e.name, '.md') then ViewTextFile(path, e.name)
  else FileNote := e.name + ': open it from the handheld''s own programs (it is in ' + Folder + ').';
end;

{ ---------- the remote ---------- }

procedure RemoteSend(const p: array of Byte; n: Integer);
begin
  Answer(T_INPUT, p, n);
end;

procedure RemoteView;
var p: array[0..5] of Byte; h: Integer;
begin
  h := ContentH; if h > SCR_MAXH then h := SCR_MAXH;
  p[0] := 4; p[1] := RemoteMode; p[2] := CW shr 8; p[3] := CW and 255; p[4] := h shr 8; p[5] := h and 255;
  RemoteSend(p, 6);
  ScrInit(Scr);
end;

procedure RemoteScroll(dx, dy: Integer);
var p: array[0..4] of Byte;
begin
  p[0] := 8; p[1] := (dx shr 8) and 255; p[2] := dx and 255; p[3] := (dy shr 8) and 255; p[4] := dy and 255;
  RemoteSend(p, 5);
end;

procedure RemoteSimple(kind, arg: Integer);
var p: array[0..1] of Byte;
begin
  p[0] := kind; p[1] := arg;
  if kind = 9 then RemoteSend(p, 2) else RemoteSend(p, 1);
end;

procedure RemoteTouch(kind, x1, y1, x2, y2: Integer);
var p: array[0..8] of Byte;
begin
  if x1 < 0 then x1 := 0; if y1 < 0 then y1 := 0; if x2 < 0 then x2 := 0; if y2 < 0 then y2 := 0;
  p[0] := kind; p[1] := x1 shr 8; p[2] := x1 and 255; p[3] := y1 shr 8; p[4] := y1 and 255;
  p[5] := x2 shr 8; p[6] := x2 and 255; p[7] := y2 shr 8; p[8] := y2 and 255;
  if kind = 3 then RemoteSend(p, 9) else RemoteSend(p, 5);
end;

{ the changed tiles into the remote picture's bitmap }
procedure RemoteBlit;
type TBI = record hdr: BITMAPINFOHEADER; mask: array[0..2] of DWORD; end;
var tx, ty, x, y, g, o: Integer; row: PWord; bi: TBI; bits: Pointer; pal: array[0..15] of Word;
begin
  if RemoteBmp = 0 then
  begin
    if not Assigned(pCreateDIBSection) then Exit;
    FillChar(bi, SizeOf(bi), 0);
    bi.hdr.biSize := SizeOf(BITMAPINFOHEADER);
    bi.hdr.biWidth := SCR_MAXW; bi.hdr.biHeight := -SCR_MAXH;        { top row first }
    bi.hdr.biPlanes := 1; bi.hdr.biBitCount := 16; bi.hdr.biCompression := BI_BITFIELDS;
    bi.mask[0] := $F800; bi.mask[1] := $07E0; bi.mask[2] := $001F;
    bits := nil;
    RemoteBmp := pCreateDIBSection(ScreenDC, @bi, DIB_RGB_COLORS, @bits, 0, 0);
    if (RemoteBmp = 0) or (bits = nil) then begin RemoteBmp := 0; Exit; end;
    RemoteBits := bits;
    FillChar(RemoteBits^, SCR_MAXW * SCR_MAXH * 2, $FF);
    for ty := 0 to SCR_TH - 1 do for tx := 0 to SCR_TW - 1 do Scr.changed[ty, tx] := True;
  end;
  for g := 0 to 15 do pal[g] := (((g * 31 + 7) div 15) shl 11) or (((g * 63 + 7) div 15) shl 5) or ((g * 31 + 7) div 15);
  for ty := 0 to SCR_TH - 1 do
    for tx := 0 to SCR_TW - 1 do
      if Scr.changed[ty, tx] then
      begin
        Scr.changed[ty, tx] := False;
        for y := ty * SCR_T to ty * SCR_T + SCR_T - 1 do
        begin
          row := RemoteBits + y * SCR_MAXW + tx * SCR_T;
          o := y * SCR_MAXW + tx * SCR_T;
          for x := 0 to SCR_T - 1 do row[x] := pal[Scr.pix[o + x]];
        end;
      end;
  Scr.anyChanged := False;
end;

{ ---------- the pairing check (docs/FORMAT3.md, section 7) ---------- }

procedure StartPair(answering: Boolean);
var x, z: TSmallArr; i: Integer; y: TSamples;
begin
  if (not answering) and ((PairState = 1) or (PairState = 2)) then Exit;   { already pairing: one press is enough }
  PairState := 1; PairPlayed := False; PairReported := False;
  if not answering then begin HaveMine := False; HaveTheirs := False; end;
  PairNote := 'Playing the test sound (beeps), then listening for the phone''s...';
  FastUntil := GetTickCount + 40000;
  x := PairPattern(TxRate);
  { then the loudness ladder: the phone hears which loudness comes through cleanest, and says so in its report }
  z := PairLadder(CH_SU, PAIR_LADDER);
  SetLength(y, Length(x) + Length(z));
  for i := 0 to High(x) do y[i] := x[i];
  for i := 0 to High(z) do y[Length(x) + i] := z[i];
  AudioSend(y);
end;

procedure TestSpeaker;
var y: TSamples; i, n, g: Integer;
begin
  n := TxRate;                                       { one second of 1.2 kHz, clearly audible (its overtones miss 2 kHz, the pairing marker) }
  SetLength(y, n);
  for i := 0 to n - 1 do
  begin
    g := 12000;
    if i < 441 then g := g * i div 441;
    if n - 1 - i < 441 then g := g * (n - 1 - i) div 441;
    y[i] := (g * SinI(Integer((Int64(1200) * i * 65536 div TxRate) and $FFFF))) div 16384;
  end;
  AudioSend(y);
  SpeakerNote := 'A one-second beep now: if you hear nothing, the sound does not get out (check Volume in the Control Panel).';
end;

function DbText(d10: Integer): UnicodeString;
begin
  if d10 <= -900 then begin Result := '-'; Exit; end;
  if d10 >= 0 then Result := '+' + IU(d10 div 10) + ' dB' else Result := '-' + IU((-d10) div 10) + ' dB';
end;

procedure PairStep(now: LongWord);
var x: TSmallArr; n: Integer; pos: Int64; b: array[0..63] of Byte;
begin
  { the phone's test sound: its first marker was heard; once all of it has had time to arrive, read it }
  if (PairMarkAt <> 0) and (PairMarkAt <> LastMarkSeen) and (LongInt(now - PairMarkAt) >= 3400) then
  begin
    LastMarkSeen := PairMarkAt;
    pos := PairMarkPos - Int64(700) * IN_RATE div 1000;
    SetLength(x, Int64(4200) * IN_RATE div 1000);
    n := AudioRingCopy(pos, x, Length(x));
    if not PairAnalyze(x, n, IN_RATE, PairMine) then Log('pair: the marker was not the phone''s test sound (or it could not be read)')
    else
    begin
      Log('pair: the phone''s test sound read, scale ' + LI(PairMine.scale10k) + ', its silent band ' + LI(PairBand10(PairMine, 20000, 21200) div 10) + ' dB');
      HaveMine := True;
      { the phone's silent band too weak here: it will answer on the fast channel, so that one stays on }
      FastAlways := PairBand10(PairMine, 20000, 21200) < 120;
      { the time between the markers is this microphone's real rate (the phone's clock is good) }
      if (PairMine.scale10k > 9500) and (PairMine.scale10k < 10500) then AudioCalibrate(Int64(IN_RATE) * PairMine.scale10k div 100);
      SaveCfg;
      if (PairState = 0) or (PairState = 3) then
      begin
        { the phone started: our turn }
        StartPair(True);
        PairNote := 'Heard the phone''s test sound; now playing this handheld''s...';
      end
      else if PairState = 2 then PairState := 3;
    end;
  end;
  if (PairState = 1) and (AudioQueued = 0) then
  begin
    PairPlayed := True;
    if HaveMine then PairState := 3
    else begin Log('pair: test sound played, listening for the phone''s'); PairState := 2; PairDeadline := now + 15000; PairNote := 'Listening for the phone''s test sound (press Pair on the phone if it does not start by itself)...'; end;
  end;
  if (PairState = 2) and (LongInt(now - PairDeadline) > 0) then
  begin
    PairState := 3;
    Log('pair: the phone''s test sound was not heard');
    PairNote := 'The phone''s test sound was not heard. Is Whisper Tools connected on the phone, its media volume about half?';
  end;
  { our report, once we have heard theirs and played ours }
  if HaveMine and PairPlayed and not PairReported and (AudioQueued = 0) then
  begin
    PairReported := True;
    n := PairReportMake(PairMine, b);
    SendMsg(CH_FU, PAIR_REPORT, b, n);
    if PairState = 3 then PairNote := 'Done. The results below; the phone shows its side.';
  end;
end;

{ ---------- the timer: hearing, answering, sending ---------- }

var PhoneHeardSD: LongWord = 0;
const LISTEN_MS = 1500;          { listening after each text frame of ours, for the phone's answer (it may take ~0.6 s to sound, and as long to play) }
var WaitAnswer: Boolean = False;  { the last turn held a text frame: the phone will confirm it }

var RateChosenAt: LongWord = 0; ShownPieces: Integer = 0; ShownLost: Integer = 0;
    LastPump: LongWord = 0; LoggedScreen: Integer = -1; LastAlive: LongWord = 0;

procedure Pump;
var g: TGotMsg; t: TTrainResult; now: LongWord; p: array[0..127] of Byte; n, typ, i: Integer; fp: TByteArr; cs: TSamples;
    changed: Boolean;
begin
  changed := False;
  now := GetTickCount;
  if (LastPump <> 0) and (now - LastPump > 1500) then Log('screen thread: held up for ' + LI(now - LastPump) + ' ms');
  LastPump := now;
  if Screen <> LoggedScreen then begin LoggedScreen := Screen; Log('screen ' + LI(Screen)); end;
  if now - LastAlive >= 15000 then
  begin
    LastAlive := now;
    Log('status: sounds queued ' + LI(AudioQueued) + ', answers waiting ' + LI(AnswerN) + ', text not confirmed ' + LI(TsUnconfirmed(Ts))
      + ', file in ' + LI(Ord(Incoming.active)) + ', files out ' + LI(NOut) + ', turns ' + LI(Turns) + ', frames heard ' + LI(FramesIn)
      + ', lost ' + LI(FramesBad) + ', skipped buffers ' + LI(Overruns));
  end;
  LogTick(False);
  if (FilePieces <> ShownPieces) or (FileLost <> ShownLost) then
  begin ShownPieces := FilePieces; ShownLost := FileLost; changed := True; end;
  while AudioTake(g) do
  begin
    if g.ch = CH_SD then PhoneHeardSD := GetTickCount;
    OnPhone(g);
    if g.msg.typ <> T_SCREEN then changed := True;
  end;
  while AudioTakeTrain(t) do begin OnTrain(t); changed := True; end;
  FeedPlayer;
  now := GetTickCount;
  PairStep(now);
  { the fast receiver costs the processor a fifth of its time: it listens only when something fast can come
    (a file announced on the silent channel, the remote, a link check, or the Files and Remote screens) }
  ListenFast := FastAlways or (Screen = SCR_FILES) or (Screen = SCR_REMOTE) or RemoteOn or Incoming.active or (LongInt(FastUntil - now) > 0);
  { files coming in: the answers }
  if (Length(Incoming.r.got) > 0) and FrNeedDue(Incoming.r, now) and (Incoming.active or (now - Incoming.doneAt < 120000)) then
  begin
    SetLength(fp, 0);
    n := FrNeed(Incoming.r, fp);
    Answer(T_FILE_NEED, fp, n);
  end;
  if Incoming.active and FrComplete(Incoming.r) then begin FinishIncoming; changed := True; end;
  if (UnknownId >= 0) and (now - UnknownAt > QUIET_MS) then
  begin
    SetLength(fp, 0);
    n := FrNeedOffer(UnknownId, fp);
    Answer(T_FILE_NEED, fp, n);
    UnknownId := -1;
  end;
  if AudioQueued > 0 then begin if changed then InvalidateRect(hMain, nil, False); Exit; end;
  { nothing queued: the moment to change the rate the speaker plays at, if it should }
  if (not OutPlaying) and (now - RateChosenAt >= 5000) then begin RateChosenAt := now; AudioChooseRate; end;
  if (PairState = 1) or (PairState = 2) then begin if changed then InvalidateRect(hMain, nil, False); Exit; end;
  { classic tones }
  if Classic and ClassicSamples(cs) then begin AudioSend(cs); InvalidateRect(hMain, nil, False); Exit; end;
  { after each frame the phone may answer: the microphone stays open for it (docs/FORMAT3.md, section 5).
    The window closes early once the phone's answer has arrived. Our own answers do not wait. }
  if WaitAnswer and ((LongInt(now - LastTurnAt) >= LISTEN_MS) or (LongInt(PhoneHeardSD - LastTurnAt) > 0)) then WaitAnswer := False;
  if (AnswerN = 0) and WaitAnswer then
  begin
    if changed then InvalidateRect(hMain, nil, False);
    Exit;
  end;
  { answers first, once the phone has been quiet on the silent channel for a moment }
  if (AnswerN > 0) and (now - PhoneHeardSD >= 150) then
  begin
    SendMsg(Answers[0].ch, Answers[0].typ, Answers[0].p, Answers[0].n);
    for i := 0 to AnswerN - 2 do Answers[i] := Answers[i + 1];
    Dec(AnswerN);
    InvalidateRect(hMain, nil, False);
    Exit;
  end;
  if not Classic then
  begin
    n := TsNext(Ts, now, p);
    if n > 0 then begin SendMsg(SilentCh, T_TEXT, p, n); WaitAnswer := True; InvalidateRect(hMain, nil, False); Exit; end;
  end;
  if (NOut > 0) and not Playing then
  begin
    SetLength(fp, 0);
    if FsNext(Outgoing[0].s, now, typ, fp, n) then
    begin
      Log('file out: ' + LI(FsConfirmed(Outgoing[0].s)) + ' of ' + LI(Outgoing[0].s.packets) + ' packets confirmed');
      if FastFiles then SendMsg(CH_FU, typ, fp, n) else SendMsg(SilentCh, typ, fp, n);
      SetTrans(Outgoing[0].t, 'Sending', FsProgress1000(Outgoing[0].s), False, False);
      changed := True;
    end;
    if Outgoing[0].s.done or Outgoing[0].s.failed then
    begin
      Log('file out: finished, done ' + LI(Ord(Outgoing[0].s.done)) + ' failed ' + LI(Ord(Outgoing[0].s.failed)) + ' all confirmed ' + LI(Ord(Outgoing[0].s.confirmedAll)));
      if Outgoing[0].s.failed then SetTrans(Outgoing[0].t, 'Stopped: the phone does not answer', FsProgress1000(Outgoing[0].s), True, False)
      else if Outgoing[0].s.confirmedAll then SetTrans(Outgoing[0].t, 'On the phone (Downloads/Whisper Tools)', 1000, True, True)
      else SetTrans(Outgoing[0].t, 'Sent (the phone could not confirm)', 1000, True, True);
      for i := 0 to NOut - 2 do Outgoing[i] := Outgoing[i + 1];
      Dec(NOut);
      changed := True;
    end;
  end;
  if changed then InvalidateRect(hMain, nil, False);
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

procedure Button(dc: HDC; const rc: TRect; const lbl, key: UnicodeString);
begin
  FillR(dc, rc, COL_NAVY);
  FillR(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_HI);
  Txt(dc, lbl, MkRect(rc.left + 6, rc.top + 3, rc.right - 4, rc.bottom), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, key, MkRect(rc.left + 6, rc.top + 4, rc.right - 5, rc.bottom), fSmall, COL_GREY, DT_RIGHT or DT_SINGLELINE);
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


function KeyLabel(code: Integer): UnicodeString;
begin
  case code of
    K_BACKSPACE: Result := '[Bksp]'; K_TAB: Result := '[Tab]'; K_SHIFT_TAB: Result := '[Shift+Tab]'; K_ESC: Result := '[Esc]';
    K_PGUP: Result := '[PgUp]'; K_PGDN: Result := '[PgDn]'; K_END: Result := '[End]'; K_HOME: Result := '[Home]';
    K_LEFT: Result := '[Left]'; K_UP: Result := '[Up]'; K_RIGHT: Result := '[Right]'; K_DOWN: Result := '[Down]';
    K_DELETE: Result := '[Del]'; K_SELALL: Result := '[Ctrl+A]'; K_COPY: Result := '[Ctrl+C]'; K_PASTE: Result := '[Ctrl+V]';
    K_CUT: Result := '[Ctrl+X]'; K_UNDO: Result := '[Ctrl+Z]'; K_SEND: Result := '[Send]'; K_BACK: Result := '[Back]';
    K_HOMESCREEN: Result := '[Home screen]'; K_RECENTS: Result := '[Recent apps]';
  else Result := '[Key]';
  end;
end;

{ the end of the typed text, keys as labels, wrapped to the width }
procedure DrawDoc(dc: HDC; top, bottom: Integer);
const MAXL = 300;
var cols, rows, i, j, j2, nl, start, x, y, k: Integer; s, seg: UnicodeString; col: COLORREF;
    ls, ln: array[0..MAXL - 1] of Integer; line: UnicodeString;
begin
  cols := (CW - 16) div MonoW;
  rows := (bottom - top) div MonoH;
  if cols < 10 then cols := 10;
  start := ShowN - cols * rows * 2;
  if start < 0 then start := 0;
  while (start > 0) and (Show[start - 1] <> #10) do Dec(start);
  s := '';
  for i := start to ShowN - 1 do
    if IsKeyChar(Show[i]) then s := s + KeyLabel(Ord(Show[i]) - KEY_BASE)
    else s := s + Show[i];
  nl := 0; ls[0] := 1; ln[0] := 0;
  for i := 1 to Length(s) do
  begin
    if s[i] = #10 then
    begin
      Inc(nl); if nl >= MAXL then Break;
      ls[nl] := i + 1; ln[nl] := 0;
    end
    else
    begin
      if ln[nl] >= cols then
      begin
        j := ls[nl] + ln[nl] - 1;
        while (j > ls[nl]) and (s[j] <> ' ') do Dec(j);
        Inc(nl); if nl >= MAXL then Break;
        if (j > ls[nl - 1]) and (s[j] = ' ') then
        begin
          ln[nl - 1] := j + 1 - ls[nl - 1];
          ls[nl] := j + 1; ln[nl] := i - (j + 1);
        end
        else begin ls[nl] := i; ln[nl] := 0; end;
      end;
      Inc(ln[nl]);
    end;
  end;
  if nl >= MAXL then nl := MAXL - 1;
  j := nl - rows + 1; if j < 0 then j := 0;
  y := top;
  for i := j to nl do
  begin
    line := Copy(s, ls[i], ln[i]);
    { plain text and key labels in turn, each measured: the next starts where the last ended }
    x := 8; k := 1;
    while k <= Length(line) do
    begin
      j2 := k;
      if line[k] = '[' then
      begin
        while (j2 <= Length(line)) and (line[j2] <> ']') do Inc(j2);
        seg := Copy(line, k, j2 - k + 1); col := COL_KEY; k := j2 + 1;
      end
      else
      begin
        while (j2 <= Length(line)) and (line[j2] <> '[') do Inc(j2);
        seg := Copy(line, k, j2 - k); col := COL_TEXT; k := j2;
      end;
      Txt(dc, seg, MkRect(x, y, CW - 4, y + MonoH), fMono, col, DT_LEFT or DT_SINGLELINE);
      x := x + TextW(dc, seg, fMono);
    end;
    if i = nl then
    begin
      if x > CW - 10 then x := CW - 10;
      FillR(dc, MkRect(x + 1, y + 1, x + 3, y + MonoH - 1), COL_GOOD);
    end;
    y := y + MonoH;
  end;
  if ShowN = 0 then
    Txt(dc, 'Start typing. On the phone, open any app, tap a text field and switch to the Whisper Tools keyboard. ' +
        'Tab, the arrows and Ctrl+C, V, X, Z go to the phone too. Alt+S presses Send there.',
        MkRect(20, top + 4, CW - 20, top + 60), fNorm, COL_GREY, DT_LEFT or DT_WORDBREAK);
end;

const
  TYPE_BTN = 5;
  TYPE_BTN_LABEL: array[0..TYPE_BTN - 1] of UnicodeString = ('Send', 'Back', 'Phone home', 'New page', 'Tools');
  TYPE_BTN_KEY: array[0..TYPE_BTN - 1] of UnicodeString = ('Alt+S', 'Alt+B', '', 'Alt+N', 'Alt+0');

function TypeBtnRect(i: Integer): TRect;
var w, y: Integer;
begin
  w := (CW - 16 - (TYPE_BTN - 1) * 5) div TYPE_BTN;
  y := CH - STATUS_H - 25;
  Result := MkRect(8 + i * (w + 5), y, 8 + i * (w + 5) + w, y + 22);
end;

procedure DrawType(dc: HDC);
var i: Integer;
begin
  DrawDoc(dc, TITLE_H + 3, CH - STATUS_H - 28);
  for i := 0 to TYPE_BTN - 1 do Button(dc, TypeBtnRect(i), TYPE_BTN_LABEL[i], TYPE_BTN_KEY[i]);
end;

procedure DrawFiles(dc: HDC);
var top, rows, i, y, x2: Integer; e: TEntry; s: UnicodeString; col: COLORREF; rc: TRect; mdc: HDC;
begin
  top := TITLE_H + 2;
  if Viewing = 1 then
  begin
    rc := MkRect(0, top, CW, CH - STATUS_H);
    FillR(dc, rc, $808080);
    x2 := (CW - ViewW) div 2;
    y := top;
    if ViewH < ContentH then y := top + (ContentH - ViewH) div 2;
    i := ViewH - ViewY; if i > ContentH then i := ContentH;      { no further down than the status line }
    mdc := CreateCompatibleDC(dc);
    SelectObject(mdc, ViewBmp);
    BitBlt(dc, x2, y, ViewW, i, mdc, 0, ViewY, SRCCOPY);
    DeleteDC(mdc);
    Exit;
  end;
  if Viewing = 2 then
  begin
    rows := (CH - STATUS_H - top - 4) div MonoH;
    y := top + 2;
    for i := ViewLine to ViewLine + rows - 1 do
    begin
      if i >= Length(ViewLines) - 1 then Break;
      s := Copy(ViewText, ViewLines[i], ViewLines[i + 1] - ViewLines[i]);
      while (Length(s) > 0) and ((s[Length(s)] = #10) or (s[Length(s)] = ' ')) do SetLength(s, Length(s) - 1);
      Txt(dc, s, MkRect(8, y, CW - 8, y + MonoH), fMono, COL_TEXT, DT_LEFT or DT_SINGLELINE);
      y := y + MonoH;
    end;
    Exit;
  end;
  { the folder on the left, transfers on the right }
  x2 := 380;
  Txt(dc, Folder, MkRect(8, top, x2 - 8, top + 16), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  rows := (CH - STATUS_H - top - 22 - 18) div 15;
  if FileSel < FileTop then FileTop := FileSel;
  if FileSel >= FileTop + rows then FileTop := FileSel - rows + 1;
  y := top + 18;
  for i := FileTop to FileTop + rows - 1 do
  begin
    if i >= NEntries then Break;
    e := Entries[i];
    if i = FileSel then FillR(dc, MkRect(4, y, x2 - 6, y + 15), COL_SEL);
    if e.folder then s := e.name + '\' else s := e.name;
    Txt(dc, s, MkRect(8, y, x2 - 70, y + 15), fNorm, COL_TEXT, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    if not e.folder then Txt(dc, SizeText(e.size), MkRect(x2 - 70, y, x2 - 10, y + 15), fSmall, COL_GREY, DT_RIGHT or DT_SINGLELINE);
    y := y + 15;
  end;
  if NEntries = 0 then Txt(dc, '(empty)', MkRect(8, y, x2, y + 15), fNorm, COL_GREY, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'Enter open   S send to the phone   Backspace up   I received   C cancel', MkRect(8, CH - STATUS_H - 17, x2 + 60, CH - STATUS_H - 2),
      fSmall, COL_GREY, DT_LEFT or DT_SINGLELINE);
  FillR(dc, MkRect(x2, top, x2 + 1, CH - STATUS_H - 20), COL_LINE);
  Txt(dc, 'Transfers', MkRect(x2 + 10, top, CW - 8, top + 16), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
  y := top + 18;
  if NTrans = 0 then
    Txt(dc, 'To send a file to the phone, select it and press S. ' +
        'From the phone: Share, then Whisper Tools, in any app. Files arrive in ' + InFolder,
        MkRect(x2 + 10, y, CW - 8, y + 90), fNorm, COL_GREY, DT_LEFT or DT_WORDBREAK);
  for i := NTrans - 1 downto 0 do
  begin
    if y > CH - STATUS_H - 50 then Break;
    if Trans[i].out then s := '-> ' else s := '<- ';
    Txt(dc, s + Trans[i].name, MkRect(x2 + 10, y, CW - 8, y + 15), fBold, COL_TEXT, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    y := y + 15;
    if Trans[i].finished then begin if Trans[i].ok then col := COL_GOOD else col := COL_FAIL; end else col := COL_GREY;
    s := Trans[i].state;
    if not Trans[i].finished then s := s + ', ' + IU(Trans[i].permille div 10) + '% of ' + SizeText(Trans[i].size);
    Txt(dc, s, MkRect(x2 + 10, y, CW - 8, y + 14), fSmall, col, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    y := y + 14;
    if not Trans[i].finished then
    begin
      FillR(dc, MkRect(x2 + 10, y + 1, CW - 10, y + 5), COL_LINE);
      FillR(dc, MkRect(x2 + 10, y + 1, x2 + 10 + (CW - 20 - x2) * Trans[i].permille div 1000, y + 5), COL_GOOD);
      y := y + 7;
    end;
    y := y + 4;
  end;
  if FileNote <> '' then Txt(dc, FileNote, MkRect(x2 + 10, CH - STATUS_H - 46, CW - 8, CH - STATUS_H - 2), fNorm, COL_FAIL, DT_LEFT or DT_WORDBREAK);
end;

procedure DrawRemote(dc: HDC);
var mdc: HDC; top, h, w: Integer;
begin
  top := TITLE_H;
  if (Scr.messages = 0) or not RemoteOn then
  begin
    if RemoteOn then
      Txt(dc, 'The phone is sending its screen: it fills in from the top over a few seconds.',
          MkRect(20, top + 20, CW - 20, top + 60), fBig, COL_NAVY, DT_LEFT or DT_WORDBREAK)
    else
      Txt(dc, 'To see the phone''s screen here: in the Whisper Tools app on the phone, open Remote, then tap Start the remote. ' +
          'Or press Enter here to ask the phone (it shows a notification to tap).' + #10#10 +
          'Then: tap the picture to tap on the phone (it needs the Whisper Tools helper on the phone). ' +
          'Arrows and Page Up/Down move the view, Alt+Z switches between zoom and the whole screen, Alt+U refreshes. ' +
          'What you type goes to the phone as on the Type screen.',
          MkRect(20, top + 14, CW - 20, CH - STATUS_H - 4), fNorm, COL_TEXT, DT_LEFT or DT_WORDBREAK);
    Exit;
  end;
  if Scr.anyChanged or (RemoteBmp = 0) then RemoteBlit;
  if RemoteBmp = 0 then Exit;
  w := Scr.tw * SCR_T; if w > CW then w := CW;
  h := Scr.th * SCR_T; if h > ContentH then h := ContentH;
  mdc := CreateCompatibleDC(dc);
  SelectObject(mdc, RemoteBmp);
  BitBlt(dc, 0, top, w, h, mdc, 0, 0, SRCCOPY);
  DeleteDC(mdc);
end;

function LinkBtn(i: Integer): TRect;
var w: Integer;
begin
  w := (CW - 24 - 2 * 6) div 3;
  Result := MkRect(12 + i * (w + 6), CH - STATUS_H - 27, 12 + i * (w + 6) + w, CH - STATUS_H - 5);
end;

procedure DrawLink(dc: HDC);
var y: Integer; s: UnicodeString; col: COLORREF;
  procedure Line(const a, b: UnicodeString; c: COLORREF);
  begin
    Txt(dc, a, MkRect(10, y, 150, y + 15), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
    Txt(dc, b, MkRect(150, y, CW - 10, y + 15), fNorm, c, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    y := y + 15;
  end;
begin
  y := TITLE_H + 4;
  if OutErr <> '' then Line('Speaker', OutErr, COL_FAIL)
  else if Turns = 0 then Line('Speaker', 'has not played yet', COL_GREY)
  else Line('Speaker', IU(Turns) + ' times, last ' + IU((GetTickCount - LastTurnAt) div 1000) + ' s ago for ' +
    IU(LastTurnMs) + ' ms, loudest ' + IU(LastTurnPeak) + '%; ' + OutRateNote, COL_TEXT);
  if InErr <> '' then Line('Microphone', InErr, COL_FAIL)
  else
  begin
    s := IU(InRate100 div 100) + ' samples/s';
    case RateSource of
      0: s := s + ' (what it claims, until measured)';
      1: s := s + ' (measured)';
      2: s := s + ' (calibrated by Pair)';
    end;
    if RateOdd <> 0 then s := s + '; an odd reading of ' + IU(RateOdd div 100) + ' was not used';
    s := s + ', loudest ' + IU(InPeak * 100 div 32768) + '%';
    if Overruns > 0 then s := s + ', fell behind ' + IU(Overruns) + ' times';
    Line('Microphone', s, COL_TEXT);
  end;
  if PhoneHeard = 0 then Line('The phone', 'no frame heard yet; ' + IU(FramesOut) + ' sent, ' + IU(FramesBad) + ' not readable',
    COL_GREY)
  else Line('The phone', 'heard ' + IU((GetTickCount - PhoneHeard) div 1000) + ' s ago; frames ' + IU(FramesOut) + ' sent, ' +
    IU(FramesIn) + ' heard, ' + IU(FramesBad) + ' not readable', COL_GOOD);
  if HaveMine then
  begin
    if PairBand10(PairMine, 20000, 21200) >= 120 then col := COL_GOOD else col := COL_FAIL;
    Line('Hears the phone', 'silent ' + DbText(PairBand10(PairMine, 20000, 21200)) + ', fast ' +
      DbText(PairBand10(PairMine, 500, 12000)) + ' (1-12 kHz)' + ', mic at ' + IU(Int64(IN_RATE) * PairMine.scale10k div 10000), col);
  end
  else Line('Hears the phone', 'not measured: press Pair', COL_GREY);
  if HaveTheirs then
  begin
    if PairBand10(PairTheirs, 20200, 21200) >= 150 then col := COL_GOOD else col := COL_FAIL;
    Line('Phone hears this', 'silent ' + DbText(PairBand10(PairTheirs, 20200, 21200)) + ', wide ' +
      DbText(PairBand10(PairTheirs, 18500, 21200)) + ', fast ' + DbText(PairBand10(PairTheirs, 1000, 12000)), col);
  end
  else Line('Phone hears this', 'not known yet (the phone sends it after pairing)', COL_GREY);
  if TypingOnFast then s := 'on the fast channel (a soft hiss): the silent band does not reach the phone'
  else s := 'silent, ' + KHz(100 * Chans[SilentCh].bins[0]) + '-' + KHz(100 * Chans[SilentCh].bins[Chans[SilentCh].n - 1]) + ' kHz';
  Line('Typing goes', s, COL_TEXT);
  if LevelSource = 1 then s := IU(SilentPeak * 100 div 32767) + '% (chosen by Pair)'
  else s := IU(SilentPeak * 100 div 32767) + '% (until Pair chooses)';
  Line('Silent loudness', s, COL_TEXT);
  s := '';
  if FuSpeed <> '' then s := 'to the phone ' + FuSpeed + '  ';
  if FdSpeed <> '' then s := s + 'from it ' + FdSpeed;
  if s <> '' then Line('Fast channels', s, COL_TEXT);
  if PairNote <> '' then begin Txt(dc, PairNote, MkRect(10, y, CW - 10, y + 15), fNorm, COL_KEY, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS); y := y + 15; end;
  if SpeakerNote <> '' then begin Txt(dc, SpeakerNote, MkRect(10, y, CW - 10, y + 15), fNorm, COL_KEY, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS); y := y + 15; end;
  if CheckState <> '' then Txt(dc, CheckState, MkRect(10, y, CW - 10, y + 15), fNorm, COL_GREY, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
  Button(dc, LinkBtn(0), 'Pair', 'P');
  Button(dc, LinkBtn(1), 'Test speaker', 'S');
  Button(dc, LinkBtn(2), 'Check the link', 'K');
end;

const NSET = 9;

function SettingName(i: Integer): UnicodeString;
begin
  case i of
    0: Result := 'Typing format';
    1: Result := 'Silent channel';
    2: Result := 'Files to the phone';
    3: Result := 'Fast loudness';
    4: Result := 'Received files';
    5: Result := 'Speaker rate';
    6: Result := 'Classic band';
    7: Result := 'Classic speed';
    8: Result := 'Classic volume';
  else Result := '';
  end;
end;

function SettingValue(i: Integer): UnicodeString;
begin
  case i of
    0: if Classic then Result := 'Classic (for the receiver page, e.g. on an iPhone): text only'
       else Result := 'Standard: silent, all keys, the phone confirms';
    1: if WideSilent then Result := 'Wide, 18.2-21.2 kHz: twice as fast, some people hear it'
       else Result := 'Narrow, 20.0-21.2 kHz: inaudible';
    2: if FastFiles then Result := 'Fast: a soft hiss while it goes, about 7-12 kbit/s' else Result := 'Silent: slow (a 10 KB file takes 1-2 minutes)';
    3: case FastLevel of 0: Result := '1/8'; 2: Result := '1/2'; else Result := '1/4'; end;
    4: if OnCard then Result := '\Storage Card\Whisper Tools' else Result := '\My Documents\Whisper Tools';
    5: if SpeakerNative then Result := 'The sound chip''s own (measured), else 44,100'
       else Result := '44,100, converted by Windows (lower quality)';
    6: Result := KHz(BAND_HZ[Band]) + '-' + KHz(BAND_HZ[Band] + 15 * STEP_HZ) + ' kHz';
    7: Result := US(SPEED_NAME[Speed]);
    8: Result := IU(Volume) + '%';
  else Result := '';
  end;
end;

procedure ChangeSetting(i, dir: Integer);
begin
  case i of
    0: begin Classic := not Classic; NewPage; end;
    1: WideSilent := not WideSilent;
    2: FastFiles := not FastFiles;
    3: FastLevel := (FastLevel + 3 + dir) mod 3;
    4: OnCard := not OnCard;
    5: SpeakerNative := not SpeakerNative;
    6: Band := (Band + NBANDS + dir) mod NBANDS;
    7: Speed := (Speed + NSPEEDS + dir) mod NSPEEDS;
    8: begin Volume := Volume + 10 * dir; if Volume > 100 then Volume := 10; if Volume < 10 then Volume := 100; end;
  end;
  SaveCfg;
end;

procedure DrawSettings(dc: HDC);
var i, y: Integer;
begin
  y := TITLE_H + 6;
  for i := 0 to NSET - 1 do
  begin
    if (i >= 6) and not Classic then Break;
    if i = SetSel then FillR(dc, MkRect(6, y - 1, CW - 6, y + 16), COL_SEL);
    Txt(dc, SettingName(i), MkRect(12, y, 170, y + 16), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
    Txt(dc, SettingValue(i), MkRect(170, y, CW - 12, y + 16), fNorm, COL_TEXT, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    y := y + 18;
  end;
  Txt(dc, 'Up and Down choose, Left, Right or Enter change. ' +
      'Whisper Tools ' + VERSION + ' by ' + CREATOR + '. Shortcuts: Alt+0 home, Alt+1 to Alt+5 tools, Alt+S Send, Alt+B Back, ' +
      'Alt+H Home screen, Alt+W Recent apps, Alt+N new page, Alt+K check the link, Alt+Q quit.',
      MkRect(12, CH - STATUS_H - 48, CW - 12, CH - STATUS_H - 2), fSmall, COL_GREY, DT_LEFT or DT_WORDBREAK);
end;

function StatusText(out col: COLORREF): UnicodeString;
var u, w: Integer;
begin
  col := COL_GREY;
  if not OutOk then
  begin
    if OutErr <> '' then Result := OutErr else Result := 'Opening sound...';
    col := COL_FAIL; Exit;
  end;
  if Playing then begin Result := 'Playing ' + PlayName; Exit; end;
  if NOut > 0 then
  begin
    Result := 'Sending ' + Trans[Outgoing[0].t].name + ', ' + IU(FsProgress1000(Outgoing[0].s) div 10) + '%';
    col := COL_GOOD; Exit;
  end;
  if Incoming.active then
  begin
    Result := 'Receiving ' + Trans[Incoming.t].name + ', ' + IU(Trans[Incoming.t].permille div 10) + '%';
    if FileLost > 0 then Result := Result + ' (' + IU(FileLost) + ' pieces arrived damaged: asked for again)';
    col := COL_GOOD; Exit;
  end;
  { pieces of a file are heard, but its announcement was not read: say so, rather than nothing }
  if (FilePieceAt <> 0) and (GetTickCount - FilePieceAt < 30000) then
  begin
    Result := 'A file is coming from the phone: ' + IU(FilePieces) + ' pieces heard, ' + IU(FileLost) + ' arrived damaged';
    if FileLost * 2 > FilePieces then col := COL_FAIL else col := COL_GOOD;
    Exit;
  end;
  if Classic then
  begin
    EnterCriticalSection(ClassicLock);
    w := ClassicSnd.L - ClassicSnd.liveFrom;
    LeaveCriticalSection(ClassicLock);
    if w > 0 then begin Result := IU(w) + ' waiting (Classic)'; col := COL_GOOD; end
    else Result := 'Classic: ' + KHz(BAND_HZ[Band]) + ' kHz, ' + US(SPEED_NAME[Speed]);
    Exit;
  end;
  w := TsWaiting(Ts); u := TsUnconfirmed(Ts);
  if w > 0 then begin Result := 'Sending, ' + IU(w) + ' waiting'; col := COL_GOOD; end
  else if u > 0 then begin Result := IU(u) + ' not yet confirmed by the phone'; col := COL_GOOD; end
  else if u = 0 then begin if Ts.L > 0 then Result := 'All on the phone' else Result := 'The phone hears this handheld'; col := COL_GOOD; end
  else if PhoneHeard <> 0 then Result := 'Phone heard: ready'
  else Result := 'Ready (the phone has not answered yet)';
end;

const
  NHOME = 6;
  HOME_NAME: array[0..NHOME - 1] of UnicodeString = ('Type', 'Files', 'Remote', 'Link', 'Settings', 'Exit');
  HOME_WHAT: array[0..NHOME - 1] of UnicodeString = (
    'Type into any app on the phone',
    'Send, receive, view and play',
    'The phone''s screen, here',
    'Signal, speeds, link check',
    'Format, channels, folders',
    'Close Whisper Tools');

function HomeBtnRect: TRect;
begin
  Result := MkRect(3, 3, 66, TITLE_H - 3);
end;

function HomeTile(i: Integer): TRect;
var w, h, x, y, top: Integer;
begin
  top := TITLE_H + 6;
  w := (CW - 16 - 2 * 6) div 3;
  h := (CH - STATUS_H - top - 6 - 6) div 2;
  x := 8 + (i mod 3) * (w + 6);
  y := top + (i div 3) * (h + 6);
  Result := MkRect(x, y, x + w, y + h);
end;

function HomeState(i: Integer; out col: COLORREF): UnicodeString;
var u: Integer;
begin
  col := COL_GOOD; Result := '';
  case i of
    0: begin
         u := TsUnconfirmed(Ts);
         if Classic then Result := 'Classic format'
         else if TsWaiting(Ts) > 0 then Result := 'Sending'
         else if u > 0 then Result := IU(u) + ' not yet confirmed'
         else if (u = 0) and (Ts.L > 0) then Result := 'All on the phone'
         else if PhoneHeard <> 0 then Result := 'The phone hears you';
       end;
    1: if NOut > 0 then Result := 'Sending ' + IU(FsProgress1000(Outgoing[0].s) div 10) + '%'
       else if Incoming.active then Result := 'Receiving ' + IU(Trans[Incoming.t].permille div 10) + '%'
       else if Playing then Result := 'Playing';
    2: if RemoteOn then Result := 'The phone is showing';
    3: if not OutOk then begin if OutErr <> '' then begin Result := 'No sound'; col := COL_FAIL; end; end
       else if PhoneHeard <> 0 then Result := 'Phone heard ' + IU((GetTickCount - PhoneHeard) div 1000) + ' s ago'
       else begin Result := 'Phone not heard yet'; col := COL_GREY; end;
  end;
end;

procedure DrawHome(dc: HDC);
var i: Integer; rc: TRect; col: COLORREF; st: UnicodeString;
begin
  for i := 0 to NHOME - 1 do
  begin
    rc := HomeTile(i);
    if i = HomeSel then FillR(dc, rc, COL_NAVY) else FillR(dc, rc, COL_LINE);
    if i = HomeSel then FillR(dc, MkRect(rc.left + 2, rc.top + 2, rc.right - 2, rc.bottom - 2), COL_SEL)
    else FillR(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), COL_HI);
    Txt(dc, IU(i + 1), MkRect(rc.left + 10, rc.top + 8, rc.right - 8, rc.top + 26), fSmall, COL_GREY, DT_RIGHT or DT_SINGLELINE);
    Txt(dc, HOME_NAME[i], MkRect(rc.left + 10, rc.top + 7, rc.right - 8, rc.top + 26), fBig, COL_NAVY, DT_LEFT or DT_SINGLELINE);
    Txt(dc, HOME_WHAT[i], MkRect(rc.left + 10, rc.top + 27, rc.right - 8, rc.top + 42), fNorm, COL_TEXT, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    st := HomeState(i, col);
    Txt(dc, st, MkRect(rc.left + 10, rc.bottom - 20, rc.right - 8, rc.bottom - 4), fBold, col, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
  end;
end;

procedure Draw(dc: HDC);
var rc: TRect; s: UnicodeString; col: COLORREF;
begin
  if not Measured then begin MeasureMono(dc); Measured := True; end;
  FillR(dc, MkRect(0, 0, CW, CH), COL_PAPER);
  SetBkMode(dc, TRANSPARENT);
  FillR(dc, MkRect(0, 0, CW, TITLE_H), COL_NAVY);
  if Screen = SCR_HOME then
  begin
    Txt(dc, APPNAME {$ifndef wince} + '  (desktop test)'{$endif}, MkRect(8, 3, CW - 8, TITLE_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
    Txt(dc, 'version ' + VERSION + ' by ' + CREATOR, MkRect(200, 5, CW - 8, TITLE_H), fNorm, $E6D2C8, DT_RIGHT or DT_SINGLELINE);
  end
  else
  begin
    { a Home button, then the tool's name (or what the viewer shows) }
    rc := HomeBtnRect;
    FillR(dc, MkRect(rc.left, rc.top, rc.right, rc.bottom), $5A4836);
    Txt(dc, '< Home', MkRect(rc.left + 6, rc.top + 2, rc.right, rc.bottom), fBold, $FFFFFF, DT_LEFT or DT_SINGLELINE);
    if Viewing <> 0 then s := ViewTitle else s := SCR_NAME[Screen];
    Txt(dc, s, MkRect(rc.right + 10, 3, CW - 8, TITLE_H), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    Txt(dc, 'Alt+' + IU(Screen + 1), MkRect(300, 6, CW - 8, TITLE_H), fSmall, $C8B4A8, DT_RIGHT or DT_SINGLELINE);
  end;
  case Screen of
    SCR_HOME: DrawHome(dc);
    SCR_TYPE: DrawType(dc);
    SCR_FILES: DrawFiles(dc);
    SCR_REMOTE: DrawRemote(dc);
    SCR_LINK: DrawLink(dc);
    SCR_SETTINGS: DrawSettings(dc);
  end;
  { the status line }
  FillR(dc, MkRect(0, CH - STATUS_H, CW, CH), COL_HI);
  FillR(dc, MkRect(0, CH - STATUS_H, CW, CH - STATUS_H + 1), COL_LINE);
  s := StatusText(col);
  Txt(dc, s, MkRect(8, CH - STATUS_H + 2, CW - 8, CH), fBold, col, DT_LEFT or DT_SINGLELINE);
  if Screen = SCR_HOME then s := 'Arrows and Enter, or 1-6'
  else if Screen = SCR_REMOTE then s := 'Alt+Z zoom  Alt+U refresh  Alt+0 Home'
  else if Viewing <> 0 then s := 'Arrows scroll   Esc closes'
  else if (Screen = SCR_TYPE) then s := 'Alt+S Send   Alt+B Back   Alt+0 Home'
  else s := 'Esc or Alt+0: Home';
  Txt(dc, s, MkRect(8, CH - STATUS_H + 3, CW - 8, CH), fSmall, COL_GREY, DT_RIGHT or DT_SINGLELINE);
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
begin
  if Quitting then Exit;
  Quitting := True;
  SaveCfg;
  if Assigned(pKillTimer) then pKillTimer(hMain, TIMER_ID);
  Log('closing');
  AudioStop;
  LogTick(True);
  DestroyWindow(hMain);
end;

procedure SetScreen(i: Integer);
begin
  if (i <> SCR_HOME) and ((i < 0) or (i >= NSCR)) then Exit;
  if i < NSCR then HomeSel := i;
  if (Viewing <> 0) and (i <> SCR_FILES) then CloseViewer;
  Screen := i;
  if i = SCR_REMOTE then RemoteView;
  if i = SCR_FILES then ListFolder;
end;

{ a key for the phone (Send, Back...): on the Remote screen it goes as a remote key, so it works without the keyboard open }
procedure PhoneKey(code: Integer);
begin
  if (Screen = SCR_REMOTE) and RemoteOn then RemoteSimple(9, code) else TypeKey(code);
end;

{$ifndef wince}
{ desktop test only: SCREEN messages from files scr_0.bin, scr_1.bin... next to the program (tests/w3/ScreenDump.java) }
procedure DesktopScreenTest;
var k: Integer; d: TByteArr;
begin
  ScrInit(Scr);
  k := 0;
  while ReadWhole(ProgDir + 'scr_' + IU(k) + '.bin', 4096, d) do
  begin
    ScrApply(Scr, d, Length(d));
    Inc(k);
  end;
  RemoteOn := k > 0;
  Inc(ScreenMsgs, k);
end;
{$endif}

function OnAlt(vk: Integer): Boolean;
begin
  Result := True;
  case vk of
    Ord('1')..Ord('5'): SetScreen(vk - Ord('1'));
    Ord('0'), Ord('M'): SetScreen(SCR_HOME);
    Ord('T'): SetScreen(SCR_TYPE);
    Ord('F'): SetScreen(SCR_FILES);
    Ord('R'): SetScreen(SCR_REMOTE);
    Ord('L'): SetScreen(SCR_LINK);
    Ord('O'): SetScreen(SCR_SETTINGS);
    Ord('S'): PhoneKey(K_SEND);
    Ord('B'): PhoneKey(K_BACK);
    Ord('H'): PhoneKey(K_HOMESCREEN);
    Ord('W'): PhoneKey(K_RECENTS);
    Ord('N'): NewPage;
    Ord('K'): begin SetScreen(SCR_LINK); CheckLink; end;
    Ord('P'): begin SetScreen(SCR_LINK); StartPair(False); end;
    Ord('Z'): if Screen = SCR_REMOTE then begin if RemoteMode = 0 then RemoteMode := 1 else RemoteMode := 0; RemoteView; end;
    Ord('X'): if Screen = SCR_REMOTE then begin if RemoteMode = 2 then RemoteMode := 1 else RemoteMode := 2; RemoteView; end;
    Ord('U'): if Screen = SCR_REMOTE then RemoteSimple(5, 0);
    Ord('Q'): Leave;
    {$ifndef wince}
    Ord('D'): DesktopScreenTest;
    {$endif}
  else Result := False;
  end;
end;

procedure FileMove(d: Integer);
begin
  FileSel := FileSel + d;
  if FileSel >= NEntries then FileSel := NEntries - 1;
  if FileSel < 0 then FileSel := 0;
end;

procedure ViewerKey(vk: Integer);
var page: Integer;
begin
  if Viewing = 1 then
  begin
    page := ContentH - 20;
    case vk of
      VK_DOWN_: ViewY := ViewY + 40; VK_UP_: ViewY := ViewY - 40;
      VK_NEXT_: ViewY := ViewY + page; VK_PRIOR_: ViewY := ViewY - page;
      VK_HOME_: ViewY := 0; VK_END_: ViewY := ViewH;
    end;
    if ViewY > ViewH - ContentH then ViewY := ViewH - ContentH;
    if ViewY < 0 then ViewY := 0;
  end
  else if Viewing = 2 then
  begin
    page := ContentH div MonoH - 1;
    case vk of
      VK_DOWN_: Inc(ViewLine); VK_UP_: Dec(ViewLine);
      VK_NEXT_: ViewLine := ViewLine + page; VK_PRIOR_: ViewLine := ViewLine - page;
      VK_HOME_: ViewLine := 0; VK_END_: ViewLine := Length(ViewLines);
    end;
    if ViewLine > Length(ViewLines) - 1 - page then ViewLine := Length(ViewLines) - 1 - page;
    if ViewLine < 0 then ViewLine := 0;
  end;
end;

procedure OpenHome(i: Integer);
begin
  if i = NHOME - 1 then Leave else SetScreen(i);
end;

procedure OnKeyDown(vk: Integer);
var page: Integer;
begin
  if vk = VK_SHIFT_ then begin ShiftDown := True; Exit; end;
  if vk = VK_CONTROL_ then begin CtrlDown := True; Exit; end;
  if Screen = SCR_HOME then
  begin
    case vk of
      VK_LEFT_: if HomeSel > 0 then Dec(HomeSel);
      VK_RIGHT_: if HomeSel < NHOME - 1 then Inc(HomeSel);
      VK_UP_: if HomeSel >= 3 then Dec(HomeSel, 3);
      VK_DOWN_: if HomeSel < 3 then Inc(HomeSel, 3);
    end;
    Exit;
  end;
  if (Screen = SCR_FILES) and (Viewing <> 0) then begin ViewerKey(vk); Exit; end;
  case Screen of
    SCR_TYPE:
      case vk of
        VK_LEFT_: TypeKey(K_LEFT); VK_RIGHT_: TypeKey(K_RIGHT); VK_UP_: TypeKey(K_UP); VK_DOWN_: TypeKey(K_DOWN);
        VK_HOME_: TypeKey(K_HOME); VK_END_: TypeKey(K_END); VK_PRIOR_: TypeKey(K_PGUP); VK_NEXT_: TypeKey(K_PGDN);
        VK_DELETE_: TypeKey(K_DELETE);
      end;
    SCR_REMOTE:
      begin
        page := ContentH * 2 div 3;
        case vk of
          VK_UP_: RemoteScroll(0, -page div 2); VK_DOWN_: RemoteScroll(0, page div 2);
          VK_LEFT_: RemoteScroll(-CW div 3, 0); VK_RIGHT_: RemoteScroll(CW div 3, 0);
          VK_PRIOR_: RemoteScroll(0, -page); VK_NEXT_: RemoteScroll(0, page);
          VK_DELETE_: TypeKey(K_DELETE);
        end;
      end;
    SCR_FILES:
      case vk of
        VK_UP_: FileMove(-1); VK_DOWN_: FileMove(1);
        VK_PRIOR_: FileMove(-10); VK_NEXT_: FileMove(10);
        VK_HOME_: FileSel := 0; VK_END_: FileSel := NEntries - 1;
      end;
    SCR_SETTINGS:
      case vk of
        VK_UP_: if SetSel > 0 then Dec(SetSel);
        VK_DOWN_: if (SetSel < NSET - 1) and (Classic or (SetSel < 5)) then Inc(SetSel);
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
    8: TypeBackspace;
    9: if ShiftDown then TypeKey(K_SHIFT_TAB) else if Classic then TypeChar(' ') else TypeKey(K_TAB);
    13: TypeChar(#10);
    27: TypeKey(K_ESC);
    1: TypeKey(K_SELALL);
    3: TypeKey(K_COPY);
    22: TypeKey(K_PASTE);
    24: TypeKey(K_CUT);
    26: TypeKey(K_UNDO);
  else
    if c >= 32 then TypeChar(WideChar(c));
  end;
end;

procedure OnChar(c: Integer);
var p: array[0..0] of Byte; i: Integer;
begin
  if Screen = SCR_HOME then
  begin
    if (c = 13) or (c = 32) then OpenHome(HomeSel)
    else if (c >= Ord('1')) and (c <= Ord('6')) then OpenHome(c - Ord('1'))
    else if c > 32 then begin SetScreen(SCR_TYPE); TypingChar(c); end;   { just start typing }
    Exit;
  end;
  { Esc goes home from the screens where it means nothing to the phone }
  if (c = 27) and ((Screen = SCR_LINK) or (Screen = SCR_SETTINGS) or ((Screen = SCR_FILES) and (Viewing = 0) and not Playing)) then
  begin
    SetScreen(SCR_HOME); Exit;
  end;
  case Screen of
    SCR_TYPE: TypingChar(c);
    SCR_REMOTE:
      if (c = 13) and not RemoteOn then
      begin
        p[0] := 6; RemoteSend(p, 1); RemoteAsked := GetTickCount;
      end
      else TypingChar(c);
    SCR_FILES:
      if Viewing <> 0 then
      begin
        if (c = 27) or (c = 13) or (c = 8) then CloseViewer;
      end
      else
        case c of
          13: OpenEntry;
          8: if Length(Folder) > 1 then
             begin
               i := Length(Folder) - 1;
               while (i > 0) and (Folder[i] <> '\') do Dec(i);
               OpenFolder(Copy(Folder, 1, i));
             end;
          27: if Playing then begin StopPlaying; FileNote := 'Stopped.'; end;
          Ord('s'), Ord('S'):
            if (FileSel >= 0) and (FileSel < NEntries) and not Entries[FileSel].folder then
              SendFile(Folder + Entries[FileSel].name, Entries[FileSel].name);
          Ord('i'), Ord('I'): begin MakeInFolder; OpenFolder(InFolder); end;
          Ord('c'), Ord('C'): CancelSending;
          Ord('\'): OpenFolder('\');
        end;
    SCR_SETTINGS:
      if (c = 13) or (c = 32) then ChangeSetting(SetSel, 1);
    SCR_LINK:
      case c of
        Ord('p'), Ord('P'): StartPair(False);
        Ord('s'), Ord('S'): TestSpeaker;
        Ord('k'), Ord('K'), 13: CheckLink;
      end;
  end;
end;

var LastTapAt: LongWord = 0; LastTapSel: Integer = -1;

procedure OnTap(x, y: Integer);
var i, rows, top: Integer; rc: TRect;
begin
  if Screen = SCR_HOME then
  begin
    for i := 0 to NHOME - 1 do
    begin
      rc := HomeTile(i);
      if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then begin HomeSel := i; OpenHome(i); Exit; end;
    end;
    Exit;
  end;
  rc := HomeBtnRect;
  if (y < TITLE_H) and (x < rc.right + 4) then begin SetScreen(SCR_HOME); Exit; end;
  case Screen of
    SCR_TYPE:
      for i := 0 to TYPE_BTN - 1 do
      begin
        rc := TypeBtnRect(i);
        if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then
          case i of
            0: TypeKey(K_SEND); 1: TypeKey(K_BACK); 2: TypeKey(K_HOMESCREEN); 3: NewPage; 4: SetScreen(SCR_HOME);
          end;
      end;
    SCR_FILES:
      if Viewing <> 0 then CloseViewer
      else if x < 380 then
      begin
        top := TITLE_H + 2 + 18;
        rows := (y - top) div 15;
        if (y >= top) and (FileTop + rows < NEntries) then
        begin
          i := FileTop + rows;
          if (i = LastTapSel) and (GetTickCount - LastTapAt < 600) then begin FileSel := i; OpenEntry; LastTapSel := -1; end
          else begin FileSel := i; LastTapSel := i; LastTapAt := GetTickCount; end;
        end;
      end;
    SCR_SETTINGS:
      begin
        i := (y - TITLE_H - 6) div 18;
        if (i >= 0) and (i < NSET) and (Classic or (i < 6)) then begin if i = SetSel then ChangeSetting(i, 1); SetSel := i; end;
      end;
    SCR_LINK:
      for i := 0 to 2 do
      begin
        rc := LinkBtn(i);
        if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then
          case i of 0: StartPair(False); 1: TestSpeaker; 2: CheckLink; end;
      end;
    SCR_REMOTE:
      if RemoteOn and (y >= TITLE_H) and (y < CH - STATUS_H) then
      begin
        PenDown := True; PenX := x; PenY := y - TITLE_H; PenAt := GetTickCount;
      end;
  end;
end;

procedure OnPenUp(x, y: Integer);
var held: LongWord;
begin
  if not PenDown then Exit;
  PenDown := False;
  y := y - TITLE_H;
  held := GetTickCount - PenAt;
  if (Abs(x - PenX) > 12) or (Abs(y - PenY) > 12) then RemoteTouch(3, PenX, PenY, x, y)
  else if held > 600 then RemoteTouch(2, PenX, PenY, 0, 0)
  else RemoteTouch(1, PenX, PenY, 0, 0);
end;

function WndProc(wnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; API;
begin
  Result := 0;
  case msg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_AUDIO: begin Pump; if Screen = SCR_LINK then InvalidateRect(wnd, nil, False); end;
    WM_TIMER: Pump;
    WM_LBUTTONDOWN:
      begin
        OnTap(SmallInt(lp and $FFFF), SmallInt((lp shr 16) and $FFFF));
        if not Quitting then InvalidateRect(wnd, nil, False);
      end;
    WM_LBUTTONUP:
      if PenDown then begin OnPenUp(SmallInt(lp and $FFFF), SmallInt((lp shr 16) and $FFFF)); InvalidateRect(wnd, nil, False); end;
    WM_KEYDOWN:
      begin
        OnKeyDown(wp);
        if not Quitting then InvalidateRect(wnd, nil, False);
      end;
    WM_KEYUP: OnKeyUp(wp);
    WM_CHAR:
      begin
        OnChar(wp);
        if not Quitting then InvalidateRect(wnd, nil, False);
      end;
    WM_SYSKEYDOWN:
      if OnAlt(wp) then begin if not Quitting then InvalidateRect(wnd, nil, False); end
      else Result := DefWindowProcW(wnd, msg, wp, lp);
    WM_SYSCHAR: ;                                  { handled as WM_SYSKEYDOWN; no beep }
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
begin
  ReturnNilIfGrowHeapFails := True;
  AppInst := GetModuleHandleW(nil);
  InitializeCriticalSection(ClassicLock);
  TsInit(Ts, Byte(GetTickCount));                    { a new document id each start }
  SnInit(ClassicSnd, Byte(GetTickCount + 77));
  ScrInit(Scr);
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
  fSmall := MkFont(11, 400, 'Tahoma');
  fMono := MkFont(14, 400, 'Courier New');
  ResolveAll;
  FindDirs;
  LoadCfg;
  MakeInFolder;
  Folder := InFolder;
  LogStart(ProgDir + 'Whisper Tools log.txt', VERSION);
  Log('settings: microphone rate ' + LI(InRate100 div 100) + ' (source ' + LI(RateSource) + ': 0 = not known yet), silent loudness ' + LI(SilentPeak)
    + ' (source ' + LI(LevelSource) + '), classic ' + LI(Ord(Classic)) + ', wide ' + LI(Ord(WideSilent)) + ', fast files '
    + LI(Ord(FastFiles)) + ', fast level ' + LI(FastLevel) + ', typing on fast ' + LI(Ord(TypingOnFast)) + ', fast always ' + LI(Ord(FastAlways)));

  if not SystemParametersInfoW(SPI_GETWORKAREA, 0, @wa, 0) then wa := MkRect(0, 0, 640, 214);
  {$ifndef wince}
  wa := MkRect(40, 40, 680, 254);
  {$endif}
  CW := wa.right - wa.left; CH := wa.bottom - wa.top;
  hMain := CreateWindowExW(0, PWideChar(CLSNAME), PWideChar(APPNAME), WS_POPUP or WS_VISIBLE,
    wa.left, wa.top, CW, CH, 0, 0, AppInst, nil);
  if hMain = 0 then Halt(2);
  ScreenDC := CreateCompatibleDC(0);
  ShowWindow(hMain, SW_SHOW);
  UpdateWindow(hMain);
  SetForegroundWindow(hMain);
  ListFolder;
  NotifyWnd := hMain; NotifyMsg := WM_AUDIO;
  ListenFast := False;
  AudioStart;
  if Assigned(pSetTimer) then pSetTimer(hMain, TIMER_ID, TIMER_MS, nil);
  SayHello(False);
  while GetMessageW(@m, 0, 0, 0) do
  begin
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end.
