unit wlog;
{ Whisper Tools: the handheld's diagnostics log. Every event of the link is written as one line, with
  the time since the program started (seconds.milliseconds), into "Whisper Tools log N.txt" in the
  folder for received files (on a memory card if Settings put them there). Lines collect in memory and go to the file every second, from whichever thread gets
  there first (the sound thread too, so a frozen screen still leaves its last seconds in the file).
  Each start writes a new file (the program keeps the last five); past 3 MB a file is not added to. }
{$mode objfpc}{$H+}
interface

uses Windows;

{ starts a new log file at path (replacing an older one of that name); False when it cannot be made }
function LogStart(const path: UnicodeString; const version: AnsiString): Boolean;
function LogPath: UnicodeString;
procedure Log(const s: AnsiString);
{ writes what has collected, if a second has passed (or now, if force) }
procedure LogTick(force: Boolean);
function LI(i: Int64): AnsiString;
function LHex(i: Integer): AnsiString;
{ a message of format 3, in words: its type, length and what matters in it }
function LDescribe(typ: Integer; const p: array of Byte; n: Integer): AnsiString;
function LChan(ch: Integer): AnsiString;
function LType(typ: Integer): AnsiString;

var LogOn: Boolean = False;

implementation

uses w3core;

const
  BUFSZ = 65536;
  MAXFILE = 3 * 1024 * 1024;

var
  Lk, FlushLk: TRTLCriticalSection;
  Buf: array[0..BUFSZ - 1] of Char;
  BufN: Integer = 0;
  Lost: Integer = 0;
  LastLine: AnsiString = '';
  Repeats: Integer = 0;
  T0: LongWord;
  LastFlush: LongWord;
  FilePath: UnicodeString;
  OutB: array[0..BUFSZ - 1] of Char;

function LI(i: Int64): AnsiString;
begin
  Str(i, Result);
end;

function LHex(i: Integer): AnsiString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Result := '0x' + H[(i shr 4) and 15] + H[i and 15];
end;

function LChan(ch: Integer): AnsiString;
begin
  case ch of
    CH_SU: Result := 'SU';
    CH_SUW: Result := 'SUW';
    CH_SD: Result := 'SD';
    CH_FU: Result := 'FU';
    CH_FD: Result := 'FD';
  else Result := 'ch' + LI(ch);
  end;
end;

function W16(const p: array of Byte; i: Integer): Integer;
begin
  Result := (p[i] shl 8) or p[i + 1];
end;

function LDescribe(typ: Integer; const p: array of Byte; n: Integer): AnsiString;
var i, k: Integer;
begin
  case typ of
    T_TEXT: begin Result := 'TEXT'; if n >= 6 then Result := Result + ' doc ' + LI(p[0]) + ' seq ' + LI(p[1]) + ' length ' + LI(W16(p, 2)) + ' from ' + LI(W16(p, 4)) + ' chars ' + LI(n - 6); end;
    T_TEXT_ACK: begin Result := 'TEXT_ACK'; if n >= 5 then Result := Result + ' doc ' + LI(p[0]) + ' known ' + LI(W16(p, 1)) + ' of length ' + LI(W16(p, 3)); end;
    T_FILE_OFFER: begin Result := 'FILE_OFFER'; if n >= 9 then Result := Result + ' id ' + LI(W16(p, 0)) + ' size ' + LI((LongInt(p[2]) shl 24) or (p[3] shl 16) or (p[4] shl 8) or p[5]) + ' packets ' + LI(W16(p, 6)) + ' kind ' + LHex(p[8]); end;
    T_FILE_DATA: begin Result := 'FILE_DATA'; if n >= 4 then Result := Result + ' id ' + LI(W16(p, 0)) + ' packet ' + LI(W16(p, 2)) + ' bytes ' + LI(n - 4); end;
    T_FILE_NEED:
      begin
        Result := 'FILE_NEED';
        if n >= 5 then
        begin
          Result := Result + ' id ' + LI(W16(p, 0)) + ' flag ' + LI(p[2]) + ' have ' + LI(W16(p, 3)) + ' missing ' + LI((n - 5) div 2);
          k := 0; i := 5;
          while (i + 1 < n) and (k < 8) do begin if k = 0 then Result := Result + ':'; Result := Result + ' ' + LI(W16(p, i)); Inc(i, 2); Inc(k); end;
          if (n - 5) div 2 > 8 then Result := Result + ' ...';
        end;
      end;
    T_FILE_CANCEL: begin Result := 'FILE_CANCEL'; if n >= 2 then Result := Result + ' id ' + LI(W16(p, 0)); end;
    T_SCREEN: Result := 'SCREEN ' + LI(n) + ' bytes';
    T_INPUT: begin Result := 'INPUT'; if n >= 1 then Result := Result + ' kind ' + LI(p[0]); end;
    T_TRAIN: Result := 'TRAIN';
    T_MAP: begin Result := 'MAP'; if n >= 2 then Result := Result + ' ch ' + LI(p[0]) + ' number ' + LI(p[1]); end;
    T_HELLO: begin Result := 'HELLO'; if n >= 4 then Result := Result + ' version ' + LI(p[0]) + ' reply ' + LI(p[3] and 1); end;
    T_CHECK: begin Result := 'CHECK'; if n >= 1 then Result := Result + ' ch ' + LChan(p[0]); end;
    $34: begin Result := 'PAIR_REPORT'; if n >= 40 then Result := Result + ' scale ' + LI(W16(p, 34)) + ' ladder ' + LI(p[38] - 1) + ' quality ' + LI(p[39] - 20) + ' dB'; end;
  else Result := 'type ' + LHex(typ);
  end;
  Result := Result + ' (' + LI(n) + ' bytes)';
