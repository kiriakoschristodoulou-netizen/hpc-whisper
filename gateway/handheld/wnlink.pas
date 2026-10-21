unit wnlink;
{ Whisper Net: the byte-stream link (NET-PROTOCOL.md section 3), no sound in
  it. The same rules as the phone's Link.java.

  Whole numbers, fixed arrays, no heap and no strings (runs in a CreateThread
  thread on the handheld). }
{$mode objfpc}{$R-}{$Q-}
interface
uses wnframe;

const
  LK_CAP = 6144;                       { bytes waiting to be sent }
  LK_MAXFR = 3;

type
  { bytes of the other side's stream; returns how many were taken (the rest comes again) }
  TLinkData = function(b: PByte; len: Integer): Integer;
  TLinkReset = procedure;

  TLink = record
    buf: array[0..LK_CAP - 1] of Byte;
    start, base, count: Integer;       { buf[0..count) are the stream bytes from offset base }
    acked, havePeer: Boolean;
    next: Integer;                     { next offset expected from the other side }
    seed: LongWord;
    onData: TLinkData;
    onReset: TLinkReset;
    framesIn, framesBad: LongWord;
  end;

procedure LkInit(var l: TLink; seed: LongWord; ad: TLinkData; ar: TLinkReset);
function LkFree(const l: TLink): Integer;
function LkPending(const l: TLink): Integer;
function LkWrite(var l: TLink; b: PByte; len: Integer): Boolean;
{ the frames of this side's turn (at least one, the last with TURN); returns how many }
function LkTurn(var l: TLink; var fr: array of TNetFrame): Integer;
procedure LkReceive(var l: TLink; const f: TNetFrame);

implementation

function Rnd16(var l: TLink): Integer;
begin
  l.seed := l.seed * 1103515245 + 12345;
  Result := (l.seed shr 8) and $FFFF;
end;

procedure Restart(var l: TLink);
begin
  repeat l.start := Rnd16(l); until l.start <> 0;
  l.base := l.start; l.count := 0; l.acked := False;
end;

procedure LkInit(var l: TLink; seed: LongWord; ad: TLinkData; ar: TLinkReset);
begin
  FillChar(l, SizeOf(l), 0);
  l.seed := seed; l.onData := ad; l.onReset := ar;
  Restart(l);
end;

function D16(a, b: Integer): Integer;
var d: Integer;
begin
  d := (a - b) and $FFFF;
  if d >= $8000 then d := d - $10000;
  Result := d;
end;

function LkFree(const l: TLink): Integer;
begin
  Result := LK_CAP - l.count;
end;

function LkPending(const l: TLink): Integer;
begin
  Result := l.count;
end;

function LkWrite(var l: TLink; b: PByte; len: Integer): Boolean;
begin
  Result := len <= LK_CAP - l.count;
  if not Result then Exit;
  Move(b^, l.buf[l.count], len);
  Inc(l.count, len);
end;

function LkTurn(var l: TLink; var fr: array of TNetFrame): Integer;
var sent, n, k: Integer;
begin
  sent := 0; k := 0;
  repeat
    n := l.count - sent;
    if n > NET_MAXLEN then n := NET_MAXLEN;
    FillChar(fr[k], SizeOf(TNetFrame), 0);
    fr[k].n := n;
    fr[k].off := (l.base + sent) and $FFFF;
    if l.havePeer then fr[k].ack := l.next and $FFFF else fr[k].ack := 0;
    if n > 0 then Move(l.buf[sent], fr[k].data[0], n);
    if (fr[k].off = l.start) and not l.acked then fr[k].flags := FL_SYNC;
    sent := sent + n;
    Inc(k);
  until (sent >= l.count) or (k >= LK_MAXFR);
  fr[k - 1].flags := fr[k - 1].flags or FL_TURN;
  Result := k;
end;

procedure LkReceive(var l: TLink; const f: TNetFrame);
var ack, adv, skip, d, took: Integer; isNew: Boolean;
begin
  Inc(l.framesIn);
  ack := f.ack;
  if (f.flags and FL_SYNC) <> 0 then
  begin
    d := D16(f.off, l.next);
    isNew := (not l.havePeer) or (d < -170) or (d > 110);
    if isNew then
    begin
      l.havePeer := True; l.next := f.off;
      if Assigned(l.onReset) then l.onReset();
      if l.acked then begin Restart(l); ack := 0; end;
    end;
  end
  else if not l.havePeer then Exit;
  adv := D16(ack, l.base);
  if (ack <> 0) and (adv > 0) and (adv <= l.count) then
  begin
    Move(l.buf[adv], l.buf[0], l.count - adv);
    Dec(l.count, adv);
    l.base := ack and $FFFF; l.acked := True;
  end;
  skip := D16(l.next, f.off);
  if (skip >= 0) and (skip < f.n) then
  begin
    took := l.onData(@f.data[skip], f.n - skip);
    if took > 0 then l.next := (l.next + took) and $FFFF;
  end;
end;

end.
