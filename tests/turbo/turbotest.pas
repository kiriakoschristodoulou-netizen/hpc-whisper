program turbotest;
{ HPC Whisper Turbo Test, for the handheld. Three measurements for a much
  faster inaudible link:

  1. Play test (P): plays turbotest.wav (next to this program) while the
     phone records it with HPC Whisper's "Record 30 seconds". The recording
     shows how much the inaudible band can carry from this handheld.
  2. Microphone test (M): records 25 s from the handheld's microphone into
     mictest.wav while the phone plays phone-test.wav. Shows what the
     handheld can hear (the phone -> handheld direction).
  3. Speed test (S): how fast this processor makes and analyses multi-tone
     sound.

  Everything found is also written to turbotest.txt next to the program.
  Every sound function is looked up by name at run time, so a missing one
  is reported instead of stopping the program. Created by Kyriakos
  Christodoulou. }
{$mode objfpc}{$H+}
{$APPTYPE GUI}
{$macro on}
{$ifdef wince}{$define API:=cdecl}{$else}{$define API:=stdcall}{$endif}
{$packrecords c}
{$R turbotest.res}
uses Windows;

{$I sections.inc}

const
  VERSION = '1.0';
  CLSNAME: UnicodeString = 'HPCTurboTest';
  APPNAME: UnicodeString = 'HPC Whisper Turbo Test';
  WM_UPDATE = WM_APP + 1;
  PLAY_BUF = 11025;                     { samples per buffer (0.25 s) }
  NPB = 4;
  MIC_SECONDS = 25;
  MIC_CHUNK_MS = 500;
  MAXCHUNK = MIC_SECONDS * 1000 div MIC_CHUNK_MS;

  COL_NAVY = $36251B; COL_TEXT = $3C2D23; COL_GREY = $8C8278; COL_HI = $F6EEE8;
  COL_GOOD = $3C8200; COL_BAD = $2828BE;
  BTN_LABEL: array[0..3] of UnicodeString = ('1  Play test', '2  Microphone test', '3  Speed test', 'Exit');
  BTN_KEY: array[0..3] of UnicodeString = ('P', 'M', 'S', 'Q');

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
  THandleW = THandle;
  TCaps = record                        { WAVEOUTCAPS / WAVEINCAPS up to the name }
    mid, pid: Word;
    ver: DWORD;
    name: array[0..31] of WideChar;
    rest: array[0..15] of DWORD;
  end;

  TNumDevs = function: UINT; API;
  TGetCaps = function(id: UINT; caps: Pointer; size: UINT): UINT; API;
  TOpen = function(out h: THandleW; id: UINT; fmt: Pointer; cb, inst, flags: DWORD): UINT; API;
  THdrFn = function(h: THandleW; hdr: PWaveHdr; size: UINT): UINT; API;
  THandleFn = function(h: THandleW): UINT; API;
  TSetVol = function(h: THandleW; vol: DWORD): UINT; API;
  TGetVol = function(h: THandleW; vol: PDWORD): UINT; API;
  TGetModuleFileNameW = function(h: HMODULE; buf: PWideChar; n: DWORD): DWORD; API;

var
  pOutNum: TNumDevs; pOutCaps: TGetCaps; pOutOpen: TOpen; pOutPrep, pOutUnprep, pOutWrite: THdrFn;
  pOutReset, pOutClose: THandleFn; pSetVol: TSetVol; pGetVol: TGetVol;
  pInNum: TNumDevs; pInCaps: TGetCaps; pInOpen: TOpen; pInPrep, pInUnprep, pInAdd: THdrFn;
  pInStart, pInStop, pInReset, pInClose: THandleFn;
  pGetModuleFileNameW: TGetModuleFileNameW;
  hCore: HMODULE = 0;
  Missing: UnicodeString = '';
  MissOut: UnicodeString = '';
  MissIn: UnicodeString = '';

  AppInst: HINST; hMain: HWND; CW, CH: Integer;
  fNorm, fBold, fBig: HFONT;
  Folder: UnicodeString = '';
  Busy: Boolean = False;
  StopAsked: Boolean = False;
  Mode: Integer = -1;                   { 0 play, 1 microphone, 2 speed }
  Line1: UnicodeString = 'Choose a test.';
  Line2: UnicodeString = '';
  Line3: UnicodeString = '';
  Col1: COLORREF = COL_TEXT;
  Progress: Integer = 0;                { 0..1000 }
  hThread: THandle = 0;

  PlayBuf: array[0..NPB - 1, 0..PLAY_BUF - 1] of SmallInt;
  PlayHdr: array[0..NPB - 1] of TWaveHdr;
  MicHdr: array[0..MAXCHUNK - 1] of TWaveHdr;

