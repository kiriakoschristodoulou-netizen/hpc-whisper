unit wtext;
{ HPC Whisper 3: what you type, as a document the phone mirrors
  (docs/FORMAT3.md, TEXT and TEXT_ACK).

  Keys that are not letters (Tab, arrows, Esc, Ctrl+C, ...) go into the
  document as characters from Unicode's private area (U+E000 + code). The
  handheld never takes one back: Backspace with nothing typed since the last
  key adds the key "Backspace", which deletes on the phone.

  New text goes out at once. When the phone confirms what it has
  (TEXT_ACK), the confirmed part is never sent again, and what is not
  confirmed after a pause goes again. When nothing has ever been confirmed
  (a phone that cannot answer), the version 2 schedule of repeats is used. }
{$mode objfpc}{$H+}
interface

const
  TDOCMAX = 16000;
  TLIVE_MAX = 16;                  { while typing, frames stay short: less lag }
  TREPAIR_MAX = 40;
  KEY_BASE = $E000;
  K_BACKSPACE = $08; K_TAB = $09; K_SHIFT_TAB = $0A; K_ESC = $1B; K_PGUP = $21; K_PGDN = $22;
  K_END = $23; K_HOME = $24; K_LEFT = $25; K_UP = $26; K_RIGHT = $27; K_DOWN = $28; K_DELETE = $2E;
  K_SELALL = $41; K_COPY = $43; K_PASTE = $56; K_CUT = $58; K_UNDO = $5A;
  K_SEND = $80; K_BACK = $81; K_HOMESCREEN = $82; K_RECENTS = $83;

type
  TTextSender = record
    doc: array[0..TDOCMAX - 1] of Byte;
    L: Integer;
    docId, seq: Byte;
    keyEnd: Integer;               { just after the last key: Backspace cannot go back past it }
    sentL: Integer;                { the length the phone was last told, -1 = never }
    liveFrom: Integer;             { from here on, never sent }
    repairFrom, repair2From: Integer;
    tailDone: Boolean;
    sweepPos: Integer;
    lastEdit, lastSend: LongWord;
    { confirmations }
    acksSeen: Boolean;             { the phone has answered at least once }
    acked: Integer;                { bytes 0 .. acked-1 of this document are on the phone }
    resendAt: LongWord;            { when to send again what is not confirmed }
    resends: Integer;
  end;

procedure TsInit(var s: TTextSender; docId: Byte);
procedure TsNewDoc(var s: TTextSender);
procedure TsType(var s: TTextSender; c: WideChar; now: LongWord);
procedure TsKey(var s: TTextSender; code: Integer; now: LongWord);
procedure TsBackspace(var s: TTextSender; now: LongWord);
{ a TEXT_ACK payload arrived }
procedure TsAck(var s: TTextSender; const p: array of Byte; n: Integer; now: LongWord);
{ the next TEXT payload to send, if any; returns its length (0 = nothing to send) }
function TsNext(var s: TTextSender; now: LongWord; var payload: array of Byte): Integer;
function TsWaiting(const s: TTextSender): Integer;       { typed, not yet sent once }
function TsUnconfirmed(const s: TTextSender): Integer;   { not yet confirmed by the phone }

implementation

const
  REPAIR_IDLE_MS = 400; REPAIR2_IDLE_MS = 1500; TAIL_IDLE_MS = 3000; SWEEP_IDLE_MS = 5000; SWEEP_BACK = 300;
  ACK_WAIT_MS = 900;               { no confirmation this long after a frame: send again }
  MAX_RESENDS = 6;

procedure TsInit(var s: TTextSender; docId: Byte);
begin
  FillChar(s, SizeOf(s), 0);
  s.docId := docId;
  s.tailDone := True;
  s.sweepPos := -1;
  s.sentL := -1;
end;

procedure TsNewDoc(var s: TTextSender);
var keep: Boolean;
begin
  keep := s.acksSeen;
  s.docId := Byte(s.docId + 1);
  s.L := 0; s.keyEnd := 0; s.sentL := -1; s.liveFrom := 0; s.repairFrom := 0; s.repair2From := 0;
  s.tailDone := True; s.sweepPos := -1; s.acked := 0; s.resends := 0; s.resendAt := 0;
  s.acksSeen := keep;
end;

procedure Changed(var s: TTextSender; now: LongWord);
begin
  if s.liveFrom > s.L then s.liveFrom := s.L;
  if s.repairFrom > s.L then s.repairFrom := s.L;
  if s.repair2From > s.L then s.repair2From := s.L;
  if s.acked > s.L then s.acked := s.L;
  s.tailDone := False;
  s.sweepPos := s.L - SWEEP_BACK;
  if s.sweepPos < 0 then s.sweepPos := 0;
  s.lastEdit := now;
  s.resends := 0;
end;

procedure PutChar(var s: TTextSender; u: Integer);
begin
  if u < $80 then begin s.doc[s.L] := u; Inc(s.L); end
  else if u < $800 then
  begin
    s.doc[s.L] := $C0 or (u shr 6); s.doc[s.L + 1] := $80 or (u and $3F); Inc(s.L, 2);
  end
  else
  begin
    s.doc[s.L] := $E0 or (u shr 12); s.doc[s.L + 1] := $80 or ((u shr 6) and $3F);
    s.doc[s.L + 2] := $80 or (u and $3F); Inc(s.L, 3);
  end;
end;

procedure TsType(var s: TTextSender; c: WideChar; now: LongWord);
begin
  if s.L + 3 > TDOCMAX then TsNewDoc(s);
  PutChar(s, Ord(c));
  Changed(s, now);
