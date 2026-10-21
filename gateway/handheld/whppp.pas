unit whppp;
{ The far end of a PPP link, as a dial-up server: answers LCP, then IPCP with
  an address for the Jornada, so Windows CE dial-up reaches "Connected".
  Used by COM Probe 1.5 on WSP1:, the far end of the HPC Whisper port.

  Runs in a thread made with CreateThread, so it uses no strings and no heap:
  fixed arrays and numbers only. No Windows calls: the same code is tested on
  Linux (tests/ppptest.pas).

  What 1.4 saw on the device: Windows CE sends an LCP Configure-Request with
  ACCM 00000000, Protocol-Field-Compression and Address-and-Control-Field-
  Compression, every 3 s, same id. No MRU, magic number or authentication.

  What this end does:
  - HDLC-like framing (RFC 1662): 7E flags, 7D escapes, FCS-16 checked on
    every frame received. Frames sent always carry FF 03 and a two-byte
    protocol, and escape every byte below 20 (always allowed).
  - LCP (RFC 1661): acks MRU, ACCM, magic number, PFC and ACFC; rejects
    anything else (authentication included: this end asks for none). Sends an
    empty Configure-Request of its own. Answers Echo-Request and
    Terminate-Request; Code-Reject for unknown codes; Identification and
    Time-Remaining (Microsoft sends these) are ignored.
  - IPCP (RFC 1332, 1877): gives the Jornada PEER_IP and DNS_IP by
    Configure-Nak; rejects VJ compression, secondary DNS and WINS. Its own
    request carries OUR_IP.
  - Any other protocol once LCP is open (CCP, IPv6CP, NetBEUI...): LCP
    Protocol-Reject, so dial-up stops waiting for it.
  - IP packets once IPCP is open: counted and the first ones kept; an ICMP
    echo request to OUR_IP is answered. }
{$mode objfpc}
{$R-}{$Q-}

interface

const
  { 192.168.55.1 is this end; the Jornada gets 192.168.55.2 }
  OUR_IP  = $C0A83701;
  PEER_IP = $C0A83702;
  DNS_IP  = $C0A83701;

  PROTO_IP   = $0021;
  PROTO_LCP  = $C021;
  PROTO_IPCP = $8021;

  MAXFRAME = 1600;              { longest frame accepted, without flags }
  PLOGMAX = 128;                { packets kept in the log }
  PLOGBYTES = 48;               { bytes of each packet kept }
  IPLOGMAX = 16;
  RESEND_MS = 3000;
  MAX_TRIES = 10;

  DIR_IN = 1; DIR_OUT = 2;

type
  { one packet, in or out: the protocol and the bytes after the protocol
    field (code, id, length, data for LCP and IPCP) }
  TPppEvent = record
    Tick, Dir, Proto, Len: LongWord;
    Data: array[0..PLOGBYTES - 1] of Byte;
  end;

  { the start of an IP packet the Jornada sent }
  TIpSeen = record
    Tick, Len, Proto, Src, Dst, SPort, DPort: LongWord;
  end;

  TPppOutProc = procedure(buf: PByte; len: LongWord);

  TPppStats = record
    BytesIn, FramesIn, BadFcs, TooLong, Runts, FramesOut, BytesOut: LongWord;
    LcpReqIn, LcpAckIn, LcpNakIn, LcpRejIn, LcpReqOut, LcpAckOut, LcpRejOut: LongWord;
    IpcpReqIn, IpcpAckIn, IpcpNakIn, IpcpRejIn, IpcpReqOut, IpcpAckOut, IpcpNakOut, IpcpRejOut: LongWord;
    EchoIn, TermIn, CodeRejOut, ProtoRejOut, ProtoRejIn, CodeRejIn, Ignored: LongWord;
    IpIn, IcmpEchoIn, IcmpReplyOut: LongWord;
    LcpOpen, IpcpOpen: LongWord;          { 1 while open }
    LcpOpenAt, IpcpOpenAt, TermAt: LongWord;   { tick when it happened, 0 = not yet }
    PeerIp, OurIp, PeerMagic, PeerAccm, PeerMru: LongWord;
    LastRejProto: LongWord;
  end;

type
  TPppIpProc = procedure(p: PByte; len: Integer);