{ ---------- helpers ---------- }

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

function MkFont(h, weight: Integer): HFONT;
var lf: LOGFONTW; i: Integer; face: UnicodeString;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -h; lf.lfWeight := weight; lf.lfCharSet := DEFAULT_CHARSET;
  face := 'Tahoma';
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

function Find(const fn: ShortString; must: Boolean): Pointer;
begin
  {$ifdef wince}
  Result := FindIn(hCore, fn);
  {$else}
  Result := FindIn(LoadLibraryW('winmm.dll'), fn);
  if Result = nil then Result := FindIn(LoadLibraryW('kernel32.dll'), fn);
  {$endif}
  if (Result = nil) and must then
  begin
    if Missing <> '' then Missing := Missing + ', ';
    Missing := Missing + US(fn);
  end;
end;

procedure ResolveAll;
begin
  {$ifdef wince}
  hCore := LoadLibraryW('coredll.dll');
  if hCore = 0 then hCore := GetModuleHandleW('coredll.dll');
  {$endif}
  pOutNum := TNumDevs(Find('waveOutGetNumDevs', True));
  pOutCaps := TGetCaps(Find('waveOutGetDevCaps', False));
  if not Assigned(pOutCaps) then pOutCaps := TGetCaps(Find('waveOutGetDevCapsW', False));
  pOutOpen := TOpen(Find('waveOutOpen', True));
  pOutPrep := THdrFn(Find('waveOutPrepareHeader', True));
  pOutUnprep := THdrFn(Find('waveOutUnprepareHeader', True));
  pOutWrite := THdrFn(Find('waveOutWrite', True));
  pOutReset := THandleFn(Find('waveOutReset', True));
  pOutClose := THandleFn(Find('waveOutClose', True));
  pSetVol := TSetVol(Find('waveOutSetVolume', True));
  pGetVol := TGetVol(Find('waveOutGetVolume', True));
  MissOut := Missing; Missing := '';
  pInNum := TNumDevs(Find('waveInGetNumDevs', True));
  pInCaps := TGetCaps(Find('waveInGetDevCaps', False));
  if not Assigned(pInCaps) then pInCaps := TGetCaps(Find('waveInGetDevCapsW', False));
  pInOpen := TOpen(Find('waveInOpen', True));
  pInPrep := THdrFn(Find('waveInPrepareHeader', True));
  pInUnprep := THdrFn(Find('waveInUnprepareHeader', True));
  pInAdd := THdrFn(Find('waveInAddBuffer', True));
  pInStart := THandleFn(Find('waveInStart', True));
  pInStop := THandleFn(Find('waveInStop', True));
  pInReset := THandleFn(Find('waveInReset', True));
  pInClose := THandleFn(Find('waveInClose', True));
  pGetModuleFileNameW := TGetModuleFileNameW(Find('GetModuleFileNameW', False));
  MissIn := Missing; Missing := '';
end;

procedure FindFolder;
var buf: array[0..259] of WideChar; n, i, cut: Integer;
begin
  Folder := '';
  if not Assigned(pGetModuleFileNameW) then Exit;
  n := pGetModuleFileNameW(0, @buf[0], 259);
  cut := 0;
  for i := 0 to n - 1 do if buf[i] = '\' then cut := i + 1;
  SetLength(Folder, cut);
  for i := 0 to cut - 1 do Folder[i + 1] := buf[i];
end;