end;

function LType(typ: Integer): AnsiString;
var d: array[0..0] of Byte;
begin
  d[0] := 0;
  Result := LDescribe(typ, d, 0);
  SetLength(Result, Length(Result) - Length(' (0 bytes)'));
end;

{ equal strings, compared here (the compiler's own comparison needs memcmp, which the device was not checked for) }
function Same(const a, b: AnsiString): Boolean;
var i: Integer;
begin
  Result := False;
  if Length(a) <> Length(b) then Exit;
  for i := 1 to Length(a) do if a[i] <> b[i] then Exit;
  Result := True;
end;

procedure Put(const s: AnsiString);
var i: Integer;
begin
  if BufN + Length(s) > BUFSZ then begin Inc(Lost); Exit; end;
  for i := 1 to Length(s) do Buf[BufN + i - 1] := s[i];
  Inc(BufN, Length(s));
end;

procedure Log(const s: AnsiString);
var t: LongWord; ms: AnsiString;
begin
  if not LogOn then Exit;
  t := GetTickCount - T0;
  ms := LI(t mod 1000);
  while Length(ms) < 3 do ms := '0' + ms;
  EnterCriticalSection(Lk);
  if Same(s, LastLine) then begin Inc(Repeats); LeaveCriticalSection(Lk); Exit; end;     { the same again: counted }
  if Repeats > 0 then begin Put('  (the line before came ' + LI(Repeats) + ' more times)'#13#10); Repeats := 0; end;
  LastLine := s;
  if Lost > 0 then begin Put('(' + LI(Lost) + ' lines lost: the file could not keep up)'#13#10); Lost := 0; end;
  Put(LI(t div 1000) + '.' + ms + ' ' + s + #13#10);
  LeaveCriticalSection(Lk);
end;

procedure WriteOut(n: Integer; truncate: Boolean);
var h: THandle; done: DWORD; mode: DWORD;
begin
  if truncate then mode := CREATE_ALWAYS else mode := OPEN_ALWAYS;
  h := CreateFileW(PWideChar(FilePath), GENERIC_WRITE, FILE_SHARE_READ, nil, mode, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  if SetFilePointer(h, 0, nil, FILE_END) > MAXFILE then begin CloseHandle(h); Exit; end;
  done := 0;
  if n > 0 then WriteFile(h, {$ifdef wince}@OutB{$else}OutB{$endif}, n, {$ifdef wince}@done{$else}done{$endif}, nil);
  CloseHandle(h);
end;

procedure LogTick(force: Boolean);
var n: Integer; now: LongWord;
begin
  if not LogOn then Exit;
  now := GetTickCount;
  if (not force) and (now - LastFlush < 1000) then Exit;
  { one writer at a time; a thread that finds the other writing goes on }
  if not TryEnterCriticalSection(FlushLk) then Exit;
  LastFlush := now;
  EnterCriticalSection(Lk);
  n := BufN;
  if n > 0 then Move(Buf[0], OutB[0], n);
  BufN := 0;
  LeaveCriticalSection(Lk);
  if n > 0 then WriteOut(n, False);
  LeaveCriticalSection(FlushLk);
end;

var LocksMade: Boolean = False;

function LogStart(const path: UnicodeString; const version: AnsiString): Boolean;
var h: THandle;
begin
  if not LocksMade then begin InitializeCriticalSection(Lk); InitializeCriticalSection(FlushLk); LocksMade := True; end;
  Result := False;
  { a new file for each start: a file left damaged by a reset in the middle of writing (it could then not
    even be copied: 3.8) cannot stop the next one }
  h := CreateFileW(PWideChar(path), GENERIC_WRITE, FILE_SHARE_READ, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  CloseHandle(h);
  FilePath := path;
  T0 := GetTickCount; LastFlush := T0;
  LogOn := True;
  Result := True;
  Log('=== Whisper Tools ' + version + ' started (the clock ' + LI(T0) + ' ms since the handheld was switched on)');
  LogTick(True);
end;

function LogPath: UnicodeString;
begin
  Result := FilePath;
end;

end.
