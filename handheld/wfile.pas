unit wfile;
{ HPC Whisper 3: files in numbered packets (docs/FORMAT3.md, section 6),
  the same logic as the phone's FileSend and FileRecv (Java). No Windows
  calls: tested on Linux.

  Sender: an offer, then 16 packets at a time; after each batch it waits up
  to 1.5 s for FILE_NEED and sends again what it lists.
  Receiver: after the sender has been quiet for a moment, it answers with
  FILE_NEED: it holds every packet below "have" except those listed. }
{$mode objfpc}{$H+}
interface

const
  PACKET = 1024; BATCH = 16; WAIT_MS = 1500; MAX_POLLS = 6; QUIET_MS = 250;
  MAXPACKETS = 8192;                   { 8 MB }
  KIND_OTHER = 0; KIND_PICTURE = 1; KIND_SOUND = 2; KIND_TEXT = 3; KIND_DOCUMENT = 4; KIND_ZLIB = $80;

var
  FileWaitMs: LongWord = 1500;        { (3.9.2) how long the sender listens after a batch: as long as the phone's answer takes to sound (tones: ~3 s) }

type
  TByteArr = array of Byte;
  TFileSend = record
    id, kind: Integer;
    name: UnicodeString;
    nameUtf8: TByteArr;
    data: TByteArr;
    packets: Integer;
    confirmed, again: array of Boolean;
    nextNew, inBatch: Integer;
    offerDue, offerSentThisBatch: Boolean;
    waiting: Boolean; waitUntil: LongWord;
    polls: Integer;
    everHeard, blindRepeatDone: Boolean;
    done, failed, confirmedAll: Boolean;
    sentPackets: Integer;
  end;
  TFileRecv = record
    id, size, packets, kind: Integer;
    nameUtf8: TByteArr;
    data: TByteArr;
    got: array of Boolean;
    have, count: Integer;
    lastHeard: LongWord;
    answered: Boolean;
  end;

procedure FsInit(var s: TFileSend; id: Integer; const nameUtf8: TByteArr; kind: Integer; const data: TByteArr);
{ the next message (type and payload) when the channel is free; False = wait }
function FsNext(var s: TFileSend; now: LongWord; out typ: Integer; var p: TByteArr; out n: Integer): Boolean;
procedure FsNeed(var s: TFileSend; const p: array of Byte; n: Integer);
function FsConfirmed(const s: TFileSend): Integer;
function FsProgress1000(const s: TFileSend): Integer;

{ a new transfer from an offer; False when malformed or too large }
function FrFromOffer(var r: TFileRecv; const p: array of Byte; n: Integer; now: LongWord; maxSize: Integer): Boolean;
function FrIdOf(const p: array of Byte; n: Integer): Integer;
procedure FrOffer(var r: TFileRecv; now: LongWord);
procedure FrData(var r: TFileRecv; const p: array of Byte; n: Integer; now: LongWord);
function FrComplete(const r: TFileRecv): Boolean;
function FrNeedDue(const r: TFileRecv; now: LongWord): Boolean;
function FrNeed(var r: TFileRecv; var p: TByteArr): Integer;          { the FILE_NEED payload; its length }
function FrNeedOffer(id: Integer; var p: TByteArr): Integer;

implementation

function Later(a, b: LongWord): Boolean; inline;              { a is at or after b (wraps) }
begin
  Result := LongInt(a - b) >= 0;
end;

procedure FsInit(var s: TFileSend; id: Integer; const nameUtf8: TByteArr; kind: Integer; const data: TByteArr);
var i: Integer;
begin
  s.id := id and $FFFF; s.kind := kind; s.nameUtf8 := nameUtf8; s.data := data;
  s.packets := (Length(data) + PACKET - 1) div PACKET;
  if s.packets < 1 then s.packets := 1;
  SetLength(s.confirmed, s.packets); SetLength(s.again, s.packets);
  for i := 0 to s.packets - 1 do begin s.confirmed[i] := False; s.again[i] := False; end;
  s.nextNew := 0; s.inBatch := 0; s.offerDue := True; s.offerSentThisBatch := False;
  s.waiting := False; s.waitUntil := 0; s.polls := 0; s.everHeard := False; s.blindRepeatDone := False;
  s.done := False; s.failed := False; s.confirmedAll := False; s.sentPackets := 0;
end;

function FsConfirmed(const s: TFileSend): Integer;
var k: Integer;
begin
  Result := 0;
  for k := 0 to s.packets - 1 do if s.confirmed[k] then Inc(Result);
end;

function FsProgress1000(const s: TFileSend): Integer;
var n: Integer;
begin
  if s.done then begin Result := 1000; Exit; end;
  if s.everHeard then n := FsConfirmed(s) else begin n := s.nextNew; if n > s.packets then n := s.packets; end;
  Result := n * 1000 div s.packets;
end;

procedure MakeOffer(const s: TFileSend; var p: TByteArr; out n: Integer);
var nl, i, size: Integer;
begin
  nl := Length(s.nameUtf8); if nl > 200 then nl := 200;
  n := 9 + nl;
  if Length(p) < n then SetLength(p, n);
  size := Length(s.data);
  p[0] := s.id shr 8; p[1] := s.id and 255;
  p[2] := (size shr 24) and 255; p[3] := (size shr 16) and 255; p[4] := (size shr 8) and 255; p[5] := size and 255;
  p[6] := s.packets shr 8; p[7] := s.packets and 255; p[8] := s.kind and 255;
  for i := 0 to nl - 1 do p[9 + i] := s.nameUtf8[i];
end;

procedure MakePacket(const s: TFileSend; k: Integer; var p: TByteArr; out n: Integer);
var a, m: Integer;
begin
  a := k * PACKET; m := Length(s.data) - a;
  if m > PACKET then m := PACKET;
  if m < 0 then m := 0;
  n := 4 + m;
  if Length(p) < n then SetLength(p, n);
  p[0] := s.id shr 8; p[1] := s.id and 255; p[2] := k shr 8; p[3] := k and 255;
  if m > 0 then Move(s.data[a], p[4], m);
end;

function FsNext(var s: TFileSend; now: LongWord; out typ: Integer; var p: TByteArr; out n: Integer): Boolean;
var k: Integer;
begin
  Result := False; typ := 0; n := 0;
  if s.done or s.failed then Exit;
  if s.waiting then
  begin
    if not Later(now, s.waitUntil) then Exit;
    s.waiting := False;
    if not s.everHeard then
    begin
      if s.nextNew >= s.packets then
      begin
        if not s.blindRepeatDone then
        begin
          s.blindRepeatDone := True;
          for k := 0 to s.packets - 1 do s.again[k] := True;
        end
        else begin s.done := True; Exit; end;
      end;
    end
    else
    begin
      Inc(s.polls);
      if s.polls > MAX_POLLS then begin s.failed := True; Exit; end;
      s.offerDue := True;
    end;
  end;
  if (s.inBatch = 0) and (not s.everHeard) and (s.nextNew > 0) and (not s.offerSentThisBatch) then s.offerDue := True;
  if s.offerDue then
  begin
    s.offerSentThisBatch := True;
    s.offerDue := False;
    if (s.inBatch = 0) and s.everHeard and (s.nextNew > 0) then begin s.waiting := True; s.waitUntil := now + FileWaitMs; end;
    MakeOffer(s, p, n); typ := $10; Result := True;
    Exit;
  end;
  if s.inBatch < BATCH then
  begin
    { what was asked for again first (lowest first), then new packets }
    k := -1;
    while True do
    begin
      k := k + 1;
      if k >= s.packets then begin k := -1; Break; end;
      if s.again[k] then
      begin
        s.again[k] := False;
        if not s.confirmed[k] then Break;
      end;
    end;
    if (k < 0) and (s.nextNew < s.packets) then begin k := s.nextNew; Inc(s.nextNew); end;
    if k >= 0 then
    begin
      Inc(s.inBatch); Inc(s.sentPackets);
      MakePacket(s, k, p, n); typ := $11; Result := True;
      Exit;
    end;
  end;
  s.inBatch := 0;
  s.offerSentThisBatch := False;
  s.waiting := True; s.waitUntil := now + FileWaitMs;
end;

procedure FsNeed(var s: TFileSend; const p: array of Byte; n: Integer);
var flags, have, listed, last, i, k, sure, top: Integer; missing: array of Boolean; full: Boolean;
begin
  if (n < 3) or (((p[0] shl 8) or p[1]) <> s.id) then Exit;
  s.everHeard := True;
  s.polls := 0;
  flags := p[2];
  if (flags and 1) <> 0 then
  begin
    for k := 0 to s.packets - 1 do s.confirmed[k] := True;
    s.done := True; s.confirmedAll := True; Exit;
  end;
  if (flags and 2) <> 0 then s.offerDue := True;
  if n < 5 then Exit;
  have := (p[3] shl 8) or p[4];
  listed := (n - 5) div 2;
  SetLength(missing, s.packets);
  for k := 0 to s.packets - 1 do missing[k] := False;
  last := -1;
  i := 5;
  while i + 1 < n do
  begin
    k := (p[i] shl 8) or p[i + 1];
    if k < s.packets then begin missing[k] := True; last := k; end;
    Inc(i, 2);
  end;
  full := listed >= 32;
  if full then sure := last + 1 else begin sure := have; if sure > s.packets then sure := s.packets; end;
  for k := 0 to sure - 1 do if not missing[k] then s.confirmed[k] := True;
  for k := 0 to s.packets - 1 do s.again[k] := missing[k] and not s.confirmed[k];
  if not full then
  begin
    top := s.nextNew; if top > s.packets then top := s.packets;
    for k := have to top - 1 do if not s.confirmed[k] then s.again[k] := True;
  end;
  if FsConfirmed(s) = s.packets then begin s.done := True; s.confirmedAll := True; end;
  s.waiting := False;
  s.inBatch := 0;
end;

{ ---------- receiving ---------- }

function FrIdOf(const p: array of Byte; n: Integer): Integer;
begin
  if n >= 2 then Result := (p[0] shl 8) or p[1] else Result := -1;
end;

function FrFromOffer(var r: TFileRecv; const p: array of Byte; n: Integer; now: LongWord; maxSize: Integer): Boolean;
var size, packets, i, want: Integer;
begin
  Result := False;
  if n < 9 then Exit;
  size := (LongInt(p[2]) shl 24) or (p[3] shl 16) or (p[4] shl 8) or p[5];
  packets := (p[6] shl 8) or p[7];
  want := (size + PACKET - 1) div PACKET; if want < 1 then want := 1;
  if (size < 0) or (size > maxSize) or (packets <> want) or (packets > MAXPACKETS) then Exit;
  r.id := (p[0] shl 8) or p[1]; r.size := size; r.packets := packets; r.kind := p[8];
  SetLength(r.nameUtf8, n - 9);
  for i := 9 to n - 1 do r.nameUtf8[i - 9] := p[i];
  SetLength(r.data, 0);
  SetLength(r.data, size);
  SetLength(r.got, packets);
  for i := 0 to packets - 1 do r.got[i] := False;
  r.have := 0; r.count := 0; r.lastHeard := now; r.answered := False;
  Result := True;
end;

procedure FrOffer(var r: TFileRecv; now: LongWord);
begin
  r.lastHeard := now; r.answered := False;
end;

procedure FrData(var r: TFileRecv; const p: array of Byte; n: Integer; now: LongWord);
var k, a, m: Integer;
begin
  if (n < 4) or (FrIdOf(p, n) <> r.id) then Exit;
  k := (p[2] shl 8) or p[3];
  r.lastHeard := now; r.answered := False;
  if (k >= r.packets) or r.got[k] then Exit;
  a := k * PACKET; m := r.size - a; if m > PACKET then m := PACKET;
  if n - 4 <> m then Exit;
  if m > 0 then Move(p[4], r.data[a], m);
  r.got[k] := True; Inc(r.count);
  if k + 1 > r.have then r.have := k + 1;
end;

function FrComplete(const r: TFileRecv): Boolean;
begin
  Result := r.count = r.packets;
end;

function FrNeedDue(const r: TFileRecv; now: LongWord): Boolean;
begin
  Result := (not r.answered) and (LongInt(now - r.lastHeard) >= QUIET_MS);
end;

function FrNeed(var r: TFileRecv; var p: TByteArr): Integer;
var all: Boolean; n, k: Integer;
begin
  r.answered := True;
  all := FrComplete(r);
  if Length(p) < 5 + 64 then SetLength(p, 5 + 64);
  n := 0;
  if not all then
  begin
    k := 0;
    while (k < r.have) and (n < 32) do
    begin
      if not r.got[k] then begin p[5 + 2 * n] := k shr 8; p[6 + 2 * n] := k and 255; Inc(n); end;
      Inc(k);
    end;
  end;
  p[0] := r.id shr 8; p[1] := r.id and 255;
  if all then p[2] := 1 else p[2] := 0;
  p[3] := r.have shr 8; p[4] := r.have and 255;
  Result := 5 + 2 * n;
end;

function FrNeedOffer(id: Integer; var p: TByteArr): Integer;
begin
  if Length(p) < 5 then SetLength(p, 5);
  p[0] := (id shr 8) and 255; p[1] := id and 255; p[2] := 2; p[3] := 0; p[4] := 0;
  Result := 5;
end;

end.