{ ---------- the results file ---------- }

procedure Log(const s: UnicodeString);
var h: THandle; b: array[0..511] of Byte; i, n: Integer; got: DWORD; p: UnicodeString;
begin
  p := Folder + 'turbotest.txt';
  h := CreateFileW(PWideChar(p), GENERIC_WRITE, FILE_SHARE_READ, nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  SetFilePointer(h, 0, nil, FILE_END);
  n := Length(s); if n > 500 then n := 500;
  for i := 1 to n do if Ord(s[i]) < 128 then b[i - 1] := Ord(s[i]) else b[i - 1] := Ord('?');
  b[n] := 13; b[n + 1] := 10;
  got := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, n + 2, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
end;

function CapsName(fn: TGetCaps; id: UINT): UnicodeString;
var c: TCaps; i: Integer;
begin
  Result := '?';
  if not Assigned(fn) then Exit;
  FillChar(c, SizeOf(c), 0);
  if fn(id, @c, SizeOf(c)) <> 0 then Exit;
  Result := '';
  i := 0;
  while (i < 32) and (c.name[i] <> #0) do begin Result := Result + c.name[i]; Inc(i); end;
end;

procedure Say(const a, b, c: UnicodeString; col: COLORREF);
begin
  Line1 := a; Line2 := b; Line3 := c; Col1 := col;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

{ ---------- 1. play test ---------- }

function PlayThread(param: Pointer): DWORD; API;
var h: THandle; fmt: TWaveFormat; wo: THandleW; i, k, n, sec, curSec: Integer; got: DWORD;
    hdr: array[0..11] of Byte; chunk: array[0..7] of Byte; size, played, total: LongInt;
    playing: array[0..NPB - 1] of Boolean; oldVol, v: DWORD; haveVol, eof: Boolean; t0: DWORD;
    p: UnicodeString;
begin
  Result := 0;
  p := Folder + 'turbotest.wav';
  h := CreateFileW(PWideChar(p), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    Say('turbotest.wav was not found.', 'It must be in the same folder as this program.', '', COL_BAD);
    Busy := False; Exit;
  end;
  { RIFF header, then the chunks until "data" }
  ReadFile(h, {$ifdef wince}@hdr{$else}hdr{$endif}, 12, {$ifdef wince}@got{$else}got{$endif}, nil);
  size := 0;
  repeat
    got := 0;
    ReadFile(h, {$ifdef wince}@chunk{$else}chunk{$endif}, 8, {$ifdef wince}@got{$else}got{$endif}, nil);
    if got < 8 then Break;
    size := chunk[4] or (chunk[5] shl 8) or (chunk[6] shl 16) or (LongInt(chunk[7]) shl 24);
    if (chunk[0] = Ord('d')) and (chunk[1] = Ord('a')) and (chunk[2] = Ord('t')) and (chunk[3] = Ord('a')) then Break;
    SetFilePointer(h, size, nil, FILE_CURRENT);
    size := 0;
  until False;
  if size <= 0 then
  begin
    Say('turbotest.wav could not be read.', '', '', COL_BAD);
    CloseHandle(h); Busy := False; Exit;
  end;
  total := size div 2;
  FillChar(fmt, SizeOf(fmt), 0);
  fmt.tag := 1; fmt.channels := 1; fmt.rate := 44100; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := 88200;
  if pOutOpen(wo, UINT(-1), @fmt, 0, 0, 0) <> 0 then
  begin
    Say('The sound device would not open at 44100 samples/s.', '', '', COL_BAD);
    CloseHandle(h); Busy := False; Exit;
  end;
  haveVol := pGetVol(0, @oldVol) = 0;
  pSetVol(0, $FFFFFFFF); pSetVol(wo, $FFFFFFFF);
  Log('Play test: device "' + CapsName(pOutCaps, 0) + '", ' + IU(total div 441) + ' centiseconds of sound');
  for i := 0 to NPB - 1 do playing[i] := False;
  played := 0; k := 0; eof := False; curSec := -1; t0 := GetTickCount;
  while not StopAsked do
  begin
    if playing[k] then
    begin
      while ((PlayHdr[k].flags and 1) = 0) and not StopAsked do Sleep(5);
      pOutUnprep(wo, @PlayHdr[k], SizeOf(TWaveHdr));
      playing[k] := False;
    end;
    if StopAsked then Break;
    if not eof then
    begin
      got := 0;
      ReadFile(h, {$ifdef wince}@PlayBuf[k][0]{$else}PlayBuf[k][0]{$endif}, PLAY_BUF * 2, {$ifdef wince}@got{$else}got{$endif}, nil);
      n := got div 2;
      if n < PLAY_BUF then eof := True;
      if n > 0 then
      begin
        FillChar(PlayHdr[k], SizeOf(TWaveHdr), 0);
        PlayHdr[k].data := @PlayBuf[k][0];
        PlayHdr[k].len := n * 2;
        if pOutPrep(wo, @PlayHdr[k], SizeOf(TWaveHdr)) = 0 then
          if pOutWrite(wo, @PlayHdr[k], SizeOf(TWaveHdr)) = 0 then playing[k] := True;
        played := played + n;
      end;
    end;
    { what is sounding now (about a buffer behind what was written) }
    v := GetTickCount - t0;
    sec := -1;
    for i := 0 to NSEC - 1 do if LongInt(v) >= SEC_MS[i] then sec := i;
    if sec <> curSec then
    begin
      curSec := sec;
      if sec >= 0 then Say('Playing: ' + SEC_NAME[sec], 'Part ' + IU(sec + 1) + ' of ' + IU(NSEC) +
          '. Note if you hear anything, and in which part.', 'Keep the phone recording, about 30 cm away.', COL_GOOD);
    end;
    Progress := LongInt(Int64(v) * 1000 div TEST_MS);
    if Progress > 1000 then Progress := 1000;
    PostMessageW(hMain, WM_UPDATE, 0, 0);
    if eof then
    begin
      { wait for the last buffers }
      for i := 0 to NPB - 1 do
        if playing[i] then
        begin
          while ((PlayHdr[i].flags and 1) = 0) and not StopAsked do Sleep(10);
          pOutUnprep(wo, @PlayHdr[i], SizeOf(TWaveHdr));
          playing[i] := False;
        end;
      Break;
    end;
    k := (k + 1) mod NPB;
  end;
  pOutReset(wo);
  for i := 0 to NPB - 1 do if playing[i] then pOutUnprep(wo, @PlayHdr[i], SizeOf(TWaveHdr));
  pOutClose(wo);
  if haveVol then pSetVol(0, oldVol);
  CloseHandle(h);
  Progress := 1000;
  if StopAsked then Say('Play test stopped.', '', '', COL_TEXT)
  else
  begin
    Say('Play test done. Stop the recording on the phone.',
        'Send the recording (from Downloads) as a file, and say whether you heard anything.', '', COL_GOOD);
    Log('Play test finished in ' + IU(GetTickCount - t0) + ' ms');
  end;
  Busy := False;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

{ ---------- 2. microphone test ---------- }

procedure WriteWav(const path: UnicodeString; data: PSmallInt; n: LongInt; rate: LongInt);
var h: THandle; b: array[0..43] of Byte; got: DWORD;
  procedure P32(at: Integer; v: LongInt);
  begin b[at] := v and 255; b[at + 1] := (v shr 8) and 255; b[at + 2] := (v shr 16) and 255; b[at + 3] := (v shr 24) and 255; end;
  procedure PS(at: Integer; const s: ShortString);
  var i: Integer; begin for i := 1 to 4 do b[at + i - 1] := Ord(s[i]); end;
begin
  FillChar(b, SizeOf(b), 0);
  PS(0, 'RIFF'); P32(4, 36 + n * 2); PS(8, 'WAVE'); PS(12, 'fmt '); P32(16, 16);
  b[20] := 1; b[22] := 1; P32(24, rate); P32(28, rate * 2); b[32] := 2; b[34] := 16;
  PS(36, 'data'); P32(40, n * 2);
  h := CreateFileW(PWideChar(path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  got := 0;
  WriteFile(h, {$ifdef wince}@b{$else}b{$endif}, 44, {$ifdef wince}@got{$else}got{$endif}, nil);
  WriteFile(h, {$ifdef wince}data{$else}data^{$endif}, n * 2, {$ifdef wince}@got{$else}got{$endif}, nil);
  CloseHandle(h);
end;

function MicThread(param: Pointer): DWORD; API;
const RATES: array[0..2] of LongInt = (44100, 22050, 11025);
var fmt: TWaveFormat; wi: THandleW; i, j, r, rate, chunkN, nChunk, done, peak, v: LongInt;
    mem: PSmallInt; ok: Boolean; t0: DWORD; p: UnicodeString; s: PSmallInt;
begin
  Result := 0;
  if pInNum() = 0 then
  begin
    Say('No microphone (recording device) was found.', '', '', COL_BAD);
    Log('Microphone test: no recording device');
    Busy := False; Exit;
  end;
  rate := 0;
  for i := 0 to 2 do
  begin
    FillChar(fmt, SizeOf(fmt), 0);
    fmt.tag := 1; fmt.channels := 1; fmt.rate := RATES[i]; fmt.bits := 16; fmt.align := 2; fmt.bytesPerSec := RATES[i] * 2;
    r := pInOpen(wi, UINT(-1), @fmt, 0, 0, 0);
    Log('Microphone at ' + IU(RATES[i]) + ' samples/s: ' + IU(r) + ' (0 = opened)');
    if r = 0 then begin rate := RATES[i]; Break; end;
  end;
  if rate = 0 then
  begin
    Say('The microphone would not open at 44100, 22050 or 11025 samples/s.', '', '', COL_BAD);
    Busy := False; Exit;
  end;
  Log('Microphone: device "' + CapsName(pInCaps, 0) + '", recording at ' + IU(rate));
  chunkN := rate * MIC_CHUNK_MS div 1000;
  nChunk := MAXCHUNK;
  GetMem(mem, chunkN * nChunk * 2);
  if mem = nil then
  begin
    Say('Not enough memory to record.', '', '', COL_BAD);
    pInClose(wi); Busy := False; Exit;
  end;
  ok := True;
  for i := 0 to nChunk - 1 do
  begin
    FillChar(MicHdr[i], SizeOf(TWaveHdr), 0);
    MicHdr[i].data := Pointer(PtrUInt(mem) + PtrUInt(i * chunkN * 2));
    MicHdr[i].len := chunkN * 2;
    if pInPrep(wi, @MicHdr[i], SizeOf(TWaveHdr)) <> 0 then ok := False
    else if pInAdd(wi, @MicHdr[i], SizeOf(TWaveHdr)) <> 0 then ok := False;
  end;
  if not ok then Log('Microphone: some buffers were refused');
  pInStart(wi);
  t0 := GetTickCount;
  done := 0; peak := 0;
  while (done < nChunk) and not StopAsked do
  begin
    Sleep(100);
    while (done < nChunk) and ((MicHdr[done].flags and 1) <> 0) do
    begin
      s := PSmallInt(MicHdr[done].data);
      for j := 0 to LongInt(MicHdr[done].recorded div 2) - 1 do
      begin
        v := s[j]; if v < 0 then v := -v;
        if v > peak then peak := v;
      end;
      Inc(done);
    end;
    Progress := done * 1000 div nChunk;
    Say('Recording: ' + IU(done * MIC_SECONDS div nChunk) + ' of ' + IU(MIC_SECONDS) + ' s',
        'Play phone-test.wav on the phone now, its speaker towards the handheld.',
        'Loudest so far: ' + IU(peak * 100 div 32768) + '% of full scale', COL_GOOD);
  end;
  pInStop(wi); pInReset(wi);
  for i := 0 to nChunk - 1 do pInUnprep(wi, @MicHdr[i], SizeOf(TWaveHdr));
  pInClose(wi);
  p := Folder + 'mictest.wav';
  WriteWav(p, mem, LongInt(done) * chunkN, rate);
  FreeMem(mem);
  Log('Microphone test: ' + IU(done * MIC_CHUNK_MS) + ' ms recorded at ' + IU(rate) + ', loudest ' + IU(peak) + ' of 32767');
  Progress := 1000;
  Say('Microphone test done: saved mictest.wav (' + IU(rate) + ' samples/s).',
      'Copy mictest.wav and turbotest.txt from this folder and send them.',
      'Loudest: ' + IU(peak * 100 div 32768) + '% of full scale', COL_GOOD);
  Busy := False;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

{ ---------- 3. speed test ---------- }

const
  TAB_N = 4096;
var
  SinTab: array[0..TAB_N - 1] of SmallInt;

procedure MakeTable;
var i, q: Integer; x, y, c, s, t: Int64;
begin
  { a sine table without floating point: a rotating vector, 2^30 fixed point }
  c := 1073740560; s := 1647099;                    { cos and sin of 2 pi / 4096 }
  x := 1073741824; y := 0;
  for i := 0 to TAB_N - 1 do
  begin
    SinTab[i] := SmallInt(y div 35791);              { about 30000 at the top }
    t := (x * c - y * s) div 1073741824;
    y := (x * s + y * c) div 1073741824;
    x := t;
  end;
  q := 0;
end;

function SpeedThread(param: Pointer): DWORD; API;
var t0, tSynth, tFft: DWORD; i, k, c, n: LongInt; ph, st: array[0..31] of LongWord; acc: LongInt;
    buf: array[0..4409] of SmallInt; re, im: array[0..255] of LongInt; j, m, half, step, w, a, b, tr, ti: LongInt;
begin
  Result := 0;
  Say('Speed test running...', '', '', COL_TEXT);
  MakeTable;
  { 1. making 1 s of sound from 32 carriers at once (table lookups, whole numbers) }
  for c := 0 to 31 do begin ph[c] := c * 123456789; st[c] := LongWord((Int64(18100 + c * 100) shl 32) div 44100); end;
  t0 := GetTickCount;
  for k := 0 to 9 do
    for i := 0 to 4409 do
    begin
      acc := 0;
      for c := 0 to 31 do
      begin
        acc := acc + SinTab[ph[c] shr 20];
        ph[c] := ph[c] + st[c];
      end;
      buf[i] := SmallInt(acc div 32);
    end;
  tSynth := GetTickCount - t0;
  { 2. 256-point fixed-point FFTs, 100 of them (what listening on the handheld would need) }
  t0 := GetTickCount;
  for n := 1 to 100 do
  begin
    for i := 0 to 255 do begin re[i] := buf[i]; im[i] := 0; end;
    j := 0;
    for i := 0 to 254 do
    begin
      if i < j then begin tr := re[i]; re[i] := re[j]; re[j] := tr; end;
      m := 128;
      while (m >= 1) and (j >= m) do begin j := j - m; m := m div 2; end;
      j := j + m;
    end;
    half := 1;
    while half < 256 do
    begin
      step := 4096 div (half * 2);
      for i := 0 to half - 1 do
      begin
        w := i * step;
        k := i;
        while k < 256 do
        begin
          a := k + half;
          tr := (re[a] * SinTab[(w + 1024) and 4095] + im[a] * SinTab[w]) div 32768;
          ti := (im[a] * SinTab[(w + 1024) and 4095] - re[a] * SinTab[w]) div 32768;
          b := k;
          re[a] := re[b] - tr; im[a] := im[b] - ti;
          re[b] := re[b] + tr; im[b] := im[b] + ti;
          k := k + half * 2;
        end;
      end;
      half := half * 2;
    end;
  end;
  tFft := GetTickCount - t0;
  Log('Speed test: 32 carriers, 1 s of sound made in ' + IU(tSynth) + ' ms; 100 FFTs of 256 points in ' + IU(tFft) + ' ms');
  Say('Speed test done.',
      'Making 1 s of 32-carrier sound took ' + IU(tSynth) + ' ms (less than 1000 = fast enough).',
      '100 analyses (256-point FFT) took ' + IU(tFft) + ' ms. Saved in turbotest.txt.', COL_GOOD);
  Progress := 1000;
  Busy := False;
  PostMessageW(hMain, WM_UPDATE, 0, 0);
end;

{ ---------- the window ---------- }

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
  r2 := rc; br := CreateSolidBrush(col); FillRect(dc, r2, br); DeleteObject(br);
end;

function BtnRect(i: Integer): TRect;
begin
  Result := MkRect(8, 28 + i * 44, 200, 28 + i * 44 + 38);
end;

procedure Draw(dc: HDC);
var i: Integer; rc: TRect; bg: COLORREF;
begin
  FillR(dc, MkRect(0, 0, CW, CH), $FFFFFF);
  SetBkMode(dc, TRANSPARENT);
  FillR(dc, MkRect(0, 0, CW, 22), COL_NAVY);
  Txt(dc, APPNAME + ' ' + VERSION, MkRect(8, 3, 400, 22), fBig, $FFFFFF, DT_LEFT or DT_SINGLELINE);
  Txt(dc, 'by Kyriakos Christodoulou', MkRect(300, 5, CW - 8, 22), fNorm, $E6D2C8, DT_RIGHT or DT_SINGLELINE);
  for i := 0 to 3 do
  begin
    rc := BtnRect(i);
    if Busy and (i = Mode) then bg := $D8EED0 else bg := COL_HI;
    FillR(dc, rc, COL_NAVY);
    FillR(dc, MkRect(rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1), bg);
    Txt(dc, BTN_LABEL[i], MkRect(rc.left + 10, rc.top + 11, rc.right - 8, rc.bottom), fBold, COL_NAVY, DT_LEFT or DT_SINGLELINE);
    Txt(dc, BTN_KEY[i], MkRect(rc.left + 10, rc.top + 11, rc.right - 10, rc.bottom), fNorm, COL_GREY, DT_RIGHT or DT_SINGLELINE);
  end;
  begin
    Txt(dc, Line1, MkRect(216, 30, CW - 8, 64), fBold, Col1, DT_LEFT or DT_WORDBREAK);
    Txt(dc, Line2, MkRect(216, 66, CW - 8, 112), fNorm, COL_TEXT, DT_LEFT or DT_WORDBREAK);
    Txt(dc, Line3, MkRect(216, 114, CW - 8, 150), fNorm, COL_GREY, DT_LEFT or DT_WORDBREAK);
  end;
  if Busy or (Progress > 0) then
  begin
    FillR(dc, MkRect(216, 158, CW - 8, 168), $E0D8D0);
    FillR(dc, MkRect(216, 158, 216 + (CW - 224) * Progress div 1000, 168), COL_GOOD);
  end;
  if Busy then Txt(dc, 'Press Space to stop.', MkRect(216, 174, CW - 8, 192), fNorm, COL_GREY, DT_LEFT or DT_SINGLELINE)
  else Txt(dc, 'Results are also saved in turbotest.txt next to this program.', MkRect(216, 174, CW - 8, 192), fNorm, COL_GREY, DT_LEFT or DT_SINGLELINE);
end;

procedure Paint(wnd: HWND);
var ps: TPaintStruct; dc, mdc: HDC; bmp: HBITMAP; old: HGDIOBJ; rc: TRect;
begin
  dc := BeginPaint(wnd, ps);
  GetClientRect(wnd, rc); CW := rc.right; CH := rc.bottom;
  mdc := CreateCompatibleDC(dc);
  bmp := CreateCompatibleBitmap(dc, CW, CH);
  old := SelectObject(mdc, bmp);
  Draw(mdc);
  BitBlt(dc, 0, 0, CW, CH, mdc, 0, 0, SRCCOPY);
  SelectObject(mdc, old); DeleteObject(bmp); DeleteDC(mdc);
  EndPaint(wnd, ps);
end;

procedure Start(m: Integer);
var tid: DWORD;
begin
  if Busy then Exit;
  if (m = 0) and (MissOut <> '') then begin Say('This handheld cannot play sound this way.', 'Missing: ' + MissOut, '', COL_BAD); Exit; end;
  if (m = 1) and (MissIn <> '') then begin Say('This handheld cannot record sound this way.', 'Missing: ' + MissIn, '', COL_BAD); Exit; end;
  Busy := True; StopAsked := False; Mode := m; Progress := 0;
  case m of
    0: begin
         Say('Starting...', 'Start "Record 30 seconds" in the HPC Whisper app on the phone first.', '', COL_TEXT);
         hThread := CreateThread(nil, 0, @PlayThread, nil, 0, tid);
       end;
    1: begin
         Say('Opening the microphone...', '', '', COL_TEXT);
         hThread := CreateThread(nil, 0, @MicThread, nil, 0, tid);
       end;
    2: hThread := CreateThread(nil, 0, @SpeedThread, nil, 0, tid);
  end;
  if hThread = 0 then begin Busy := False; Say('Could not start.', '', '', COL_BAD); end
  else if m = 0 then SetThreadPriority(hThread, THREAD_PRIORITY_ABOVE_NORMAL);
end;

procedure Leave;
var n: Integer;
begin
  StopAsked := True;
  n := 0;
  if hThread <> 0 then
    while Busy and (n < 40) do begin Sleep(100); Inc(n); end;
  DestroyWindow(hMain);
end;

function WndProc(wnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; API;
var i, x, y: Integer; rc: TRect;
begin
  Result := 0;
  case msg of
    WM_PAINT: Paint(wnd);
    WM_ERASEBKGND: Result := 1;
    WM_UPDATE: InvalidateRect(wnd, nil, False);
    WM_LBUTTONDOWN:
      begin
        x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
        for i := 0 to 3 do
        begin
          rc := BtnRect(i);
          if (x >= rc.left) and (x < rc.right) and (y >= rc.top) and (y < rc.bottom) then
            if i = 3 then Leave else Start(i);
        end;
        InvalidateRect(wnd, nil, False);
      end;
    WM_CHAR:
      begin
        case wp of
          Ord('p'), Ord('P'), Ord('1'): Start(0);
          Ord('m'), Ord('M'), Ord('2'): Start(1);
          Ord('s'), Ord('S'), Ord('3'): Start(2);
          32: StopAsked := True;
          Ord('q'), Ord('Q'), 27: Leave;
        end;
        InvalidateRect(wnd, nil, False);
      end;
    WM_CLOSE: Leave;
    WM_DESTROY: if wnd = hMain then PostQuitMessage(0);
  else
    Result := DefWindowProcW(wnd, msg, wp, lp);
  end;
end;

var
  wc: WNDCLASSW; m: MSG; wa: TRect;
begin
  AppInst := GetModuleHandleW(nil);
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
  fNorm := MkFont(12, 400); fBold := MkFont(12, 700); fBig := MkFont(14, 700);
  ResolveAll;
  FindFolder;
  Line1 := 'Choose a test. Each one takes under half a minute.';
  Line2 := 'Play test: the phone records this handheld. Microphone test: this handheld records the phone.';
  Line3 := 'Speed test: how fast this processor is for the new sound.';
  Log('--- HPC Whisper Turbo Test ' + VERSION);
  if not SystemParametersInfoW(SPI_GETWORKAREA, 0, @wa, 0) then wa := MkRect(0, 0, 640, 214);
  {$ifndef wince}
  wa := MkRect(40, 40, 680, 254);
  {$endif}
  CW := wa.right - wa.left; CH := wa.bottom - wa.top;
  hMain := CreateWindowExW(0, PWideChar(CLSNAME), PWideChar(APPNAME), WS_POPUP or WS_VISIBLE,
    wa.left, wa.top, CW, CH, 0, 0, AppInst, nil);
  if hMain = 0 then Halt(2);
  ShowWindow(hMain, SW_SHOW); UpdateWindow(hMain); SetForegroundWindow(hMain);
  while GetMessageW(@m, 0, 0, 0) do begin TranslateMessage(@m); DispatchMessageW(@m); end;
end.
