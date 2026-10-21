unit wnturn;
{ Whisper Net: the handheld's turns (NET-PROTOCOL.md 3.4). It leads: plays its
  frames, then listens for the phone's until the phone's turn is over.

  Everything outside is reached through procedure variables, so the same code
  runs on the handheld (waveOut / waveIn, the virtual serial port) and in the
  Linux simulator (tests/netsim.pas).

  Whole numbers, fixed arrays, no heap: runs in a CreateThread thread. }
{$mode objfpc}{$R-}{$Q-}
interface
uses wnframe, wnrx, wnlink, wnstack;

type
  TProc = procedure;
  TPlayChunk = procedure(buf: PSmallInt; n: Integer);
  TMicRead = function(buf: PSmallInt; n: Integer): Boolean;     { n samples; False: stop }
  TNowMs = function: LongWord;
  TSleepMs = procedure(ms: Integer);

var
  PfPlayStart, PfPlayEnd, PfMicStart, PfMicStop, PfPoll: TProc;
  PfPlayChunk: TPlayChunk;
  PfMicRead: TMicRead;
  PfNow: TNowMs;
  PfSleep: TSleepMs;

  NtRate: Integer = 43200;            { what the sound is made at }
  NtRxRate: Integer = 0;              { what the microphone really runs at (0 = NtRate) }
  NtUpHz: Integer = 19000;
  NtDownHz: Integer = 18000;
  NtSymMs: Integer = 20;
  NtVolume: Integer = 80;
  NtStop: Boolean = False;
  { for the screen }
  NtState: Integer;                     { 0 waiting, 1 sending, 2 listening }
  NtTurns, NtFramesIn, NtEmptyTurns: LongWord;
  NtLastHeard: LongWord;                { PfNow when a frame last came }
  NtIdle: Integer;

procedure NtRun;

implementation

var
  Rx: TNetRx;
  Tp: TTurnPlayer;
  Fr: array[0..LK_MAXFR - 1] of TNetFrame;
  Buf: array[0..2047] of SmallInt;
  Mic: array[0..2159] of SmallInt;      { 50 ms at 43.2 kHz }

const
  IDLE_STEPS: array[0..3] of Integer = (1000, 2000, 4000, 6000);
  MICCHUNK_MS = 50;

{ one turn: play, then listen; returns the number of frames heard }
function DoTurn: Integer;
var nfr, i, k, heard, turnEnd, mc: Integer; f: TNetFrame; haveTurn, loud: Boolean; go: Boolean;
begin
  Result := 0;
  nfr := LkTurn(Lk, Fr);
  TpInit(Tp, NtRate);
  Tp.bandHz := NtUpHz; Tp.symMs := NtSymMs; Tp.volume := NtVolume;
  Tp.leadMs := 0; Tp.nf := nfr;
  for i := 0 to nfr - 1 do
    EncodeNet(Fr[i].flags, Fr[i].n, Fr[i].ack, Fr[i].off, Fr[i].data, Tp.f[i]);
  TpStart(Tp);
  NtState := 1;
  PfPlayStart();
  repeat
    go := TpFill(Tp, Buf, 1024);
    PfPlayChunk(@Buf[0], 1024);
    PfPoll();
  until not go;
  PfPlayEnd();
  Inc(NtTurns);
  { listen }
  NtState := 2;
  if NtRxRate = 0 then NtRxRate := NtRate;
  NrInit(Rx, NtRxRate, NtDownHz, NtSymMs);
  PfMicStart();
  mc := NtRxRate div 1000 * MICCHUNK_MS;
  haveTurn := False; turnEnd := 0; heard := 0;
  while not NtStop do
  begin
    if not PfMicRead(@Mic[0], mc) then Break;
    NrPush(Rx, Mic[0], mc);
    while NrTake(Rx, f) do
    begin
      Inc(heard);
      LkReceive(Lk, f);
      if (f.flags and FL_TURN) <> 0 then begin haveTurn := True; turnEnd := f.endBlk; end;
    end;
    PfPoll();
    StTick(PfNow());
    loud := NrQuietFor(Rx) < 50000;
    if haveTurn and (Rx.nblk >= turnEnd + 300) then Break;
    if (not loud) and (heard = 0) and (Rx.nblk >= 2500) then Break;
    if loud and (not haveTurn) and (not NrReading(Rx)) and (NrQuietFor(Rx) >= 1200) and (Rx.nblk >= 2500) then Break;
    if Rx.nblk >= 15000 then Break;
  end;
  PfMicStop();
  Result := heard;
end;

procedure NtRun;
var now, nextTurn: LongWord; heard: Integer;
begin
  NtStop := False; NtIdle := 0; nextTurn := 0; NtState := 0;
  NtTurns := 0; NtFramesIn := 0; NtEmptyTurns := 0;
  while not NtStop do
  begin
    now := PfNow();
    PfPoll();
    StTick(now);
    if StUpWaiting then nextTurn := now;
    if now >= nextTurn then
    begin
      StPump;
      heard := DoTurn;
      NtFramesIn := NtFramesIn + LongWord(heard);
      now := PfNow();
      if heard > 0 then NtLastHeard := now else Inc(NtEmptyTurns);
      if (LkPending(Lk) > 0) or StActive or (heard > 1) or ((heard = 1) and (Lk.framesIn > 0) and StUpWaiting) then
      begin NtIdle := 0; nextTurn := now; end
      else
      begin
        nextTurn := now + LongWord(IDLE_STEPS[NtIdle]);
        if NtIdle < 3 then Inc(NtIdle);
      end;
      NtState := 0;
    end
    else PfSleep(20);
  end;
end;

end.
