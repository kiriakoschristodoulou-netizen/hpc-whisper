program wmsim;
{ Plays a typing script through the real sender (wmodem) and writes the sound
  (44100 samples/s, 16-bit) for the tests.
  usage: wmsim script.txt out.raw band speed volume
  script: one event per line, "<ms> <code>", code = a character number,
  8 for backspace, -1 for a new document. }
{$mode objfpc}{$H+}
uses wmodem;
const RATE = 44100; BUFN = 4410;
var t: TToneMaker; snd: TSender; f: TFrame; sc: Text; fo: file;
    evMs, evCode: array[0..99999] of LongInt; nev, iev, code: LongInt;
    band, speed, vol: Integer; buf: array[0..BUFN - 1] of SmallInt;
    busy: Boolean; nowMs: LongWord; idleBufs, frames: Integer;
begin
  Assign(sc, ParamStr(1)); Reset(sc); nev := 0;
  while not Eof(sc) do begin ReadLn(sc, evMs[nev], evCode[nev]); Inc(nev); end;
  Close(sc);
  Val(ParamStr(3), band, code); Val(ParamStr(4), speed, code); Val(ParamStr(5), vol, code);
  TmInit(t, RATE); t.band := band; t.speed := speed; t.volume := vol;
  SnInit(snd, 7);
  Assign(fo, ParamStr(2)); Rewrite(fo, 1);
  FillChar(buf, SizeOf(buf), 0);
  BlockWrite(fo, buf, SizeOf(buf)); BlockWrite(fo, buf, SizeOf(buf));
  nowMs := 0; iev := 0; busy := False; idleBufs := 0; frames := 0;
  while True do
  begin
    while (iev < nev) and (evMs[iev] <= nowMs) do
    begin
      if evCode[iev] = 8 then SnBackspace(snd, nowMs)
      else if evCode[iev] = -1 then SnNewDoc(snd)
      else SnType(snd, WideChar(evCode[iev]), nowMs);
      Inc(iev);
    end;
    if not busy then
      if SnNext(snd, nowMs, f) then begin TmStart(t, f); Inc(frames); end;
    busy := TmFill(t, buf, BUFN);
    BlockWrite(fo, buf, SizeOf(buf));
    nowMs := nowMs + 100;
    if (iev >= nev) and not busy then Inc(idleBufs) else idleBufs := 0;
    if idleBufs > 80 then Break;                 { 8 s with nothing to send: done }
  end;
  Close(fo);
  WriteLn(frames, ' frames, ', nowMs div 1000, ' s, document ', snd.L, ' bytes');
end.
