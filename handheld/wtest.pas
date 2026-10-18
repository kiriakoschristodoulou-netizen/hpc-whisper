unit wtest;
{ Whisper Tools: the self test (docs/FORMAT3.md, section 8). Pair plays, besides its test sound and loudness
  steps, a scripted set of frames the other side counts:

    handheld -> phone   5 frames of the version 2 tones (silent 20 kHz at three speeds, 18 kHz, 20 kHz again),
                        3 frames on the silent channel, 2 on the fast channel, then the end mark (tones)
    phone -> handheld   3 frames of tones down (three loudnesses), 3 on the silent channel down, 3 on the fast
                        channel down (three loudnesses), then the end mark (tones down)

  Every test frame carries what it is (stage, number, run) and a fill that both sides can recompute, so a
  frame read wrongly is never counted. The handheld tells the phone how many of the phone's it read in
  one frame of tones (the one format that reaches the phone however the rest does): document $FE.
  Whole numbers only; no Windows calls (tested on Linux against the phone's Java). }
{$mode objfpc}{$H+}
interface

uses w3tx, wmodem;

const
  T_SELFTEST = $35;                     { the message type of the test frames (format 3) }
  DOC_TONES = $FD;                      { version 2 tone frames of the test: their document number }
  DOC_REPORT = $FE;                     { and of the handheld's results }
  ST_SU = 1; ST_FU = 2; ST_END_H = 3;   { stages from the handheld }
  ST_SD = 10; ST_FD = 11; ST_TD = 12; ST_END_P = 20; { stages from the phone }
  NTONE = 5; NSU = 3; NFU = 2; NSD = 3; NFD = 3; NTD = 3;
  TONE_BAND: array[0..NTONE - 1] of Integer = (4, 4, 0, 4, 4);     { index into BAND_HZ: 20.0, 20.0, 18.0, 20.0, 20.0 kHz }
  TONE_SPEED: array[0..NTONE - 1] of Integer = (1, 2, 1, 0, 1);    { Normal, Fast, Normal, Slow, Normal }
  TEST_LEN = 24;                        { a test frame of the modem }
  TD_TEST_LEN = 8;                      { and of the tones down: shorter, they are slow }
  REPORT_LEN = 20;

type
  TTally = record
    run: Integer;                       { the run number of the first test frame heard, -1 = none yet }
    sdMask, fdMask, tdMask: Integer;    { which of the phone's frames were read }
    endP: Boolean;                      { the phone's end mark was read }
    frames: Integer;                    { test frames read }
    firstAt, lastAt, endAt: LongWord;
  end;

type
  { what this handheld knows of its own hearing, for the results it sends the phone }
  TReportInfo = record
    micRate, spkRate: Integer;          { samples/s, the microphone's real rate and the speaker's }
    peakPct: Integer;                   { the loudest input during the test, % of full scale }
    tdStarts, tdHdrs: Integer;          { tones down: preambles seen, headers read }
    sdHdrs, fdHdrs, fdStarts: Integer;  { the modem receivers: headers read, frames found }
  end;

procedure TestPayload(run, stage, idx: Integer; var p: array of Byte);
procedure TestPayloadN(run, stage, idx, len: Integer; var p: array of Byte);
function TestPayloadOk(const p: array of Byte; n: Integer): Boolean;
procedure TallyInit(var t: TTally);
procedure TallyAdd(var t: TTally; const p: array of Byte; n: Integer; now: LongWord);
{ one frame of tones of the test (number idx), then a short silence, at this rate }
procedure ToneTestSound(idx, run, rate, volume: Integer; var x: TSamples);
procedure EndToneSound(run, rate, volume: Integer; var x: TSamples);
{ the handheld's results: 20 bytes }
function ReportMake(const t: TTally; snrLow, snrHigh: Integer; const info: TReportInfo; var b: array of Byte): Integer;
{ the results as a frame of tones }
procedure ReportSound(const b: array of Byte; n, rate, volume: Integer; var x: TSamples);

implementation

procedure TestPayloadN(run, stage, idx, len: Integer; var p: array of Byte);
var i: Integer;
begin
  p[0] := run and 255; p[1] := stage; p[2] := idx;
  for i := 3 to len - 1 do p[i] := Byte(stage * 31 + idx * 7 + i * 13 + (run and 255) * 5);
end;

procedure TestPayload(run, stage, idx: Integer; var p: array of Byte);
begin
  TestPayloadN(run, stage, idx, TEST_LEN, p);
end;

function TestPayloadOk(const p: array of Byte; n: Integer): Boolean;
var i: Integer;
begin
  Result := False;
  if (n <> TEST_LEN) and (n <> TD_TEST_LEN) then Exit;
  for i := 3 to n - 1 do
    if p[i] <> Byte(p[1] * 31 + p[2] * 7 + i * 13 + p[0] * 5) then Exit;
  Result := True;
end;

procedure TallyInit(var t: TTally);
begin
  FillChar(t, SizeOf(t), 0);
  t.run := -1;
end;

procedure TallyAdd(var t: TTally; const p: array of Byte; n: Integer; now: LongWord);
begin
  if not TestPayloadOk(p, n) then Exit;
  if t.frames = 0 then begin t.firstAt := now; t.run := p[0]; end;
  t.lastAt := now;
  Inc(t.frames);
  case p[1] of
    ST_SD: if p[2] < NSD then t.sdMask := t.sdMask or (1 shl p[2]);
    ST_FD: if p[2] < NFD then t.fdMask := t.fdMask or (1 shl p[2]);
    ST_TD: if p[2] < NTD then t.tdMask := t.tdMask or (1 shl p[2]);
    ST_END_P: begin t.endP := True; t.endAt := now; end;
  end;
end;

procedure FrameSound(const f: TFrame; band, speed, rate, volume: Integer; var x: TSamples);
var tm: TToneMaker; buf: array[0..2209] of SmallInt; n, i: Integer; more: Boolean;
begin
  TmInit(tm, rate);
  tm.band := band; tm.speed := speed; tm.volume := volume;
  TmStart(tm, f);
  SetLength(x, 0); n := 0;
  repeat
    for i := 0 to High(buf) do buf[i] := 0;
    more := TmFill(tm, buf, Length(buf));
    SetLength(x, n + Length(buf));
    for i := 0 to High(buf) do x[n + i] := buf[i];
    Inc(n, Length(buf));
  until (not more) or (n > rate * 8);
  { a quarter of a second of quiet between frames }
  SetLength(x, n + rate div 4);
  for i := n to n + rate div 4 - 1 do x[i] := 0;
end;

procedure ToneTestSound(idx, run, rate, volume: Integer; var x: TSamples);
var f: TFrame; t: array[0..3] of Byte;
begin
  t[0] := Ord('S'); t[1] := Ord('T'); t[2] := Ord('A') + idx; t[3] := run and 127;
  EncodeFrame(t, 4, idx, DOC_TONES, 4, 0, f);
  FrameSound(f, TONE_BAND[idx], TONE_SPEED[idx], rate, volume, x);
end;

{ the end mark of the handheld's part: tones, the one format that reaches the phone however the rest does }
procedure EndToneSound(run, rate, volume: Integer; var x: TSamples);
var f: TFrame; t: array[0..3] of Byte;
begin
  t[0] := Ord('S'); t[1] := Ord('T'); t[2] := Ord('Z'); t[3] := run and 127;
  EncodeFrame(t, 4, NTONE, DOC_TONES, 4, 0, f);
  FrameSound(f, 4, 1, rate, volume, x);
end;

function Clamp20(v: Integer): Byte;
begin
  v := v + 20;
  if v < 0 then v := 0 else if v > 255 then v := 255;
  Result := v;
end;

function Cl(v: Integer): Byte;
begin
  if v < 0 then v := 0 else if v > 255 then v := 255;
  Result := v;
end;

function ReportMake(const t: TTally; snrLow, snrHigh: Integer; const info: TReportInfo; var b: array of Byte): Integer;
begin
  b[0] := 2;
  if t.run >= 0 then b[1] := t.run else b[1] := 0;
  b[2] := t.sdMask; b[3] := t.fdMask;
  b[4] := Ord(t.endP);
  if t.frames > 255 then b[5] := 255 else b[5] := t.frames;
  b[6] := Clamp20(snrLow); b[7] := Clamp20(snrHigh);
  b[8] := t.tdMask;
  b[9] := (info.micRate shr 8) and 255; b[10] := info.micRate and 255;
  b[11] := (info.spkRate shr 8) and 255; b[12] := info.spkRate and 255;
  b[13] := Cl(info.peakPct);
  b[14] := Cl(info.tdStarts); b[15] := Cl(info.tdHdrs);
  b[16] := Cl(info.sdHdrs); b[17] := Cl(info.fdHdrs); b[18] := Cl(info.fdStarts);
  b[19] := 0;
  Result := REPORT_LEN;
end;

procedure ReportSound(const b: array of Byte; n, rate, volume: Integer; var x: TSamples);
var f: TFrame;
begin
  EncodeFrame(b, n, 0, DOC_REPORT, n, 0, f);
  FrameSound(f, 4, 1, rate, volume, x);
end;

end.
