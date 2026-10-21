unit wnstack;
{ Whisper Net: the handheld's small TCP/IP stack and mux (NET-PROTOCOL.md
  sections 4 and 5).

  Windows (through the dial-up link) thinks it talks to the whole internet.
  Here every TCP connection is answered at once as if this were the server
  (SYN-ACK, acknowledgements, window), and only what matters goes over the
  sound link: OPEN, the bytes, CLOSE, ABORT. DNS questions become DNS messages
  (answers are cached 10 minutes), other UDP becomes UDP messages.

  Whole numbers, fixed arrays, no heap, no strings: it runs in a thread made
  with CreateThread. No Windows calls: tested on Linux (tests/netsim.pas).

  Calls, all from one thread:
    StInit; StIpIn(packet) for every IP packet Windows sent; StTick(now) often;
    StPump before every turn (moves waiting messages into the link);
    the link (Lk) receives frames from the receiver (LkReceive(Lk, f)). }
{$mode objfpc}{$R-}{$Q-}
interface
uses wnframe, wnlink;

const
  OUR_IP  = $C0A83701;               { 192.168.55.1: the gateway and DNS }
  PEER_IP = $C0A83702;               { 192.168.55.2: the handheld, Windows' side }
  MAXC = 6;                          { TCP connections }
  UPBUF = 2048;                      { bytes from Windows waiting to go up, per connection }
  DNBUF = 4096;                      { bytes from the internet waiting for Windows, per connection }
  TCP_MSS = 536;
  MAXDQ = 8;                         { DNS questions waiting for an answer }
  MAXU = 8;                          { UDP exchanges }
  DCACHE = 12;
  DNS_TTL_MS = 600000;
  UP_LIMIT = 400;                    { bytes the link may hold before more DATA is queued }
  IDLE_MS = 300000;                  { a silent connection is reset after this }

type
  TIpOut = procedure(p: PByte; len: Integer);

  TStStats = record
    ipIn, tcpOpened, tcpReset, dnsAsked, dnsCached, dnsAnswered, udpOut, udpIn: LongWord;
    bytesUp, bytesDown: LongWord;     { stream bytes written to / read from the mux }
    helloAt: LongWord;
  end;

var
  IpOut: TIpOut = nil;
  Lk: TLink;
  StNow: LongWord;
  St: TStStats;

procedure StInit(seed: LongWord);
procedure StIpIn(p: PByte; len: Integer);
procedure StTick(now: LongWord);
procedure StPump;
{ connections open, a question waiting, or messages queued: the turns should keep coming }
function StActive: Boolean;
function StConns: Integer;
{ something waits to go up (messages, bytes of a connection) }
function StUpWaiting: Boolean;

implementation

type
  TConn = record
    state: Byte;                      { 0 free, 1 SYN-ACK sent, 2 established }
    wip, rip: LongWord;               { Windows, and the server it thinks it talks to }
    wport, rport: Word;
    iss, sndUna, sndNxt, rcvNxt: LongWord;
    wnd: LongWord;                    { Windows' receive window }
    opened, gwClose, finSent, finAcked, finRcvd, closeUp, failed: Boolean;
    up: array[0..UPBUF - 1] of Byte; upHead, upN: Integer;
    dn: array[0..DNBUF - 1] of Byte; dnHead, dnN, dnSent: Integer;
    lastAct, rtxAt: LongWord;
  end;

  TDnsQ = record
    used: Boolean;
    qid, txid: Word;
    wip, rip: LongWord; wport: Word;
    sec: array[0..127] of Byte; secLen: Integer;    { the question section, to copy into the answer }
    at: LongWord;
  end;

  TUdpX = record
    used: Boolean;
    wip, rip: LongWord; wport, rport: Word;
    until_: LongWord;
  end;

  TDnsC = record
    used: Boolean;
    name: array[0..99] of Byte; nl: Integer;
    cnt: Integer; addr: array[0..3] of LongWord;
    expires: LongWord;
  end;

var
  C: array[0..MAXC - 1] of TConn;
  DQ: array[0..MAXDQ - 1] of TDnsQ;
  UX: array[0..MAXU - 1] of TUdpX;
  DC: array[0..DCACHE - 1] of TDnsC;
  cq: array[0..1535] of Byte; cqN: Integer;      { control messages: 2-byte length, message }
  rb: array[0..511] of Byte; rbN: Integer;       { stream from the gateway, not yet used }
  OutB: array[0..1599] of Byte;
  ipId: Word;
  issCtr: LongWord;
  nextQid: Byte;
  rrConn: Integer;
  gotHello: Boolean;

{ ---------- bytes ---------- }

function GetW(p: PByte; o: Integer): LongWord;
begin Result := (LongWord(p[o]) shl 8) or p[o + 1]; end;
function GetL(p: PByte; o: Integer): LongWord;
begin Result := (LongWord(p[o]) shl 24) or (LongWord(p[o + 1]) shl 16) or (LongWord(p[o + 2]) shl 8) or p[o + 3]; end;
procedure PutW(p: PByte; o: Integer; v: LongWord);
begin p[o] := (v shr 8) and 255; p[o + 1] := v and 255; end;
procedure PutL(p: PByte; o: Integer; v: LongWord);
begin p[o] := (v shr 24) and 255; p[o + 1] := (v shr 16) and 255; p[o + 2] := (v shr 8) and 255; p[o + 3] := v and 255; end;

function SumAdd(s: LongWord; p: PByte; n: Integer): LongWord;
var i: Integer;
begin
  i := 0;
  while i + 1 < n do begin s := s + GetW(p, i); Inc(i, 2); end;
  if i < n then s := s + (LongWord(p[i]) shl 8);
  Result := s;
end;
function SumFold(s: LongWord): LongWord;
begin
  while (s shr 16) <> 0 do s := (s and $FFFF) + (s shr 16);
  Result := (not s) and $FFFF;
end;

function SeqLT(a, b: LongWord): Boolean; begin Result := LongInt(a - b) < 0; end;
function SeqLE(a, b: LongWord): Boolean; begin Result := LongInt(a - b) <= 0; end;

{ ---------- sending packets to Windows ---------- }

{ IP header (20 bytes) in OutB[0..19] for a payload of plen bytes already in OutB[20..] }
procedure FinishIp(proto: Byte; src, dst: LongWord; plen: Integer);
begin
  OutB[0] := $45; OutB[1] := 0;
  PutW(@OutB, 2, 20 + plen);
  Inc(ipId); PutW(@OutB, 4, ipId);
  PutW(@OutB, 6, $4000);
  OutB[8] := 64; OutB[9] := proto;
  PutW(@OutB, 10, 0);
  PutL(@OutB, 12, src); PutL(@OutB, 16, dst);
  PutW(@OutB, 10, SumFold(SumAdd(0, @OutB, 20)));
  if Assigned(IpOut) then IpOut(@OutB, 20 + plen);
end;

{ a TCP segment from the server (rip:rport) to Windows (wip:wport) }
procedure SendTcpRaw(rip, wip: LongWord; rport, wport: Word; flags: Byte; seq, ack: LongWord; win: LongWord;
                     data: PByte; dlen: Integer; mss: Boolean);
var hl, s: LongWord; tl: Integer;
begin
  hl := 20; if mss then hl := 24;
  tl := hl + dlen;
  PutW(@OutB, 20, rport); PutW(@OutB, 22, wport);
  PutL(@OutB, 24, seq); PutL(@OutB, 28, ack);
  OutB[32] := (hl div 4) shl 4; OutB[33] := flags;
  if win > 65535 then win := 65535;
  PutW(@OutB, 34, win);
  PutW(@OutB, 36, 0); PutW(@OutB, 38, 0);
  if mss then begin OutB[40] := 2; OutB[41] := 4; PutW(@OutB, 42, TCP_MSS); end;
  if dlen > 0 then Move(data^, OutB[20 + hl], dlen);
  { checksum with the pseudo header }
  s := (rip shr 16) + (rip and $FFFF) + (wip shr 16) + (wip and $FFFF) + 6 + tl;
  s := SumAdd(s, @OutB[20], tl);
  PutW(@OutB, 36, SumFold(s));
  FinishIp(6, rip, wip, tl);
end;

function UpFree(const k: TConn): Integer;
begin Result := UPBUF - k.upN; end;

procedure SendTcp(var k: TConn; flags: Byte; seq: LongWord; data: PByte; dlen: Integer; mss: Boolean);
begin
  SendTcpRaw(k.rip, k.wip, k.rport, k.wport, flags, seq, k.rcvNxt, UpFree(k), data, dlen, mss);
end;

procedure SendAck(var k: TConn);
begin
  SendTcp(k, $10, k.sndNxt, nil, 0, False);
end;

{ a reset for a segment that belongs to no connection }
procedure SendRstFor(ip: PByte; hl, tl: Integer);
var flags: Byte; seq, ack, plen: LongWord;
begin
  flags := ip[hl + 13];
  if (flags and 4) <> 0 then Exit;
  seq := GetL(ip, hl + 4); ack := GetL(ip, hl + 8);
  plen := tl - hl - ((ip[hl + 12] shr 4) * 4);
  if (flags and $10) <> 0 then
    SendTcpRaw(GetL(ip, 16), GetL(ip, 12), GetW(ip, hl + 2), GetW(ip, hl), 4, ack, 0, 0, nil, 0, False)
  else
  begin
    if (flags and 2) <> 0 then Inc(plen);
    if (flags and 1) <> 0 then Inc(plen);
    SendTcpRaw(GetL(ip, 16), GetL(ip, 12), GetW(ip, hl + 2), GetW(ip, hl), $14, 0, seq + plen, 0, nil, 0, False);
  end;
end;

procedure SendUdp(src, dst: LongWord; sport, dport: Word; data: PByte; dlen: Integer);
var ul: Integer; s: LongWord;
begin
  ul := 8 + dlen;
  PutW(@OutB, 20, sport); PutW(@OutB, 22, dport); PutW(@OutB, 24, ul); PutW(@OutB, 26, 0);
  if dlen > 0 then Move(data^, OutB[28], dlen);
  s := (src shr 16) + (src and $FFFF) + (dst shr 16) + (dst and $FFFF) + 17 + ul;
  s := SumAdd(s, @OutB[20], ul);
  s := SumFold(s);
  if s = 0 then s := $FFFF;
  PutW(@OutB, 26, s);
  FinishIp(17, src, dst, ul);
end;

{ ---------- messages up (to the gateway) ---------- }

function Enq(m: PByte; len: Integer): Boolean;
begin
  Result := cqN + 2 + len <= SizeOf(cq);
  if not Result then Exit;
  cq[cqN] := len shr 8; cq[cqN + 1] := len and 255;
  Move(m^, cq[cqN + 2], len);
  Inc(cqN, 2 + len);
end;

procedure EnqHello;
var m: array[0..1] of Byte;
begin
  m[0] := 7; m[1] := 1; Enq(@m, 2);
end;

procedure EnqId(t, id: Byte);
var m: array[0..1] of Byte;
begin
  m[0] := t; m[1] := id; Enq(@m, 2);
end;

{ ---------- connections ---------- }

function ConnId(const k: TConn): Byte;
begin
  Result := (PtrUInt(@k) - PtrUInt(@C[0])) div SizeOf(TConn) + 1;
end;

procedure FreeConn(var k: TConn; sendAbort: Boolean);
begin
  if sendAbort and (k.state <> 0) then EnqId(4, ConnId(k));
  k.state := 0;
end;

function FindConn(wip, rip: LongWord; wport, rport: Word): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to MAXC - 1 do
    if (C[i].state <> 0) and (C[i].wip = wip) and (C[i].rip = rip) and (C[i].wport = wport) and (C[i].rport = rport) then
    begin Result := i; Exit; end;
end;

procedure RingPutDn(var k: TConn; p: PByte; n: Integer);
var i, at: Integer;
begin
  for i := 0 to n - 1 do
  begin
    at := (k.dnHead + k.dnN) mod DNBUF;
    k.dn[at] := p[i]; Inc(k.dnN);
  end;
end;

procedure RingGetDn(var k: TConn; off, n: Integer; dst: PByte);
var i: Integer;
begin
  for i := 0 to n - 1 do dst[i] := k.dn[(k.dnHead + off + i) mod DNBUF];
end;

{ send what the window allows; FIN when the gateway closed and everything is out }
procedure TcpSend(var k: TConn);
var n, wl, flight: Integer; tmp: array[0..TCP_MSS - 1] of Byte;
begin
  if k.state < 2 then Exit;
  while True do
  begin
    n := k.dnN - k.dnSent;
    wl := Integer(k.wnd) - k.dnSent;
    if wl < n then n := wl;
    if n > TCP_MSS then n := TCP_MSS;
    if n <= 0 then Break;
    RingGetDn(k, k.dnSent, n, @tmp);
    if k.dnSent = 0 then k.rtxAt := StNow;
    SendTcp(k, $18, k.sndNxt, @tmp, n, False);
    Inc(k.dnSent, n); k.sndNxt := k.sndNxt + LongWord(n);
  end;
  if k.gwClose and (k.dnSent = k.dnN) and (not k.finSent) then
  begin
    SendTcp(k, $11, k.sndNxt, nil, 0, False);
    k.finSent := True; k.sndNxt := k.sndNxt + 1;
    k.rtxAt := StNow;
  end;
  flight := k.dnSent;
  if flight < 0 then flight := 0;
end;

procedure NewConn(ip: PByte; hl, tl: Integer);
var i, id: Integer; k: ^TConn;
begin
  id := -1;
  for i := 0 to MAXC - 1 do if C[i].state = 0 then begin id := i; Break; end;
  if id < 0 then begin SendRstFor(ip, hl, tl); Exit; end;
  k := @C[id];
  FillChar(k^, SizeOf(TConn), 0);
  k^.state := 1;
  k^.wip := GetL(ip, 12); k^.rip := GetL(ip, 16);
  k^.wport := GetW(ip, hl); k^.rport := GetW(ip, hl + 2);
  k^.rcvNxt := GetL(ip, hl + 4) + 1;
  issCtr := issCtr + 250000 + StNow * 4;
  k^.iss := issCtr; k^.sndUna := k^.iss; k^.sndNxt := k^.iss + 1;
  k^.wnd := GetW(ip, hl + 14);
  k^.lastAct := StNow; k^.rtxAt := StNow;
  Inc(St.tcpOpened);
  SendTcp(k^, $12, k^.iss, nil, 0, True);
  { OPEN: id, address, port }
  OutB[0] := 1; OutB[1] := id + 1;
  PutL(@OutB, 2, k^.rip); PutW(@OutB, 6, k^.rport);
  Enq(@OutB, 8);
end;

procedure TcpIn(ip: PByte; hl, tl: Integer);
var th, plen, skip, take, i: Integer; flags: Byte; seq, ack: LongWord; wip, rip: LongWord; ci: Integer; k: ^TConn;
    payload: PByte; sendAckNow: Boolean; acked: LongWord; dataAcked: Integer;
begin
  if tl - hl < 20 then Exit;
  th := (ip[hl + 12] shr 4) * 4;
  if (th < 20) or (hl + th > tl) then Exit;
  flags := ip[hl + 13];
  seq := GetL(ip, hl + 4); ack := GetL(ip, hl + 8);
  plen := tl - hl - th; payload := @ip[hl + th];
  wip := GetL(ip, 12); rip := GetL(ip, 16);
  ci := FindConn(wip, rip, GetW(ip, hl), GetW(ip, hl + 2));
  if ci < 0 then
  begin
    if ((flags and 2) <> 0) and ((flags and $14) = 0) then NewConn(ip, hl, tl)
    else SendRstFor(ip, hl, tl);
    Exit;
  end;
  k := @C[ci];
  k^.lastAct := StNow;
  if (flags and 4) <> 0 then begin Inc(St.tcpReset); FreeConn(k^, True); Exit; end;
  if (flags and 2) <> 0 then
  begin
    if (k^.state = 1) and (seq + 1 = k^.rcvNxt) then SendTcp(k^, $12, k^.iss, nil, 0, True);
    Exit;
  end;
  if (flags and $10) = 0 then Exit;
  k^.wnd := GetW(ip, hl + 14);
  if (k^.state = 1) and (ack = k^.iss + 1) then k^.state := 2;
  if k^.state < 2 then Exit;
  { acknowledgement of our data / FIN }
  if SeqLT(k^.sndUna, ack) and SeqLE(ack, k^.sndNxt) then
  begin
    acked := ack - k^.sndUna;
    if k^.finSent and (ack = k^.sndNxt) then begin k^.finAcked := True; Dec(acked); end;
    dataAcked := Integer(acked);
    if dataAcked > k^.dnSent then dataAcked := k^.dnSent;
    k^.dnHead := (k^.dnHead + dataAcked) mod DNBUF;
    Dec(k^.dnN, dataAcked); Dec(k^.dnSent, dataAcked);
    k^.sndUna := ack;
    k^.rtxAt := StNow;
  end;
  { data and FIN from Windows }
  sendAckNow := False;
  if (plen > 0) or ((flags and 1) <> 0) then
  begin
    skip := LongInt(k^.rcvNxt - seq);
    if (skip >= 0) and (skip <= plen) then
    begin
      take := plen - skip;
      if take > UpFree(k^) then take := UpFree(k^);
      for i := 0 to take - 1 do
        k^.up[(k^.upHead + k^.upN + i) mod UPBUF] := payload[skip + i];
      Inc(k^.upN, take);
      k^.rcvNxt := k^.rcvNxt + LongWord(take);
      if ((flags and 1) <> 0) and (skip + take = plen) and (not k^.finRcvd) then
      begin k^.finRcvd := True; k^.rcvNxt := k^.rcvNxt + 1; end;
    end;
    sendAckNow := True;
  end;
  if sendAckNow then SendAck(k^);
  TcpSend(k^);
  if k^.finAcked and k^.finRcvd and (k^.upN = 0) and k^.closeUp then FreeConn(k^, True);
end;

{ ---------- DNS ---------- }

function LowerC(c: Byte): Byte;
begin
  if (c >= 65) and (c <= 90) then Result := c + 32 else Result := c;
end;

procedure DnsReply(wip, rip: LongWord; wport: Word; txid: Word; sec: PByte; secLen: Integer; cnt, rcode: Integer; const addr: array of LongWord);
var n, i: Integer; b: array[0..299] of Byte;
begin
  PutW(@b, 0, txid); PutW(@b, 2, $8180 or rcode);
  PutW(@b, 4, 1); PutW(@b, 6, cnt); PutW(@b, 8, 0); PutW(@b, 10, 0);
  Move(sec^, b[12], secLen);
  n := 12 + secLen;
  for i := 0 to cnt - 1 do
  begin
    b[n] := $C0; b[n + 1] := $0C;                    { name: the question's }
    PutW(@b, n + 2, 1); PutW(@b, n + 4, 1);          { A, IN }
    PutL(@b, n + 6, 300); PutW(@b, n + 10, 4);
    PutL(@b, n + 12, addr[i]);
    Inc(n, 16);
  end;
  SendUdp(rip, wip, 53, wport, @b, n);
end;

function CacheFind(name: PByte; nl: Integer): Integer;
var i, j: Integer; same: Boolean;
begin
  Result := -1;
  for i := 0 to DCACHE - 1 do
    if DC[i].used and (DC[i].nl = nl) then
    begin
      if SeqLT(DC[i].expires, StNow) then begin DC[i].used := False; Continue; end;
      same := True;
      for j := 0 to nl - 1 do if DC[i].name[j] <> name[j] then begin same := False; Break; end;
      if same then begin Result := i; Exit; end;
    end;
end;

procedure DnsIn(wip, rip: LongWord; wport: Word; d: PByte; len: Integer);
var i, p, nl, qt, ci, q, secLen: Integer; name: array[0..99] of Byte; txid: Word; m: array[0..127] of Byte; none: array[0..0] of LongWord;
begin
  if len < 17 then Exit;
  if (d[2] and $80) <> 0 then Exit;                  { not a question }
  if GetW(d, 4) <> 1 then Exit;
  txid := GetW(d, 0);
  p := 12; nl := 0;
  while (p < len) and (d[p] <> 0) do
  begin
    if (d[p] and $C0) <> 0 then Exit;
    if nl + d[p] + 1 > 99 then Exit;
    if nl > 0 then begin name[nl] := Ord('.'); Inc(nl); end;
    for i := 1 to d[p] do begin name[nl] := LowerC(d[p + i]); Inc(nl); end;
    p := p + d[p] + 1;
  end;
  if p + 5 > len then Exit;
  secLen := p + 1 + 4 - 12;
  if secLen > 128 then Exit;
  qt := GetW(d, p + 1);
  none[0] := 0;
  if qt <> 1 then begin DnsReply(wip, rip, wport, txid, @d[12], secLen, 0, 0, none); Exit; end;
  ci := CacheFind(@name, nl);
  if ci >= 0 then
  begin
    Inc(St.dnsCached);
    DnsReply(wip, rip, wport, txid, @d[12], secLen, DC[ci].cnt, 0, DC[ci].addr);
    Exit;
  end;
  { already asked? (Windows asks again after a second) }
  for q := 0 to MAXDQ - 1 do
    if DQ[q].used and (DQ[q].txid = txid) and (DQ[q].wport = wport) then Exit;
  q := -1;
  for i := 0 to MAXDQ - 1 do if not DQ[i].used then begin q := i; Break; end;
  if q < 0 then Exit;
  Inc(nextQid); if nextQid = 0 then nextQid := 1;
  DQ[q].used := True; DQ[q].qid := nextQid; DQ[q].txid := txid;
  DQ[q].wip := wip; DQ[q].rip := rip; DQ[q].wport := wport;
  Move(d[12], DQ[q].sec, secLen); DQ[q].secLen := secLen; DQ[q].at := StNow;
  m[0] := 5; m[1] := nextQid; m[2] := nl;
  Move(name, m[3], nl);
  Enq(@m, 3 + nl);
  Inc(St.dnsAsked);
end;

procedure DnsAnswer(qid, cnt: Integer; a: PByte);
var q, i, c: Integer; addr: array[0..3] of LongWord; nl: Integer; p: Integer;
begin
  q := -1;
  for i := 0 to MAXDQ - 1 do if DQ[i].used and (DQ[i].qid = qid) then begin q := i; Break; end;
  if q < 0 then Exit;
  if cnt > 4 then cnt := 4;
  for i := 0 to cnt - 1 do addr[i] := GetL(a, i * 4);
  { cache it: the name is in the question section }
  if cnt > 0 then
  begin
    c := -1;
    for i := 0 to DCACHE - 1 do if (not DC[i].used) or SeqLT(DC[i].expires, StNow) then begin c := i; Break; end;
    if c < 0 then c := (StNow div 1000) mod DCACHE;
    nl := 0; p := 0;
    while (p < DQ[q].secLen) and (DQ[q].sec[p] <> 0) do
    begin
      if nl > 0 then begin DC[c].name[nl] := Ord('.'); Inc(nl); end;
      for i := 1 to DQ[q].sec[p] do begin DC[c].name[nl] := LowerC(DQ[q].sec[p + i]); Inc(nl); end;
      p := p + DQ[q].sec[p] + 1;
    end;
    DC[c].nl := nl; DC[c].used := True; DC[c].cnt := cnt; DC[c].expires := StNow + DNS_TTL_MS;
    for i := 0 to cnt - 1 do DC[c].addr[i] := addr[i];
  end;
  if cnt > 0 then DnsReply(DQ[q].wip, DQ[q].rip, DQ[q].wport, DQ[q].txid, @DQ[q].sec, DQ[q].secLen, cnt, 0, addr)
  else DnsReply(DQ[q].wip, DQ[q].rip, DQ[q].wport, DQ[q].txid, @DQ[q].sec, DQ[q].secLen, 0, 3, addr);
  Inc(St.dnsAnswered);
  DQ[q].used := False;
end;

{ ---------- other UDP ---------- }

procedure UdpIn(ip: PByte; hl, tl: Integer);
var sp, dp, ul, i, x: Integer; wip, rip: LongWord; m: array[0..279] of Byte;
begin
  if tl - hl < 8 then Exit;
  sp := GetW(ip, hl); dp := GetW(ip, hl + 2); ul := GetW(ip, hl + 4) - 8;
  if (ul < 0) or (hl + 8 + ul > tl) then Exit;
  wip := GetL(ip, 12); rip := GetL(ip, 16);
  if dp = 53 then begin DnsIn(wip, rip, sp, @ip[hl + 8], ul); Exit; end;
  if (rip = $FFFFFFFF) or ((rip and 255) = 255) or (rip shr 28 = 14) then Exit;      { broadcast, multicast }
  if (dp >= 137) and (dp <= 139) then Exit;
  if ul > 200 then Exit;
  x := -1;
  for i := 0 to MAXU - 1 do
    if UX[i].used and (UX[i].wip = wip) and (UX[i].rip = rip) and (UX[i].wport = sp) and (UX[i].rport = dp) then begin x := i; Break; end;
  if x < 0 then
    for i := 0 to MAXU - 1 do if not UX[i].used then begin x := i; Break; end;
  if x < 0 then Exit;
  UX[x].used := True; UX[x].wip := wip; UX[x].rip := rip; UX[x].wport := sp; UX[x].rport := dp;
  UX[x].until_ := StNow + 8000;
  m[0] := 6; m[1] := x + 1; PutL(@m, 2, rip); PutW(@m, 6, dp); m[8] := ul;
  Move(ip[hl + 8], m[9], ul);
  Enq(@m, 9 + ul);
  Inc(St.udpOut);
end;

{ ---------- IP from Windows ---------- }

procedure StIpIn(p: PByte; len: Integer);
var hl, tl: Integer; proto: Byte;
begin
  Inc(St.ipIn);
  if len < 20 then Exit;
  if (p[0] shr 4) <> 4 then Exit;
  hl := (p[0] and 15) * 4; tl := GetW(p, 2);
  if (hl < 20) or (tl > len) or (tl < hl) then Exit;
  if (GetW(p, 6) and $3FFF) <> 0 then Exit;            { fragments are not handled }
  proto := p[9];
  if proto = 6 then TcpIn(p, hl, tl)
  else if proto = 17 then UdpIn(p, hl, tl);
end;

{ ---------- messages down (from the gateway) ---------- }

{ the length of the message at the start of rb, -1 if more is needed, -2 if unknown }
function DownLen: Integer;
begin
  Result := -1;
  if rbN = 0 then Exit;
  case rb[0] of
    $81, $83, $87: Result := 2;
    $82, $86: if rbN >= 3 then Result := 3 + rb[2];
    $84: Result := 3;
    $85: if rbN >= 3 then Result := 3 + rb[2] * 4;
  else Result := -2;
  end;
end;

{ use one complete message; False if it cannot be used yet (no room) }
function UseDown(m: PByte; n: Integer): Boolean;
var k: ^TConn; i, id: Integer;
begin
  Result := True;
  case m[0] of
    $81: begin
           id := m[1]; if (id >= 1) and (id <= MAXC) and (C[id - 1].state <> 0) then C[id - 1].opened := True;
         end;
    $82: begin
           id := m[1];
           if (id >= 1) and (id <= MAXC) and (C[id - 1].state <> 0) then
           begin
             k := @C[id - 1];
             if DNBUF - k^.dnN < m[2] then begin Result := False; Exit; end;
             RingPutDn(k^, @m[3], m[2]);
             k^.lastAct := StNow;
             Inc(St.bytesDown, m[2]);
             TcpSend(k^);
           end;
         end;
    $83: begin
           id := m[1];
           if (id >= 1) and (id <= MAXC) and (C[id - 1].state <> 0) then
           begin C[id - 1].gwClose := True; TcpSend(C[id - 1]); end;
         end;
    $84: begin
           id := m[1];
           if (id >= 1) and (id <= MAXC) and (C[id - 1].state <> 0) then
           begin
             k := @C[id - 1];
             SendTcp(k^, $14, k^.sndNxt, nil, 0, False);
             Inc(St.tcpReset);
             FreeConn(k^, False);
           end;
         end;
    $85: DnsAnswer(m[1], m[2], @m[3]);
    $86: begin
           id := m[1];
           if (id >= 1) and (id <= MAXU) and UX[id - 1].used then
           begin
             SendUdp(UX[id - 1].rip, UX[id - 1].wip, UX[id - 1].rport, UX[id - 1].wport, @m[3], m[2]);
             Inc(St.udpIn);
           end;
         end;
    $87: gotHello := True;
  end;
end;

procedure ParseDown;
var n: Integer;
begin
  while True do
  begin
    n := DownLen;
    if n = -2 then begin rbN := 0; Exit; end;       { unknown: drop what we have }
    if (n < 0) or (rbN < n) then Exit;
    if not UseDown(@rb[0], n) then Exit;
    Move(rb[n], rb[0], rbN - n);
    Dec(rbN, n);
  end;
end;

function LinkData(b: PByte; len: Integer): Integer;
begin
  Result := SizeOf(rb) - rbN;
  if len < Result then Result := len;
  if Result <= 0 then begin Result := 0; Exit; end;
  Move(b^, rb[rbN], Result);
  Inc(rbN, Result);
  ParseDown;
end;

{ the gateway or we started anew: nothing of the old connections is left }
procedure LinkReset;
var i: Integer;
begin
  for i := 0 to MAXC - 1 do
    if C[i].state <> 0 then
    begin
      SendTcpRaw(C[i].rip, C[i].wip, C[i].rport, C[i].wport, $14, C[i].sndNxt, C[i].rcvNxt, 0, nil, 0, False);
      C[i].state := 0;
    end;
  for i := 0 to MAXDQ - 1 do DQ[i].used := False;
  for i := 0 to MAXU - 1 do UX[i].used := False;
  cqN := 0; rbN := 0;
  EnqHello;
end;

{ ---------- pumping up ---------- }

procedure StPump;
var i, j, n, ln, chunk: Integer; m: array[0..2] of Byte; tmp: array[0..199] of Byte; k: ^TConn; moved: Boolean;
begin
  ParseDown;
  { control messages first, in order }
  while cqN > 0 do
  begin
    ln := (cq[0] shl 8) or cq[1];
    if LkFree(Lk) < ln then Break;
    LkWrite(Lk, @cq[2], ln);
    Inc(St.bytesUp, ln);
    Move(cq[2 + ln], cq[0], cqN - 2 - ln);
    Dec(cqN, 2 + ln);
  end;
  if cqN > 0 then Exit;
  { data of the connections, a turn each }
  for j := 0 to MAXC - 1 do
  begin
    i := (rrConn + j) mod MAXC;
    k := @C[i];
    if k^.state < 1 then Continue;
    moved := False;
    while (k^.upN > 0) and (LkPending(Lk) < UP_LIMIT) do
    begin
      chunk := k^.upN; if chunk > 200 then chunk := 200;
      if LkFree(Lk) < chunk + 3 then Break;
      for n := 0 to chunk - 1 do tmp[n] := k^.up[(k^.upHead + n) mod UPBUF];
      m[0] := 2; m[1] := i + 1; m[2] := chunk;
      LkWrite(Lk, @m, 3); LkWrite(Lk, @tmp, chunk);
      Inc(St.bytesUp, chunk + 3);
      k^.upHead := (k^.upHead + chunk) mod UPBUF; Dec(k^.upN, chunk);
      moved := True;
    end;
    if moved then SendAck(k^);                      { window update }
    if k^.finRcvd and (k^.upN = 0) and (not k^.closeUp) and (LkFree(Lk) >= 2) then
    begin
      m[0] := 3; m[1] := i + 1; LkWrite(Lk, @m, 2); Inc(St.bytesUp, 2);
      k^.closeUp := True;
      if k^.finAcked then FreeConn(k^, True);
    end;
  end;
  rrConn := (rrConn + 1) mod MAXC;
end;

procedure StTick(now: LongWord);
var i: Integer; k: ^TConn;
begin
  StNow := now;
  for i := 0 to MAXC - 1 do
  begin
    k := @C[i];
    if k^.state = 0 then Continue;
    if (now - k^.lastAct) > IDLE_MS then
    begin
      SendTcp(k^, $14, k^.sndNxt, nil, 0, False);
      FreeConn(k^, True); Continue;
    end;
    if (k^.state = 1) and ((now - k^.rtxAt) > 3000) then
    begin SendTcp(k^, $12, k^.iss, nil, 0, True); k^.rtxAt := now; end;
    if (k^.state = 2) and ((k^.dnSent > 0) or (k^.finSent and not k^.finAcked)) and ((now - k^.rtxAt) > 3000) then
    begin
      k^.dnSent := 0; k^.sndNxt := k^.sndUna;
      if k^.finSent and (not k^.finAcked) then k^.finSent := False;
      k^.rtxAt := now;
      TcpSend(k^);
    end;
  end;
  for i := 0 to MAXDQ - 1 do
    if DQ[i].used and ((now - DQ[i].at) > 30000) then
    begin
      DnsAnswer(DQ[i].qid, 0, nil);
    end;
  for i := 0 to MAXU - 1 do
    if UX[i].used and SeqLT(UX[i].until_, now) then UX[i].used := False;
end;

function StConns: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to MAXC - 1 do if C[i].state <> 0 then Inc(Result);
end;

function StUpWaiting: Boolean;
var i: Integer;
begin
  Result := cqN > 0;
  for i := 0 to MAXC - 1 do
    if (C[i].state <> 0) and ((C[i].upN > 0) or (C[i].finRcvd and not C[i].closeUp)) then Result := True;
end;

function StActive: Boolean;
var i: Integer;
begin
  Result := (cqN > 0) or (StConns > 0);
  for i := 0 to MAXDQ - 1 do if DQ[i].used then Result := True;
  for i := 0 to MAXU - 1 do if UX[i].used then Result := True;
end;

procedure StInit(seed: LongWord);
begin
  FillChar(C, SizeOf(C), 0);
  FillChar(DQ, SizeOf(DQ), 0);
  FillChar(UX, SizeOf(UX), 0);
  FillChar(DC, SizeOf(DC), 0);
  FillChar(St, SizeOf(St), 0);
  cqN := 0; rbN := 0; ipId := seed and $FFFF; issCtr := seed * 7919; nextQid := 0; rrConn := 0;
  gotHello := False;
  LkInit(Lk, seed, @LinkData, @LinkReset);
  EnqHello;
end;

end.