var
  PppOut: TPppOutProc = nil;
  { every IP packet the Jornada sent goes here first (Whisper Net's stack) }
  PppIpHook: TPppIpProc = nil;
  PS: TPppStats;
  PEv: array[0..PLOGMAX - 1] of TPppEvent;
  PEvN: LongWord;               { packets logged; the log keeps the first PLOGMAX }
  IpSeen: array[0..IPLOGMAX - 1] of TIpSeen;
  IpSeenN: LongWord;

procedure PppReset;
{ an IP packet to the Jornada }
procedure PppSendIp(p: PByte; len: Integer);
{ bytes as they came off the line }
procedure PppInput(buf: PByte; n, now: LongWord);
{ call often (every 50 ms or so): resends unanswered requests }
procedure PppTick(now: LongWord);
{ FCS-16 over a buffer, starting from fcs (use $FFFF); exposed for the test }
function PppFcs(fcs: LongWord; buf: PByte; n: LongWord): LongWord;

implementation

var
  FcsTab: array[0..255] of Word;
  RxBuf: array[0..MAXFRAME + 7] of Byte;
  RxLen: LongWord;
  RxIn, RxEsc, RxOver: Boolean;
  TxRaw: array[0..MAXFRAME + 7] of Byte;
  TxBuf: array[0..2 * (MAXFRAME + 8) + 3] of Byte;
  Pkt: array[0..MAXFRAME + 7] of Byte;      { building a packet to send }
  Opts: array[0..MAXFRAME + 7] of Byte;     { options for an answer }
  NowT: LongWord;

  NextId: Byte;
  LcpReqSent, LcpAckRcvd, LcpAckSent: Boolean;
  LcpReqId: Byte; LcpReqAt, LcpTries: LongWord;
  IpcpReqSent, IpcpAckRcvd, IpcpAckSent: Boolean;
  IpcpReqId: Byte; IpcpReqAt, IpcpTries: LongWord;
  IpcpAskAddr: Boolean;                     { our request carries OurIp }

{ ---------- FCS and framing ---------- }

procedure MakeTable;
var i, b, v: LongWord;
begin
  for i := 0 to 255 do
  begin
    v := i;
    for b := 1 to 8 do
      if (v and 1) <> 0 then v := (v shr 1) xor $8408 else v := v shr 1;
    FcsTab[i] := v;
  end;
end;

function PppFcs(fcs: LongWord; buf: PByte; n: LongWord): LongWord;
var i: LongWord;
begin
  i := 0;
  while i < n do
  begin
    fcs := (fcs shr 8) xor FcsTab[(fcs xor buf[i]) and $FF];
    Inc(i);
  end;
  Result := fcs and $FFFF;
end;

function GetW(p: PByte; off: LongWord): LongWord;
begin
  Result := (LongWord(p[off]) shl 8) or p[off + 1];
end;

function GetL(p: PByte; off: LongWord): LongWord;
begin
  Result := (LongWord(p[off]) shl 24) or (LongWord(p[off + 1]) shl 16) or
            (LongWord(p[off + 2]) shl 8) or p[off + 3];
end;

procedure PutW(p: PByte; off, v: LongWord);
begin
  p[off] := (v shr 8) and $FF; p[off + 1] := v and $FF;
end;

procedure PutL(p: PByte; off, v: LongWord);
begin
  p[off] := (v shr 24) and $FF; p[off + 1] := (v shr 16) and $FF;
  p[off + 2] := (v shr 8) and $FF; p[off + 3] := v and $FF;
end;

procedure LogPkt(dir, proto: LongWord; info: PByte; len: LongWord);
var i, k: LongWord;
begin
  if PEvN < PLOGMAX then
  begin
    i := PEvN;
    PEv[i].Tick := NowT; PEv[i].Dir := dir; PEv[i].Proto := proto; PEv[i].Len := len;
    FillChar(PEv[i].Data, PLOGBYTES, 0);
    k := len; if k > PLOGBYTES then k := PLOGBYTES;
    if k > 0 then Move(info^, PEv[i].Data, k);
  end;
  Inc(PEvN);
end;

{ Sends one packet: FF 03, protocol, info, FCS; every byte below 20, 7D and
  7E escaped; a flag at each end. }
procedure SendPkt(proto: LongWord; info: PByte; len: LongWord);
var n, i, o, fcs: LongWord; c: Byte;
begin
  if len > MAXFRAME - 6 then len := MAXFRAME - 6;
  LogPkt(DIR_OUT, proto, info, len);
  TxRaw[0] := $FF; TxRaw[1] := $03;
  PutW(@TxRaw, 2, proto);
  if len > 0 then Move(info^, TxRaw[4], len);
  n := 4 + len;
  fcs := PppFcs($FFFF, @TxRaw, n) xor $FFFF;
  TxRaw[n] := fcs and $FF; TxRaw[n + 1] := (fcs shr 8) and $FF;
  n := n + 2;
  o := 0;
  TxBuf[o] := $7E; Inc(o);
  i := 0;
  while i < n do
  begin
    c := TxRaw[i];
    if (c < $20) or (c = $7D) or (c = $7E) then
    begin
      TxBuf[o] := $7D; TxBuf[o + 1] := c xor $20; o := o + 2;
    end
    else begin TxBuf[o] := c; Inc(o); end;
    Inc(i);
  end;
  TxBuf[o] := $7E; Inc(o);
  Inc(PS.FramesOut);
  PS.BytesOut := PS.BytesOut + o;
  if Assigned(PppOut) then PppOut(@TxBuf, o);
end;

{ An LCP or IPCP packet: code, id, length, data }
procedure SendCtl(proto, code, id: LongWord; data: PByte; dlen: LongWord);
begin
  if dlen > MAXFRAME - 16 then dlen := MAXFRAME - 16;
  Pkt[0] := code; Pkt[1] := id;
  PutW(@Pkt, 2, dlen + 4);
  if dlen > 0 then Move(data^, Pkt[4], dlen);
  SendPkt(proto, @Pkt, dlen + 4);
end;

function NewId: Byte;
begin
  Inc(NextId);
  if NextId = 0 then NextId := 1;
  Result := NextId;
end;

{ ---------- LCP ---------- }

procedure IpcpDown;
begin
  IpcpReqSent := False; IpcpAckRcvd := False; IpcpAckSent := False;
  IpcpTries := 0; PS.IpcpOpen := 0;
end;

procedure SendLcpReq;
begin
  { empty: every option at its default; this end asks for no authentication }
  SendCtl(PROTO_LCP, 1, LcpReqId, nil, 0);
  LcpReqSent := True; LcpReqAt := NowT; Inc(LcpTries);
  Inc(PS.LcpReqOut);
end;

procedure SendIpcpReq;
var o: array[0..5] of Byte; n: LongWord;
begin
  n := 0;
  if IpcpAskAddr then
  begin
    o[0] := 3; o[1] := 6; PutL(@o, 2, PS.OurIp); n := 6;
  end;
  SendCtl(PROTO_IPCP, 1, IpcpReqId, @o, n);
  IpcpReqSent := True; IpcpReqAt := NowT; Inc(IpcpTries);
  Inc(PS.IpcpReqOut);
end;

procedure CheckOpen;
begin
  if (PS.LcpOpen = 0) and LcpAckRcvd and LcpAckSent then
  begin
    PS.LcpOpen := 1;
    if PS.LcpOpenAt = 0 then PS.LcpOpenAt := NowT;
    { network phase: no authentication, so IPCP starts at once }
    IpcpDown;
    IpcpReqId := NewId;
    SendIpcpReq;
  end;
  if (PS.LcpOpen = 1) and (PS.IpcpOpen = 0) and IpcpAckRcvd and IpcpAckSent then
  begin
    PS.IpcpOpen := 1;
    if PS.IpcpOpenAt = 0 then PS.IpcpOpenAt := NowT;
  end;
end;

procedure LcpDown;
begin
  PS.LcpOpen := 0;
  LcpReqSent := False; LcpAckRcvd := False; LcpAckSent := False; LcpTries := 0;
  IpcpDown;
end;

procedure LcpConfReq(id: Byte; data: PByte; dlen: LongWord);
var p, t, l, nrej: LongWord;
begin
  Inc(PS.LcpReqIn);
  if PS.LcpOpen = 1 then LcpDown;           { the peer starts over: so do we }
  { check the options; collect the ones we do not take }
  nrej := 0; p := 0;
  while p + 2 <= dlen do
  begin
    t := data[p]; l := data[p + 1];
    if (l < 2) or (p + l > dlen) then Exit;  { malformed: drop the packet }
    case t of
      1: if l <> 4 then t := 0 else PS.PeerMru := GetW(data, p + 2);
      2: if l <> 6 then t := 0 else PS.PeerAccm := GetL(data, p + 2);
      5: if l <> 6 then t := 0 else PS.PeerMagic := GetL(data, p + 2);
      7, 8: if l <> 2 then t := 0;
    else
      t := 0;                                { authentication and the rest }
    end;
    if t = 0 then
    begin
      Move(data[p], Opts[nrej], l); nrej := nrej + l;
    end;
    p := p + l;
  end;
  if not LcpReqSent then
  begin
    LcpReqId := NewId; LcpTries := 0;
    SendLcpReq;
  end;
  if nrej > 0 then
  begin
    SendCtl(PROTO_LCP, 4, id, @Opts, nrej);
    Inc(PS.LcpRejOut);
    LcpAckSent := False;
  end
  else
  begin
    SendCtl(PROTO_LCP, 2, id, data, dlen);
    Inc(PS.LcpAckOut);
    LcpAckSent := True;
  end;
  CheckOpen;
end;

procedure LcpPacket(info: PByte; len: LongWord);
var code, id, plen: LongWord; data: PByte; dlen: LongWord;
begin
  if len < 4 then begin Inc(PS.Runts); Exit; end;
  code := info[0]; id := info[1]; plen := GetW(info, 2);
  if (plen < 4) or (plen > len) then begin Inc(PS.Runts); Exit; end;
  data := info + 4; dlen := plen - 4;
  case code of
    1: LcpConfReq(id, data, dlen);
    2: begin
         Inc(PS.LcpAckIn);
         if LcpReqSent and (id = LcpReqId) then begin LcpAckRcvd := True; CheckOpen; end;
       end;
    3, 4: begin
         if code = 3 then Inc(PS.LcpNakIn) else Inc(PS.LcpRejIn);
         { our request is empty, so there is nothing to change: ask again }
         if LcpReqSent and (id = LcpReqId) and (LcpTries < MAX_TRIES) then
         begin LcpReqId := NewId; SendLcpReq; end;
       end;
    5: begin
         Inc(PS.TermIn);
         if PS.TermAt = 0 then PS.TermAt := NowT;
         SendCtl(PROTO_LCP, 6, id, nil, 0);
         LcpDown;
       end;
    6: ;                                     { Terminate-Ack: nothing to do }
    7: Inc(PS.CodeRejIn);
    8: begin
         Inc(PS.ProtoRejIn);
         if dlen >= 2 then PS.LastRejProto := GetW(data, 0);
       end;
    9: begin
         Inc(PS.EchoIn);
         if (PS.LcpOpen = 1) and (dlen >= 4) then
         begin
           Move(data^, Opts, dlen);
           PutL(@Opts, 0, 0);                { our magic number: none }
           SendCtl(PROTO_LCP, 10, id, @Opts, dlen);
         end;
       end;
    10, 11, 12, 13: Inc(PS.Ignored);         { Echo-Reply, Discard, Identification, Time-Remaining }
  else
    begin
      { Code-Reject carries the whole rejected packet }
      SendCtl(PROTO_LCP, 7, NewId, info, plen);
      Inc(PS.CodeRejOut);
    end;
  end;
end;

{ ---------- IPCP ---------- }

procedure IpcpConfReq(id: Byte; data: PByte; dlen: LongWord);
var p, t, l, nrej, nnak, v: LongWord;
    naks: array[0..63] of Byte;
begin
  Inc(PS.IpcpReqIn);
  if PS.IpcpOpen = 1 then
  begin
    PS.IpcpOpen := 0; IpcpAckRcvd := False; IpcpAckSent := False;
    IpcpReqId := NewId; IpcpTries := 0; SendIpcpReq;
  end;
  nrej := 0; nnak := 0; p := 0;
  while p + 2 <= dlen do
  begin
    t := data[p]; l := data[p + 1];
    if (l < 2) or (p + l > dlen) then Exit;
    case t of
      3, 129:                                { the Jornada's address; primary DNS }
        if l <> 6 then
        begin Move(data[p], Opts[nrej], l); nrej := nrej + l; end
        else
        begin
          if t = 3 then v := PS.PeerIp else v := DNS_IP;
          if GetL(data, p + 2) <> v then
            if nnak + 6 <= SizeOf(naks) then
            begin
              naks[nnak] := t; naks[nnak + 1] := 6; PutL(@naks, nnak + 2, v);
              nnak := nnak + 6;
            end;
        end;
    else
      { 1 IP-Addresses, 2 VJ compression, 130 WINS, 131 secondary DNS, 132 WINS... }
      begin Move(data[p], Opts[nrej], l); nrej := nrej + l; end;
    end;
    p := p + l;
  end;
  if not IpcpReqSent then begin IpcpReqId := NewId; IpcpTries := 0; SendIpcpReq; end;
  if nrej > 0 then
  begin
    SendCtl(PROTO_IPCP, 4, id, @Opts, nrej); Inc(PS.IpcpRejOut); IpcpAckSent := False;
  end
  else if nnak > 0 then
  begin
    SendCtl(PROTO_IPCP, 3, id, @naks, nnak); Inc(PS.IpcpNakOut); IpcpAckSent := False;
  end
  else
  begin
    SendCtl(PROTO_IPCP, 2, id, data, dlen); Inc(PS.IpcpAckOut); IpcpAckSent := True;
  end;
  CheckOpen;
end;

procedure IpcpPacket(info: PByte; len: LongWord);
var code, id, plen, p, t, l: LongWord; data: PByte; dlen: LongWord;
begin
  if len < 4 then begin Inc(PS.Runts); Exit; end;
  code := info[0]; id := info[1]; plen := GetW(info, 2);
  if (plen < 4) or (plen > len) then begin Inc(PS.Runts); Exit; end;
  data := info + 4; dlen := plen - 4;
  case code of
    1: IpcpConfReq(id, data, dlen);
    2: begin
         Inc(PS.IpcpAckIn);
         if IpcpReqSent and (id = IpcpReqId) then begin IpcpAckRcvd := True; CheckOpen; end;
       end;
    3, 4: begin
         if code = 3 then Inc(PS.IpcpNakIn) else Inc(PS.IpcpRejIn);
         if IpcpReqSent and (id = IpcpReqId) and (IpcpTries < MAX_TRIES) then
         begin
           p := 0;
           while p + 2 <= dlen do
           begin
             t := data[p]; l := data[p + 1];
             if (l < 2) or (p + l > dlen) then Break;
             if t = 3 then
             begin
               if code = 4 then IpcpAskAddr := False
               else if (l = 6) and (GetL(data, p + 2) <> 0) then PS.OurIp := GetL(data, p + 2);
             end;
             p := p + l;
           end;
           IpcpReqId := NewId; SendIpcpReq;
         end;
       end;
    5: begin
         SendCtl(PROTO_IPCP, 6, id, nil, 0);
         PS.IpcpOpen := 0; IpcpAckRcvd := False; IpcpAckSent := False;
       end;
    6, 7: ;
  else
    begin
      SendCtl(PROTO_IPCP, 7, NewId, info, plen);
      Inc(PS.CodeRejOut);
    end;
  end;
end;

{ ---------- IP ---------- }

function IpSum(p: PByte; n: LongWord): LongWord;
var s, i: LongWord;
begin
  s := 0; i := 0;
  while i + 1 < n do begin s := s + GetW(p, i); i := i + 2; end;
  if i < n then s := s + (LongWord(p[i]) shl 8);
  while (s shr 16) <> 0 do s := (s and $FFFF) + (s shr 16);
  Result := (not s) and $FFFF;
end;

procedure IpPacket(info: PByte; len: LongWord);
var hl, tl, proto, src, dst, k: LongWord;
begin
  Inc(PS.IpIn);
  if len < 20 then Exit;
  if (info[0] shr 4) <> 4 then Exit;
  hl := (info[0] and $F) * 4; tl := GetW(info, 2);
  if (hl < 20) or (tl > len) or (tl < hl) then Exit;
  proto := info[9]; src := GetL(info, 12); dst := GetL(info, 16);
  if Assigned(PppIpHook) then PppIpHook(info, tl);
  if IpSeenN < IPLOGMAX then
  begin
    k := IpSeenN;
    IpSeen[k].Tick := NowT; IpSeen[k].Len := tl; IpSeen[k].Proto := proto;
    IpSeen[k].Src := src; IpSeen[k].Dst := dst; IpSeen[k].SPort := 0; IpSeen[k].DPort := 0;
    if ((proto = 6) or (proto = 17)) and (tl >= hl + 4) then
    begin IpSeen[k].SPort := GetW(info, hl); IpSeen[k].DPort := GetW(info, hl + 2); end
    else if (proto = 1) and (tl >= hl + 2) then
    begin IpSeen[k].SPort := info[hl]; IpSeen[k].DPort := info[hl + 1]; end;   { ICMP type, code }
  end;
  Inc(IpSeenN);
  { ICMP echo request to this end: answer it }
  if (proto = 1) and (dst = PS.OurIp) and (tl >= hl + 8) and (info[hl] = 8) and (PS.IpcpOpen = 1) then
  begin
    Inc(PS.IcmpEchoIn);
    Move(info^, Pkt, tl);
    PutL(@Pkt, 12, dst); PutL(@Pkt, 16, src);
    Pkt[8] := 64;                            { TTL }
    PutW(@Pkt, 10, 0); PutW(@Pkt, 10, IpSum(@Pkt, hl));
    Pkt[hl] := 0;                            { echo reply }
    PutW(@Pkt, hl + 2, 0); PutW(@Pkt, hl + 2, IpSum(@Pkt[hl], tl - hl));
    Move(Pkt, Opts, tl);
    SendPkt(PROTO_IP, @Opts, tl);
    Inc(PS.IcmpReplyOut);
  end;
end;

procedure PppSendIp(p: PByte; len: Integer);
begin
  if PS.IpcpOpen = 1 then SendPkt(PROTO_IP, p, len);
end;

{ ---------- frames ---------- }

procedure Frame;
var p, proto, n: LongWord;
begin
  if RxLen < 4 then begin if RxLen > 0 then Inc(PS.Runts); Exit; end;
  if PppFcs($FFFF, @RxBuf, RxLen) <> $F0B8 then begin Inc(PS.BadFcs); Exit; end;
  Inc(PS.FramesIn);
  n := RxLen - 2;
  p := 0;
  if (RxBuf[0] = $FF) and (RxBuf[1] = $03) then p := 2;
  if p >= n then begin Inc(PS.Runts); Exit; end;
  if (RxBuf[p] and 1) <> 0 then begin proto := RxBuf[p]; p := p + 1; end   { compressed protocol }
  else
  begin
    if p + 2 > n then begin Inc(PS.Runts); Exit; end;
    proto := GetW(@RxBuf, p); p := p + 2;
  end;
  LogPkt(DIR_IN, proto, @RxBuf[p], n - p);
  case proto of
    PROTO_LCP: LcpPacket(@RxBuf[p], n - p);
    PROTO_IPCP: if PS.LcpOpen = 1 then IpcpPacket(@RxBuf[p], n - p);
    PROTO_IP: if PS.IpcpOpen = 1 then IpPacket(@RxBuf[p], n - p);
  else
    if PS.LcpOpen = 1 then
    begin
      { Protocol-Reject: the protocol, then as much of the packet as fits }
      Opts[0] := (proto shr 8) and $FF; Opts[1] := proto and $FF;
      if n - p > 0 then Move(RxBuf[p], Opts[2], n - p);
      SendCtl(PROTO_LCP, 8, NewId, @Opts, 2 + n - p);
      Inc(PS.ProtoRejOut);
    end;
  end;
end;

procedure PppInput(buf: PByte; n, now: LongWord);
var i: LongWord; c: Byte;
begin
  NowT := now;
  PS.BytesIn := PS.BytesIn + n;
  i := 0;
  while i < n do
  begin
    c := buf[i];
    if c = $7E then
    begin
      if RxIn and not RxOver then Frame
      else if RxOver then Inc(PS.TooLong);
      RxIn := True; RxEsc := False; RxOver := False; RxLen := 0;
    end
    else if RxIn then
    begin
      if c = $7D then RxEsc := True
      else
      begin
        if RxEsc then begin c := c xor $20; RxEsc := False; end;
        if RxLen < MAXFRAME then begin RxBuf[RxLen] := c; Inc(RxLen); end
        else RxOver := True;
      end;
    end;
    Inc(i);
  end;
end;

procedure PppTick(now: LongWord);
begin
  NowT := now;
  if LcpReqSent and not LcpAckRcvd and (now - LcpReqAt >= RESEND_MS) and (LcpTries < MAX_TRIES) then
    SendLcpReq;
  if (PS.LcpOpen = 1) and IpcpReqSent and not IpcpAckRcvd and (now - IpcpReqAt >= RESEND_MS) and (IpcpTries < MAX_TRIES) then
    SendIpcpReq;
end;

procedure PppReset;
begin
  FillChar(PS, SizeOf(PS), 0);
  PS.OurIp := OUR_IP; PS.PeerIp := PEER_IP;
  PEvN := 0; IpSeenN := 0;
  RxLen := 0; RxIn := False; RxEsc := False; RxOver := False;
  NextId := 0; NowT := 0;
  LcpReqSent := False; LcpAckRcvd := False; LcpAckSent := False; LcpReqId := 0; LcpReqAt := 0; LcpTries := 0;
  IpcpReqSent := False; IpcpAckRcvd := False; IpcpAckSent := False; IpcpReqId := 0; IpcpReqAt := 0; IpcpTries := 0;
  IpcpAskAddr := True;
end;

initialization
  MakeTable;
  PppReset;
end.
