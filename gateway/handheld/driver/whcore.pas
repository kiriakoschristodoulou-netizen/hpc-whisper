unit whcore;
{ HPC Whisper virtual serial port, driver logic, version 1.5.
  1.5: the trace also records when a read starts (with the read timeouts in
  force), reads that end at once (no buffer, zero count), and all five
  timeout values given to SET_TIMEOUTS. (The 1.5 fix itself is in whcom.pas:
  every BOOL the driver returns is exactly 1 or 0.)
  1.4: the wait mask and its pending events belong to each open handle, as in
  a real serial driver. In 1.3 they were shared, so dial-up's data handle
  setting its mask woke the carrier-watch handle's wait, which dial-up read
  as the line dropping (error 619).
  1.3 adds a trace: while it is on, every call is recorded with its time,
  its arguments and its answer (IOC_WSP_TRACE_*).
  No Windows calls here: the same code is tested on Linux (tests/coretest.pas).
  Two faces share these pipes:
    COM  the serial port that programs and dial-up networking open
    WSP  the other end of the line (the Whisper side, or the probe's responder)
  Lessons from 1.0 and 1.1 on the device:
  - serial control codes are numbered from 1 on Windows CE (SET_DTR = 3);
  - nothing may wait without a way out: every blocking call ends on its own
    timeout, on a close of its handle, on a purge, or on the WSP abort call. }
{$mode objfpc}

interface

const
  WH_VERSION = 150;
  MAXDW = $FFFFFFFF;

  { serial control codes: (0x1B shl 16) or (n shl 2), n numbered from 1 }
  IOC_SET_BREAK_ON    = $1B0004;
  IOC_SET_BREAK_OFF   = $1B0008;
  IOC_SET_DTR         = $1B000C;
  IOC_CLR_DTR         = $1B0010;
  IOC_SET_RTS         = $1B0014;
  IOC_CLR_RTS         = $1B0018;
  IOC_SET_XOFF        = $1B001C;
  IOC_SET_XON         = $1B0020;
  IOC_GET_WAIT_MASK   = $1B0024;
  IOC_SET_WAIT_MASK   = $1B0028;
  IOC_WAIT_ON_MASK    = $1B002C;
  IOC_GET_COMMSTATUS  = $1B0030;
  IOC_GET_MODEMSTATUS = $1B0034;
  IOC_GET_PROPERTIES  = $1B0038;
  IOC_SET_TIMEOUTS    = $1B003C;
  IOC_GET_TIMEOUTS    = $1B0040;
  IOC_PURGE           = $1B0044;
  IOC_SET_QUEUE_SIZE  = $1B0048;
  IOC_IMMEDIATE_CHAR  = $1B004C;
  IOC_GET_DCB         = $1B0050;
  IOC_SET_DCB         = $1B0054;
  IOC_ENABLE_IR       = $1B0058;
  IOC_DISABLE_IR      = $1B005C;

  { the Whisper side's own calls }
  IOC_WSP_STATS    = $222000;   { out: TWhStats }
  IOC_WSP_CLEARLOG = $222004;
  IOC_WSP_ABORT    = $222008;   { ends every blocked call on the COM side }
  IOC_WSP_LOG      = $22200C;   { out: array of TWhLogEntry }
  IOC_WSP_TRACE_START = $222010;  { clears the trace and turns it on }
  IOC_WSP_TRACE_STOP  = $222014;
  IOC_WSP_TRACE_GET   = $222018;  { out: DWORD total recorded, then the first TTraceEntry records, oldest first }

  { trace entry kinds }
  TK_OPEN = 1; TK_CLOSE = 2; TK_READ = 3; TK_WRITE = 4; TK_IOCTL = 5;
  TK_WAIT_BEGIN = 6; TK_WAIT_END = 7; TK_WSP_WRITE = 8; TK_WSP_READ = 9;
  TK_READ_BEGIN = 10;   { Code = interval, Arg = count, Arg2 = multiplier, Ret = constant }
  TRACEMAX = 2000;             { the trace keeps the FIRST TRACEMAX entries (1.5) }

  EV_RXCHAR  = $0001;
  EV_TXEMPTY = $0004;
  EV_CTS     = $0008;
  EV_DSR     = $0010;
  EV_RLSD    = $0020;

  PURGE_TXABORT = 1;
  PURGE_RXABORT = 2;
  PURGE_TXCLEAR = 4;
  PURGE_RXCLEAR = 8;

  MODEM_LINES = $B0;            { CTS, DSR and RLSD on: the line is up }

  RING_SIZE = 65536;            { a power of two }
  RING_MASK = RING_SIZE - 1;
  LOGMAX = 32;
  MAXOPEN = 8;

  WRITE_CAP_MS = 10000;         { a write into a full pipe gives up after this }

type
  TRing = record
    Head, Tail: LongWord;       { Head: total bytes put; Tail: total bytes taken }
    Data: array[0..RING_SIZE - 1] of Byte;
  end;

  TWhStats = record
    Version, ComInits, WspInits, ComOpens, WspOpens: LongWord;
    ToPhoneBytes, FromPhoneBytes, ToPhoneQueued, FromPhoneQueued, Dropped: LongWord;
    Refused, Aborts, Dtr, Rts, Baud, WaitMask, LogCount, DtrDrops: LongWord;
  end;

  TWhLogEntry = record
    Code, Hits, LastIn, LastOut, LastRet, LastOk, Refused: LongWord;
  end;

  TTraceEntry = record
    Tick, Kind, Code, Arg, Arg2, Ret, Ok, Handle: LongWord;
  end;

  TSleepProc = procedure(ms: LongWord);
  TTickFunc = function: LongWord;

var
  SleepP: TSleepProc = nil;
  TickF: TTickFunc = nil;

function ComInit(ctx: LongWord): LongWord;
function ComDeinit(h: LongWord): Boolean;
function ComOpen(h, access, share: LongWord): LongWord;
function ComClose(h: LongWord): Boolean;
function ComRead(h: LongWord; buf: PByte; count: LongWord): LongWord;
function ComWrite(h: LongWord; buf: PByte; count: LongWord): LongWord;
function ComIOControl(h, code: LongWord; pin: PByte; lin: LongWord;
                      pout: PByte; lout: LongWord; pact: PLongWord): Boolean;

function WspInit(ctx: LongWord): LongWord;
function WspDeinit(h: LongWord): Boolean;
function WspOpen(h, access, share: LongWord): LongWord;
function WspClose(h: LongWord): Boolean;
function WspRead(h: LongWord; buf: PByte; count: LongWord): LongWord;
function WspWrite(h: LongWord; buf: PByte; count: LongWord): LongWord;
function WspIOControl(h, code: LongWord; pin: PByte; lin: LongWord;
                      pout: PByte; lout: LongWord; pact: PLongWord): Boolean;

procedure ResetAll;

implementation

const
  COMDEV = $57480001;
  WSPDEV = $57480002;
  COMOPEN_TAG = $57430000;      { + 1..MAXOPEN }
  WSPOPEN_TAG = $57530000;

var
  ToPhone, FromPhone: TRing;
  St: TWhStats;
  Log: array[0..LOGMAX - 1] of TWhLogEntry;
  OpenUsed: array[1..MAXOPEN] of Boolean;
  OpenClosed: array[1..MAXOPEN] of LongWord;   { generation: changes on close }
  WspIsOpen: Boolean;
  AbortGen, PurgeRxGen, PurgeTxGen: LongWord;
  { per open handle }
  HMask, MaskGen: array[1..MAXOPEN] of LongWord;
  RxPending, TxPending, LinePending: array[1..MAXOPEN] of Boolean;
  TOInterval, TOMult, TOConst, TOWMult, TOWConst: LongWord;
  Dcb: array[0..27] of Byte;
  Trace: array[0..TRACEMAX - 1] of TTraceEntry;
  TraceN: LongWord;               { entries recorded since the start; the first TRACEMAX are kept }
  TraceOn: Boolean;

{ ---------- helpers ---------- }

function Now: LongWord;
begin
  if Assigned(TickF) then Result := TickF() else Result := 0;
end;

procedure Nap(ms: LongWord);
begin
  if Assigned(SleepP) then SleepP(ms);
end;

function RingCount(const r: TRing): LongWord;
begin
  Result := r.Head - r.Tail;
end;

function RingPut(var r: TRing; buf: PByte; count: LongWord): LongWord;
var room, i, h: LongWord;
begin
  room := RING_SIZE - (r.Head - r.Tail);
  if count > room then count := room;
  h := r.Head;
  i := 0;
  while i < count do
  begin
    r.Data[(h + i) and RING_MASK] := buf[i];
    Inc(i);
  end;
  r.Head := h + count;
  Result := count;
end;

function RingGet(var r: TRing; buf: PByte; count: LongWord): LongWord;
var have, i, t: LongWord;
begin
  have := r.Head - r.Tail;
  if count > have then count := have;
  t := r.Tail;
  i := 0;
  while i < count do
  begin
    buf[i] := r.Data[(t + i) and RING_MASK];
    Inc(i);
  end;
  r.Tail := t + count;
  Result := count;
end;

procedure RingClear(var r: TRing);
begin
  r.Tail := r.Head;
end;

procedure PendRx;
var k: Integer;
begin
  for k := 1 to MAXOPEN do if OpenUsed[k] then RxPending[k] := True;
end;

procedure PendTx;
var k: Integer;
begin
  for k := 1 to MAXOPEN do if OpenUsed[k] then TxPending[k] := True;
end;

function GetDW(p: PByte; off: LongWord): LongWord;
begin
  Result := p[off] or (LongWord(p[off + 1]) shl 8) or (LongWord(p[off + 2]) shl 16) or (LongWord(p[off + 3]) shl 24);
end;

procedure PutDW(p: PByte; off, v: LongWord);
begin
  p[off] := v and $FF; p[off + 1] := (v shr 8) and $FF;
  p[off + 2] := (v shr 16) and $FF; p[off + 3] := (v shr 24) and $FF;
end;

procedure PutW(p: PByte; off, v: LongWord);
begin
  p[off] := v and $FF; p[off + 1] := (v shr 8) and $FF;
end;

procedure LogCall(code, lin, lout, ret: LongWord; ok: Boolean);
var i: LongWord;
begin
  i := 0;
  while i < St.LogCount do
  begin
    if Log[i].Code = code then Break;
    Inc(i);
  end;
  if i >= St.LogCount then
  begin
    if St.LogCount >= LOGMAX then Exit;
    FillChar(Log[i], SizeOf(TWhLogEntry), 0);
    Log[i].Code := code;
    Inc(St.LogCount);
  end;
  Inc(Log[i].Hits);
  Log[i].LastIn := lin; Log[i].LastOut := lout; Log[i].LastRet := ret;
  if ok then Log[i].LastOk := 1 else begin Log[i].LastOk := 0; Inc(Log[i].Refused); end;
end;

procedure Tr(kind, h, code, arg, arg2, ret: LongWord; ok: Boolean);
var i: LongWord;
begin
  if not TraceOn then Exit;
  i := TraceN;
  Inc(TraceN);
  if i >= TRACEMAX then Exit;       { full: count, but keep the start }
  Trace[i].Tick := Now; Trace[i].Kind := kind; Trace[i].Handle := h and $FFFF;
  Trace[i].Code := code; Trace[i].Arg := arg; Trace[i].Arg2 := arg2; Trace[i].Ret := ret;
  if ok then Trace[i].Ok := 1 else Trace[i].Ok := 0;
end;

function OpenIndex(h: LongWord): LongWord;
begin
  Result := 0;
  if (h and $FFFF0000) <> COMOPEN_TAG then Exit;
  if ((h and $FFFF) < 1) or ((h and $FFFF) > MAXOPEN) then Exit;
  if not OpenUsed[h and $FFFF] then Exit;
  Result := h and $FFFF;
end;

{ ---------- COM face ---------- }

function ComInit(ctx: LongWord): LongWord;
begin
  Inc(St.ComInits);
  St.Version := WH_VERSION;
  Result := COMDEV;
end;

function ComDeinit(h: LongWord): Boolean;
begin
  Inc(AbortGen);
  Result := h = COMDEV;
end;

function ComOpen(h, access, share: LongWord): LongWord;
var i: LongWord;
begin
  Result := 0;
  if h <> COMDEV then Exit;
  for i := 1 to MAXOPEN do
    if not OpenUsed[i] then
    begin
      OpenUsed[i] := True;
      HMask[i] := 0; Inc(MaskGen[i]);
      RxPending[i] := False; TxPending[i] := False; LinePending[i] := False;
      Inc(St.ComOpens);
      Result := COMOPEN_TAG + i;
      Tr(TK_OPEN, Result, 0, access, share, Result, True);
      Exit;
    end;
end;

function ComClose(h: LongWord): Boolean;
var i: LongWord;
begin
  i := OpenIndex(h);
  Result := i <> 0;
  if i = 0 then Exit;
  Inc(OpenClosed[i]);            { wakes any call still waiting on this handle }
  OpenUsed[i] := False;
  Tr(TK_CLOSE, h, 0, 0, 0, 0, True);
end;

function ComRead(h: LongWord; buf: PByte; count: LongWord): LongWord;
var
  i, got, n, start, last, total, gen, cgen, pgen: LongWord;
  immediate, firstonly: Boolean;
  t64: QWord;
begin
  Result := MAXDW;
  i := OpenIndex(h);
  if i = 0 then Exit;
  Result := 0;
  Tr(TK_READ_BEGIN, h, TOInterval, count, TOMult, TOConst, buf <> nil);
  if (count = 0) or (buf = nil) then begin Tr(TK_READ, h, 0, count, 0, 0, False); Exit; end;
  gen := AbortGen; cgen := OpenClosed[i]; pgen := PurgeRxGen;
  immediate := (TOInterval = MAXDW) and (TOMult = 0) and (TOConst = 0);
  firstonly := (TOInterval = MAXDW) and (TOMult = MAXDW) and (TOConst > 0) and (TOConst < MAXDW);
  if firstonly then total := TOConst
  else if immediate then total := 0
  else
  begin
    t64 := QWord(TOMult) * count + TOConst;
    if t64 >= MAXDW then total := MAXDW - 1 else total := LongWord(t64);
  end;
  got := 0; start := Now; last := start;
  repeat
    n := RingGet(FromPhone, buf + got, count - got);
    if n > 0 then begin got := got + n; last := Now; end;
    if got >= count then Break;
    if immediate then Break;
    if firstonly and (got > 0) then Break;
    if (TOInterval > 0) and (TOInterval <> MAXDW) and (got > 0) and (Now - last >= TOInterval) then Break;
    if (total > 0) and (Now - start >= total) then Break;
    if (AbortGen <> gen) or (OpenClosed[i] <> cgen) or (PurgeRxGen <> pgen) then Break;
    Nap(2);
  until False;
  Result := got;
  Tr(TK_READ, h, 0, count, Now - start, got, True);
end;

function ComWrite(h: LongWord; buf: PByte; count: LongWord): LongWord;
var
  i, put, n, start, total, gen, cgen, pgen: LongWord;
  t64: QWord;
begin
  Result := MAXDW;
  i := OpenIndex(h);
  if i = 0 then Exit;
  Result := 0;
  if (count = 0) or (buf = nil) then Exit;
  gen := AbortGen; cgen := OpenClosed[i]; pgen := PurgeTxGen;
  t64 := QWord(TOWMult) * count + TOWConst;
  if (t64 = 0) or (t64 > WRITE_CAP_MS) then total := WRITE_CAP_MS else total := LongWord(t64);
  put := 0; start := Now;
  repeat
    n := RingPut(ToPhone, buf + put, count - put);
    put := put + n;
    if put >= count then Break;
    if Now - start >= total then Break;
    if (AbortGen <> gen) or (OpenClosed[i] <> cgen) or (PurgeTxGen <> pgen) then Break;
    Nap(2);
  until False;
  St.ToPhoneBytes := St.ToPhoneBytes + put;
  if put > 0 then PendTx;
  Result := put;
  Tr(TK_WRITE, h, 0, count, Now - start, put, True);
end;

function WaitOnMask(i: LongWord; out ev: LongWord): Boolean;
var gen, cgen, mgen, mask: LongWord;
begin
  gen := AbortGen; cgen := OpenClosed[i]; mgen := MaskGen[i];
  mask := HMask[i];
  ev := 0;
  Result := True;
  if mask = 0 then Exit;
  repeat
    if ((mask and EV_RXCHAR) <> 0) and RxPending[i] then
    begin ev := ev or EV_RXCHAR; RxPending[i] := False; end;
    if ((mask and EV_TXEMPTY) <> 0) and TxPending[i] and (RingCount(ToPhone) = 0) then
    begin ev := ev or EV_TXEMPTY; TxPending[i] := False; end;
    if ((mask and (EV_CTS or EV_DSR or EV_RLSD)) <> 0) and LinePending[i] then
    begin ev := ev or (mask and (EV_CTS or EV_DSR or EV_RLSD)); LinePending[i] := False; end;
    if ev <> 0 then Break;
    if (AbortGen <> gen) or (OpenClosed[i] <> cgen) or (MaskGen[i] <> mgen) then Break;
    Nap(5);
  until False;
end;

function ComIOControl(h, code: LongWord; pin: PByte; lin: LongWord;
                      pout: PByte; lout: LongWord; pact: PLongWord): Boolean;
var i, ret, v, ev: LongWord;
begin
  Result := False; ret := 0;
  i := OpenIndex(h);
  if i = 0 then Exit;
  if pact <> nil then pact^ := 0;
  case code of
    IOC_SET_BREAK_ON, IOC_SET_BREAK_OFF, IOC_SET_XOFF, IOC_SET_XON,
    IOC_ENABLE_IR, IOC_DISABLE_IR:
      Result := True;
    IOC_SET_DTR: begin St.Dtr := 1; Result := True; end;
    IOC_CLR_DTR: begin if St.Dtr = 1 then Inc(St.DtrDrops); St.Dtr := 0; Result := True; end;
    IOC_SET_RTS: begin St.Rts := 1; Result := True; end;
    IOC_CLR_RTS: begin St.Rts := 0; Result := True; end;
    IOC_GET_WAIT_MASK:
      if (pout <> nil) and (lout >= 4) then
      begin PutDW(pout, 0, HMask[i]); ret := 4; Result := True; end;
    IOC_SET_WAIT_MASK:
      if (pin <> nil) and (lin >= 4) then
      begin
        HMask[i] := GetDW(pin, 0);
        St.WaitMask := HMask[i];   { the last one set, for the stats }
        RxPending[i] := RingCount(FromPhone) > 0;
        TxPending[i] := False; LinePending[i] := False;
        Inc(MaskGen[i]);           { a wait on THIS handle returns with no event }
        Result := True;
      end;
    IOC_WAIT_ON_MASK:
      if (pout <> nil) and (lout >= 4) then
      begin
        v := Now;
        Tr(TK_WAIT_BEGIN, h, code, HMask[i], 0, 0, True);
        WaitOnMask(i, ev);
        Tr(TK_WAIT_END, h, code, HMask[i], Now - v, ev, True);
        PutDW(pout, 0, ev); ret := 4; Result := True;
      end;
    IOC_GET_COMMSTATUS:
      { SERIAL_DEV_STATUS: Errors, then COMSTAT (flags, cbInQue, cbOutQue) }
      if (pout <> nil) and (lout >= 16) then
      begin
        FillChar(pout^, 16, 0);
        PutDW(pout, 8, RingCount(FromPhone));
        PutDW(pout, 12, RingCount(ToPhone));
        ret := 16; Result := True;
      end;
    IOC_GET_MODEMSTATUS:
      if (pout <> nil) and (lout >= 4) then
      begin PutDW(pout, 0, MODEM_LINES); ret := 4; Result := True; end;
    IOC_GET_PROPERTIES:
      if (pout <> nil) and (lout >= 64) then
      begin
        FillChar(pout^, 64, 0);
        PutW(pout, 0, 64);              { wPacketLength }
        PutW(pout, 2, 2);               { wPacketVersion }
        PutDW(pout, 4, 1);              { SP_SERIALCOMM }
        PutDW(pout, 12, RING_SIZE);     { dwMaxTxQueue }
        PutDW(pout, 16, RING_SIZE);     { dwMaxRxQueue }
        PutDW(pout, 20, $00020000);     { dwMaxBaud: 115200 }
        PutDW(pout, 24, 1);             { PST_RS232 }
        PutDW(pout, 28, $FF);           { DTR/DSR, RTS/CTS, RLSD, parity, XON/XOFF, timeouts }
        PutDW(pout, 32, $7F);           { settable parameters }
        PutDW(pout, 36, $00075F00 or $10000000 or $00020000 or $00040000);
        PutW(pout, 40, $000F);          { 5 to 8 data bits }
        PutW(pout, 42, $1F07);          { stop bits and parity }
        PutDW(pout, 44, RING_SIZE);
        PutDW(pout, 48, RING_SIZE);
        ret := 64; Result := True;
      end;
    IOC_SET_TIMEOUTS:
      if (pin <> nil) and (lin >= 20) then
      begin
        TOInterval := GetDW(pin, 0); TOMult := GetDW(pin, 4); TOConst := GetDW(pin, 8);
        TOWMult := GetDW(pin, 12); TOWConst := GetDW(pin, 16);
        Result := True;
      end;
    IOC_GET_TIMEOUTS:
      if (pout <> nil) and (lout >= 20) then
      begin
        PutDW(pout, 0, TOInterval); PutDW(pout, 4, TOMult); PutDW(pout, 8, TOConst);
        PutDW(pout, 12, TOWMult); PutDW(pout, 16, TOWConst);
        ret := 20; Result := True;
      end;
    IOC_PURGE:
      if (pin <> nil) and (lin >= 4) then
      begin
        v := GetDW(pin, 0);
        if (v and PURGE_RXABORT) <> 0 then Inc(PurgeRxGen);
        if (v and PURGE_TXABORT) <> 0 then Inc(PurgeTxGen);
        if (v and PURGE_RXCLEAR) <> 0 then
        begin
          RingClear(FromPhone);
          for ev := 1 to MAXOPEN do RxPending[ev] := False;
        end;
        if (v and PURGE_TXCLEAR) <> 0 then RingClear(ToPhone);
        Result := True;
      end;
    IOC_SET_QUEUE_SIZE:
      Result := True;
    IOC_IMMEDIATE_CHAR:
      if (pin <> nil) and (lin >= 1) then
      begin
        Result := RingPut(ToPhone, pin, 1) = 1;
        if Result then begin Inc(St.ToPhoneBytes); PendTx; end;
      end;
    IOC_GET_DCB:
      if (pout <> nil) and (lout >= 28) then
      begin Move(Dcb, pout^, 28); ret := 28; Result := True; end;
    IOC_SET_DCB:
      if (pin <> nil) and (lin >= 12) then
      begin
        if lin >= 28 then Move(pin^, Dcb, 28) else Move(pin^, Dcb, lin);
        PutDW(@Dcb, 0, 28);
        St.Baud := GetDW(@Dcb, 4);
        Result := True;
      end;
  end;
  if Result and (pact <> nil) then pact^ := ret;
  if not Result then Inc(St.Refused);
  LogCall(code, lin, lout, ret, Result);
  if code <> IOC_WAIT_ON_MASK then
  begin
    { what it was given: the first input DWORD, and for DCB and timeouts the
      second value that matters; what it answered: the first output DWORD }
    v := 0; ev := 0;
    if (pin <> nil) and (lin >= 4) then v := GetDW(pin, 0)
    else if (pin <> nil) and (lin >= 1) then v := pin[0];
    if code = IOC_SET_DCB then
    begin
      if lin >= 12 then begin v := GetDW(pin, 4); ev := GetDW(pin, 8); end;
    end
    else if code = IOC_SET_TIMEOUTS then
    begin
      { Arg interval, Arg2 read constant + write constant shl 16, Ret read multiplier }
      if lin >= 20 then begin ev := GetDW(pin, 8) or (GetDW(pin, 16) shl 16); ret := GetDW(pin, 4); end;
    end;
    if Result and (pout <> nil) and (ret >= 4) then ret := GetDW(pout, 0);
    if (code = IOC_GET_DCB) and Result then begin ret := GetDW(pout, 4); ev := GetDW(pout, 8); end;
    Tr(TK_IOCTL, h, code, v, ev, ret, Result);
  end;
end;

{ ---------- WSP face ---------- }

function WspInit(ctx: LongWord): LongWord;
begin
  Inc(St.WspInits);
  St.Version := WH_VERSION;
  Result := WSPDEV;
end;

function WspDeinit(h: LongWord): Boolean;
begin
  Result := h = WSPDEV;
end;

function WspOpen(h, access, share: LongWord): LongWord;
begin
  Result := 0;
  if h <> WSPDEV then Exit;
  WspIsOpen := True;
  Inc(St.WspOpens);
  Result := WSPOPEN_TAG + 1;
end;

function WspClose(h: LongWord): Boolean;
begin
  Result := h = WSPOPEN_TAG + 1;
  if Result then WspIsOpen := False;
end;

function WspRead(h: LongWord; buf: PByte; count: LongWord): LongWord;
var start, n: LongWord;
begin
  Result := MAXDW;
  if h <> WSPOPEN_TAG + 1 then Exit;
  Result := 0;
  if (count = 0) or (buf = nil) then Exit;
  start := Now;
  repeat
    n := RingGet(ToPhone, buf, count);
    if n > 0 then Break;
    if Now - start >= 50 then Break;   { never blocks longer than 50 ms }
    Nap(2);
  until False;
  Result := n;
  if n > 0 then Tr(TK_WSP_READ, h, 0, count, 0, n, True);
end;

function WspWrite(h: LongWord; buf: PByte; count: LongWord): LongWord;
var n: LongWord;
begin
  Result := MAXDW;
  if h <> WSPOPEN_TAG + 1 then Exit;
  Result := 0;
  if (count = 0) or (buf = nil) then Exit;
  n := RingPut(FromPhone, buf, count);
  St.FromPhoneBytes := St.FromPhoneBytes + n;
  if n < count then St.Dropped := St.Dropped + (count - n);
  if n > 0 then PendRx;
  Result := n;                         { the Whisper side is told what fitted }
  Tr(TK_WSP_WRITE, h, 0, count, 0, n, True);
end;

function WspIOControl(h, code: LongWord; pin: PByte; lin: LongWord;
                      pout: PByte; lout: LongWord; pact: PLongWord): Boolean;
var n, k, j, first: LongWord;
begin
  Result := False;
  if h <> WSPOPEN_TAG + 1 then Exit;
  if pact <> nil then pact^ := 0;
  case code of
    IOC_WSP_STATS:
      if (pout <> nil) and (lout >= SizeOf(TWhStats)) then
      begin
        St.ToPhoneQueued := RingCount(ToPhone);
        St.FromPhoneQueued := RingCount(FromPhone);
        Move(St, pout^, SizeOf(TWhStats));
        if pact <> nil then pact^ := SizeOf(TWhStats);
        Result := True;
      end;
    IOC_WSP_CLEARLOG:
      begin St.LogCount := 0; St.Refused := 0; Result := True; end;
    IOC_WSP_ABORT:
      begin Inc(AbortGen); Inc(St.Aborts); Result := True; end;
    IOC_WSP_TRACE_START:
      begin TraceN := 0; TraceOn := True; Result := True; end;
    IOC_WSP_TRACE_STOP:
      begin TraceOn := False; Result := True; end;
    IOC_WSP_TRACE_GET:
      if (pout <> nil) and (lout >= 4) then
      begin
        PutDW(pout, 0, TraceN);
        k := TraceN; if k > TRACEMAX then k := TRACEMAX;
        if 4 + k * SizeOf(TTraceEntry) > lout then k := (lout - 4) div SizeOf(TTraceEntry);
        first := 0;                    { the first entries are kept }
        j := 0;
        while j < k do
        begin
          Move(Trace[first + j], pout[4 + j * SizeOf(TTraceEntry)], SizeOf(TTraceEntry));
          Inc(j);
        end;
        if pact <> nil then pact^ := 4 + k * SizeOf(TTraceEntry);
        Result := True;
      end;
    IOC_WSP_LOG:
      if pout <> nil then
      begin
        n := St.LogCount;
        if n * SizeOf(TWhLogEntry) > lout then n := lout div SizeOf(TWhLogEntry);
        if n > 0 then Move(Log, pout^, n * SizeOf(TWhLogEntry));
        if pact <> nil then pact^ := n * SizeOf(TWhLogEntry);
        Result := True;
      end;
  end;
end;

procedure ResetAll;
var i: Integer;
begin
  FillChar(ToPhone, SizeOf(ToPhone), 0);
  FillChar(FromPhone, SizeOf(FromPhone), 0);
  FillChar(St, SizeOf(St), 0);
  FillChar(Log, SizeOf(Log), 0);
  FillChar(Trace, SizeOf(Trace), 0);
  TraceN := 0; TraceOn := False;
  for i := 1 to MAXOPEN do begin OpenUsed[i] := False; OpenClosed[i] := 0; end;
  WspIsOpen := False;
  AbortGen := 0; PurgeRxGen := 0; PurgeTxGen := 0;
  for i := 1 to MAXOPEN do
  begin
    HMask[i] := 0; MaskGen[i] := 0;
    RxPending[i] := False; TxPending[i] := False; LinePending[i] := False;
  end;
  TOInterval := 0; TOMult := 0; TOConst := 0; TOWMult := 0; TOWConst := 0;
  FillChar(Dcb, SizeOf(Dcb), 0);
  PutDW(@Dcb, 0, 28);                { DCBlength }
  PutDW(@Dcb, 4, 9600);              { BaudRate }
  PutDW(@Dcb, 8, $1 or $10 or $1000);{ fBinary, DTR_CONTROL_ENABLE, RTS_CONTROL_ENABLE }
  PutW(@Dcb, 14, 512);               { XonLim }
  PutW(@Dcb, 16, 512);               { XoffLim }
  Dcb[18] := 8;                      { ByteSize }
  Dcb[21] := $11; Dcb[22] := $13;    { XonChar, XoffChar }
  St.Baud := 9600;
  St.Version := WH_VERSION;
end;

initialization
  ResetAll;
end.
