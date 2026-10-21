program losssim;
{ Checks the repeat policy of the sender (wmodem) against lost frames.
  A person types (with pauses and corrections); every frame the sender plays is
  lost with some probability, alone or in bursts; a model of the phone keeps
  what arrives. At the end the phone's text must equal the document.
  With a fifth argument (ackLossPercent) the phone also answers, as in docs/FORMAT.md: 700 ms after the sound has
  stopped, if it has heard something new, it sends the acknowledgement (0.75 s), which is lost with that
  probability, and the handheld stops repeating what is acknowledged.
  With a sixth argument (corrupt = 1) a byte of the phone's copy goes wrong after the typing has stopped (as if a late
  change was missed): the handheld's periodic check (every 30 s) must find it and put it right.
  usage: losssim lossPercent burstMs runs [sends [ackLossPercent [corrupt]]] }
{$mode objfpc}{$H+}
uses wmodem;
var runs, run, ok, code, sends, lossPct, burstMs, ackLoss: LongInt; useAck, corrupt, corrupted: Boolean; corruptAt: LongWord;
    known: array[0..DOCMAX] of Boolean; newSince: Boolean; soundEnd, ackStart, ackEnd, lastDone: LongWord; ackPending: Boolean;
    ackP, ackG, ackH, ackFrames, totalLast: LongInt; lastFrameAt: LongWord; delivered, deliveredRuns: LongInt;
    snd: TSender; f: TFrame; recv: array[0..DOCMAX] of Byte; recvL: Integer;
    nowMs, nextKey, busyUntil, burstUntil, last, nchar: LongWord; i: Integer;
    txt: UnicodeString; frames, totalFrames: LongInt; bad: Integer; c: WideChar;
begin
  Val(ParamStr(1), lossPct, code); Val(ParamStr(2), burstMs, code); Val(ParamStr(3), runs, code);
  sends := DEFAULT_SENDS; if ParamCount >= 4 then Val(ParamStr(4), sends, code);
  useAck := ParamCount >= 5; ackLoss := 0; if useAck then Val(ParamStr(5), ackLoss, code);
  corrupt := (ParamCount >= 6) and (ParamStr(6) = '1');
  totalLast := 0; ackFrames := 0; deliveredRuns := 0;
  RandSeed := 12345; ok := 0; totalFrames := 0;
  txt := 'The quick brown fox jumps over the lazy dog. Meet me at 7pm, caf' + #$E9 + ' near the old harbour! ';
  for run := 1 to runs do
  begin
    SnInit(snd, run); snd.target := sends;
    FillChar(recv, SizeOf(recv), 0); recvL := 0; FillChar(known, SizeOf(known), 0);
    newSince := False; soundEnd := 0; ackPending := False; ackStart := 0; ackEnd := 0; lastDone := 0; lastFrameAt := 0;
    nowMs := 1000; nextKey := nowMs; busyUntil := 0; burstUntil := 0; frames := 0; nchar := 0;
    last := 0; corrupted := False; corruptAt := 0;
    while True do
    begin
      if corrupt and (not corrupted) and (nchar >= 260) and (nowMs - last > 20000) and (snd.L > 10) then
      begin
        recv[Random(snd.L div 2)] := recv[0] xor $55; corrupted := True; corruptAt := nowMs;
      end;
      if (nchar < 260) and (nowMs >= nextKey) then
      begin
        if Random(12) = 0 then SnBackspace(snd, nowMs)
        else begin c := txt[1 + (nchar mod Length(txt))]; SnType(snd, c, nowMs); Inc(nchar); end;
        if Random(10) = 0 then nextKey := nowMs + 800 + Random(2500) else nextKey := nowMs + 80 + Random(260);
      end;
      if useAck and (busyUntil > 0) and (nowMs >= busyUntil) and (lastDone < busyUntil) then
      begin
        lastDone := busyUntil; SnFrameDone(snd, busyUntil);
      end;
      if useAck and ackPending and (nowMs >= ackEnd) then
      begin
        ackPending := False;
        if Random(100) >= ackLoss then SnAck(snd, nowMs, snd.docId, ackP, ackG, ackH);
      end;
      if useAck and (not ackPending) and newSince and (nowMs >= busyUntil) and (nowMs >= soundEnd + 700) then
      begin
        { the phone answers: bytes 0..P-1 are all here, then a gap of G }
        ackP := 0; while (ackP < recvL) and known[ackP] do Inc(ackP);
        ackG := 0; while (ackP + ackG < recvL) and (not known[ackP + ackG]) and (ackG < 15) do Inc(ackG);
        ackH := AckHash(snd.docId, ackP, ackG, recv);
        ackStart := nowMs; ackEnd := nowMs + 750; ackPending := True; newSince := False; Inc(ackFrames);
      end;
      if nowMs >= busyUntil then
        if SnNext(snd, nowMs, f) then
        begin
          Inc(frames); if f.len > 0 then begin last := nowMs; lastFrameAt := nowMs; end;
          busyUntil := nowMs + FrameMs(f, 1);
          soundEnd := busyUntil;
          if (burstMs > 0) and (nowMs >= burstUntil) and (Random(100) < 6) then burstUntil := nowMs + burstMs;
          { the phone does not listen while it plays the acknowledgement }
          if ackPending and (busyUntil > ackStart) and (nowMs < ackEnd) then ackPending := ackPending and (Random(2) = 0);
          if (nowMs >= burstUntil) and (Random(100) >= lossPct) and not (ackPending and (nowMs < ackEnd) and (busyUntil > ackStart)) then
          begin
            recvL := f.docL; if f.off + f.len > DOCMAX then WriteLn('bad ', f.off, ' ', f.len, ' ', snd.L);
            for i := recvL to DOCMAX do known[i] := False;
            for i := 0 to f.len - 1 do begin recv[f.off + i] := snd.doc[f.off + i]; known[f.off + i] := True; end;
            newSince := True;
          end;
        end;
      Inc(nowMs, 10);
      if (nchar >= 260) and (nowMs - last > 40000) and ((not corrupt) or (corrupted and (nowMs - corruptAt > 200000))) then Break;
      if nowMs > 900000 then Break;
    end;
    bad := 0;
    if recvL <> snd.L then bad := 1000;
    for i := 0 to snd.L - 1 do if recv[i] <> snd.doc[i] then Inc(bad);
    if bad = 0 then Inc(ok)
    else if ParamCount >= 7 then WriteLn('run ', run, ': bad ', bad, ' acked ', snd.acked, ' L ', snd.L, ' mismatch ', snd.mismatch, ' repairAll ', snd.repairAll, ' heard ', snd.heard, ' noAck ', snd.noAck, ' corruptAt ', corruptAt, ' end ', nowMs);
    Inc(totalFrames, frames); Inc(totalLast, lastFrameAt - 1000);
  end;
  Write('loss ', lossPct, '%, bursts ', burstMs, ' ms, sends ', sends);
  if useAck then Write(', acknowledgements lost ', ackLoss, '%');
  if corrupt then Write(', one wrong byte on the phone');
  WriteLn(': ', ok, ' of ', runs, ' complete, ', totalFrames div runs, ' frames per run, last frame ', totalLast div runs div 1000, ' s after the start');
  if ok <> runs then Halt(1);
end.
