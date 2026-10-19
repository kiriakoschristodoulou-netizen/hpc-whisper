program losssim;
{ Checks the repeat policy of the sender (wmodem) against lost frames.
  A person types (with pauses and corrections); every frame the sender plays is
  lost with some probability, alone or in bursts; a model of the phone keeps
  what arrives. At the end the phone's text must equal the document.
  usage: losssim lossPercent burstMs runs [sends] }
{$mode objfpc}{$H+}
uses wmodem;
var runs, run, ok, code, sends, lossPct, burstMs: LongInt;
    snd: TSender; f: TFrame; recv: array[0..DOCMAX] of Byte; recvL: Integer;
    nowMs, nextKey, busyUntil, burstUntil, last, nchar: LongWord; i: Integer;
    txt: UnicodeString; frames, totalFrames: LongInt; bad: Integer; c: WideChar;
begin
  Val(ParamStr(1), lossPct, code); Val(ParamStr(2), burstMs, code); Val(ParamStr(3), runs, code);
  sends := DEFAULT_SENDS; if ParamCount >= 4 then Val(ParamStr(4), sends, code);
  RandSeed := 12345; ok := 0; totalFrames := 0;
  txt := 'The quick brown fox jumps over the lazy dog. Meet me at 7pm, caf' + #$E9 + ' near the old harbour! ';
  for run := 1 to runs do
  begin
    SnInit(snd, run); snd.target := sends;
    FillChar(recv, SizeOf(recv), 0); recvL := 0;
    nowMs := 1000; nextKey := nowMs; busyUntil := 0; burstUntil := 0; frames := 0; nchar := 0;
    last := 0;
    while True do
    begin
      if (nchar < 260) and (nowMs >= nextKey) then
      begin
        if Random(12) = 0 then SnBackspace(snd, nowMs)
        else begin c := txt[1 + (nchar mod Length(txt))]; SnType(snd, c, nowMs); Inc(nchar); end;
        if Random(10) = 0 then nextKey := nowMs + 800 + Random(2500) else nextKey := nowMs + 80 + Random(260);
      end;
      if nowMs >= busyUntil then
        if SnNext(snd, nowMs, f) then
        begin
          Inc(frames); last := nowMs;
          busyUntil := nowMs + FrameMs(f, 1);
          if (burstMs > 0) and (nowMs >= burstUntil) and (Random(100) < 6) then burstUntil := nowMs + burstMs;
          if (nowMs >= burstUntil) and (Random(100) >= lossPct) then
          begin
            recvL := f.docL; if f.off + f.len > DOCMAX then WriteLn('bad ', f.off, ' ', f.len, ' ', snd.L);
            for i := 0 to f.len - 1 do recv[f.off + i] := snd.doc[f.off + i];
          end;
        end;
      Inc(nowMs, 10);
      if (nchar >= 260) and (nowMs - last > 40000) then Break;
      if nowMs > 900000 then Break;
    end;
    bad := 0;
    if recvL <> snd.L then bad := 1000;
    for i := 0 to snd.L - 1 do if recv[i] <> snd.doc[i] then Inc(bad);
    if bad = 0 then Inc(ok);
    Inc(totalFrames, frames);
  end;
  WriteLn('loss ', lossPct, '%, bursts ', burstMs, ' ms, sends ', sends, ': ', ok, ' of ', runs, ' complete, ', totalFrames div runs, ' frames per run');
  if ok <> runs then Halt(1);
end.