end;

procedure TsKey(var s: TTextSender; code: Integer; now: LongWord);
begin
  if s.L + 3 > TDOCMAX then TsNewDoc(s);
  PutChar(s, KEY_BASE + code);
  s.keyEnd := s.L;
  Changed(s, now);
end;

procedure TsBackspace(var s: TTextSender; now: LongWord);
begin
  if s.L <= s.keyEnd then
  begin
    { nothing typed since the last key (or at all): the phone deletes in its own field }
    TsKey(s, K_BACKSPACE, now);
    Exit;
  end;
  Dec(s.L);
  while (s.L > s.keyEnd) and ((s.doc[s.L] and $C0) = $80) do Dec(s.L);   { a whole UTF-8 character }
  Changed(s, now);
end;

procedure TsAck(var s: TTextSender; const p: array of Byte; n: Integer; now: LongWord);
var known, L: Integer;
begin
  if n < 5 then Exit;
  s.acksSeen := True;
  if p[0] <> s.docId then Exit;
  known := (p[1] shl 8) or p[2];
  L := (p[3] shl 8) or p[4];
  if L <> s.L then Exit;                       { about an older length: wait for the next }
  if known > s.L then known := s.L;
  if known > s.acked then begin s.acked := known; s.resends := 0; end;
  if s.acked >= s.L then s.resendAt := 0;
end;

function MakeText(var s: TTextSender; o, n: Integer; now: LongWord; var p: array of Byte): Integer;
var i: Integer;
begin
  p[0] := s.docId; p[1] := s.seq;
  p[2] := (s.L shr 8) and 255; p[3] := s.L and 255;
  p[4] := (o shr 8) and 255; p[5] := o and 255;
  for i := 0 to n - 1 do p[6 + i] := s.doc[o + i];
  s.seq := Byte(s.seq + 1);
  s.sentL := s.L;
  s.lastSend := now;
  Result := 6 + n;
end;

function TsNext(var s: TTextSender; now: LongWord; var payload: array of Byte): Integer;
var o, n: Integer; idle: LongWord;
begin
  Result := 0;
  idle := now - s.lastEdit;
  { new text (or a shorter document) goes out at once, with the text that went out only once before it if
    there is room, so while you type every character goes twice anyway }
  if (s.liveFrom < s.L) or (s.sentL <> s.L) then
  begin
    if s.L - s.liveFrom >= TLIVE_MAX then
    begin
      o := s.liveFrom; n := s.L - o;
      if n > TREPAIR_MAX then n := TREPAIR_MAX;
    end
    else
    begin
      o := s.repairFrom;
      if s.acksSeen and (o < s.acked) then o := s.acked;
      if s.L - o > TLIVE_MAX then o := s.L - TLIVE_MAX;
      n := s.L - o;
    end;
    Result := MakeText(s, o, n, now, payload);
    if o <= s.repairFrom then s.repairFrom := s.liveFrom;
    s.liveFrom := o + n;
    s.resendAt := now + ACK_WAIT_MS;
    Exit;
  end;
  if s.acksSeen then
  begin
    { the phone answers: send again only what it has not confirmed, after a pause }
    if (s.acked < s.L) and (s.resendAt <> 0) and (LongInt(now - s.resendAt) >= 0) and (s.resends < MAX_RESENDS) then
    begin
      o := s.acked; n := s.L - o;
      if n > TREPAIR_MAX then n := TREPAIR_MAX;
      Result := MakeText(s, o, n, now, payload);
      Inc(s.resends);
      s.resendAt := now + ACK_WAIT_MS + LongWord(s.resends) * 300;
      Exit;
    end;
    if s.resends < MAX_RESENDS then Exit;
    { no answer to several repeats: fall back on the version 2 schedule below }
  end;
  if (s.repairFrom < s.L) and (idle >= REPAIR_IDLE_MS) then
  begin
    o := s.repairFrom; n := s.L - o;
    if n > TREPAIR_MAX then n := TREPAIR_MAX;
    Result := MakeText(s, o, n, now, payload);
    s.repairFrom := o + n;
    Exit;
  end;
  if (s.repair2From < s.repairFrom) and (idle >= REPAIR2_IDLE_MS) then
  begin
    o := s.repair2From; n := s.repairFrom - o;
    if n > TREPAIR_MAX then n := TREPAIR_MAX;
    Result := MakeText(s, o, n, now, payload);
    s.repair2From := o + n;
    Exit;
  end;
  if (not s.tailDone) and (idle >= TAIL_IDLE_MS) then
  begin
    o := s.L - TREPAIR_MAX; if o < 0 then o := 0;
    Result := MakeText(s, o, s.L - o, now, payload);
    s.tailDone := True;
    Exit;
  end;
  if (s.sweepPos >= 0) and (s.sweepPos < s.L) and (idle >= SWEEP_IDLE_MS) then
  begin
    o := s.sweepPos; n := s.L - o;
    if n > TREPAIR_MAX then n := TREPAIR_MAX;
    Result := MakeText(s, o, n, now, payload);
    s.sweepPos := o + n;
    if s.sweepPos >= s.L then s.sweepPos := -1;
  end;
end;

function TsWaiting(const s: TTextSender): Integer;
begin
  Result := s.L - s.liveFrom;
end;

function TsUnconfirmed(const s: TTextSender): Integer;
begin
  if s.acksSeen then Result := s.L - s.acked else Result := -1;
end;

end.
