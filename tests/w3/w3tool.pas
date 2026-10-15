program w3tool;
{ The handheld's format 3 modem on Linux, for tests against the phone's.
    w3tool tx CH TYPE payload.bin out.wav [51]    a frame (44,100/s, or 51,200 with "51")
    w3tool train CH out.wav                        a TRAIN frame (44,100/s)
    w3tool rx CH in.wav RATE100 [map.bin]          read frames; RATE100 = the true rate x 100
  Prints one line per message: "msg TYPE LEN SNR10 FIXED HEX", and "train SNR10..." }
{$mode objfpc}{$H+}
uses w3core, w3dsp, w3tx, w3rx;

function ReadFileBytes(const p: string): TBytes;
var f: File; n: Int64;
begin
  Assign(f, p); Reset(f, 1);
  n := FileSize(f);
  SetLength(Result, n);
  if n > 0 then BlockRead(f, Result[0], n);
  Close(f);
end;

procedure WriteWav(const p: string; const x0: TSamples; rate: LongInt);
var f: File; h: array[0..43] of Byte; n, i: LongInt; x: TSamples;
  procedure P32(o: Integer; v: LongInt); begin h[o] := v and 255; h[o+1] := (v shr 8) and 255; h[o+2] := (v shr 16) and 255; h[o+3] := (v shr 24) and 255; end;
  procedure P16(o: Integer; v: Integer); begin h[o] := v and 255; h[o+1] := (v shr 8) and 255; end;
begin
  SetLength(x, Length(x0) + 8000);                 { frames follow silence }
  for i := 0 to High(x) do x[i] := 0;
  for i := 0 to High(x0) do x[4000 + i] := x0[i];
  n := Length(x) * 2;
  h[0] := Ord('R'); h[1] := Ord('I'); h[2] := Ord('F'); h[3] := Ord('F'); P32(4, 36 + n);
  h[8] := Ord('W'); h[9] := Ord('A'); h[10] := Ord('V'); h[11] := Ord('E');
  h[12] := Ord('f'); h[13] := Ord('m'); h[14] := Ord('t'); h[15] := Ord(' '); P32(16, 16);
  P16(20, 1); P16(22, 1); P32(24, rate); P32(28, rate * 2); P16(32, 2); P16(34, 16);
  h[36] := Ord('d'); h[37] := Ord('a'); h[38] := Ord('t'); h[39] := Ord('a'); P32(40, n);
  Assign(f, p); Rewrite(f, 1);
  BlockWrite(f, h, 44);
  if Length(x) > 0 then BlockWrite(f, x[0], n);
  Close(f);
end;

{ 16-bit mono (or the first channel) samples of a WAV file }
function ReadWav(const p: string; out rate: LongInt): TSamples;
var b: TBytes; i, o, n, ch, sz, k: Integer;
begin
  b := ReadFileBytes(p);
  rate := b[24] or (b[25] shl 8) or (b[26] shl 16) or (b[27] shl 24);
  ch := b[22];
  o := 12; sz := 0;
  while o + 8 <= Length(b) do
  begin
    sz := b[o+4] or (b[o+5] shl 8) or (b[o+6] shl 16) or (b[o+7] shl 24);
    if (b[o] = Ord('d')) and (b[o+1] = Ord('a')) then Break;
    o := o + 8 + sz;
  end;
  o := o + 8;
  if (sz <= 0) or (o + sz > Length(b)) then sz := Length(b) - o;
  n := sz div (2 * ch);
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    k := o + i * 2 * ch;
    Result[i] := SmallInt(b[k] or (b[k+1] shl 8));
  end;
end;

function IStr(v: LongInt): string;
begin
  Str(v, Result);
end;

function Hex(const b: array of Byte; n: Integer): string;
const H: string = '0123456789abcdef';
var i: Integer;
begin
  SetLength(Result, 2 * n);
  for i := 0 to n - 1 do begin Result[2*i+1] := H[(b[i] shr 4) + 1]; Result[2*i+2] := H[(b[i] and 15) + 1]; end;
end;

var
  cmd: string; ch, typ, code, i, n, rate: LongInt; m: TBitMap; pl, mb: TBytes; x, y: TSamples;
  r: TRx; rs: TResampler; msg: TRxMsg; rate100: Int64; s: string;
begin
  cmd := ParamStr(1);
  Val(ParamStr(2), ch, code);
  if cmd = 'tx' then
  begin
    Val(ParamStr(3), typ, code);
    pl := ReadFileBytes(ParamStr(4));
    StdMap(ch, m);
    if ParamCount >= 7 then begin mb := ReadFileBytes(ParamStr(7)); MapFromMsg(mb, Length(mb), m); end;
    if ParamStr(6) = '51' then begin x := MakeFrame51(ch, m, typ, pl, Length(pl), 0); WriteWav(ParamStr(5), x, 51200); end
    else begin x := MakeFrame(ch, m, typ, pl, Length(pl), 0); WriteWav(ParamStr(5), x, 44100); end;
  end
  else if cmd = 'train' then
  begin
    x := MakeTrain(ch, 0);
    WriteWav(ParamStr(3), x, 44100);
  end
  else if cmd = 'rx' then
  begin
    x := ReadWav(ParamStr(3), rate);
    Val(ParamStr(4), rate100, code);
    RxInit(r, ch);
    if ParamCount >= 5 then
    begin
      mb := ReadFileBytes(ParamStr(5));
      if MapFromMsg(mb, Length(mb), m) then RxAddMap(r, m);
    end;
    if rate100 = 5120000 then y := x
    else
    begin
      RsInit(rs, rate100, 5120000, True);
      SetLength(y, Int64(Length(x)) * 5120000 div rate100 + 64);
      n := RsProcess(rs, x, 0, Length(x), y, 0);
      SetLength(y, n);
    end;
    i := 0;
    while i < Length(y) do
    begin
      n := Length(y) - i; if n > 4096 then n := 4096;
      RxPush(r, y, i, n);
      Inc(i, n);
      while RxTake(r, msg) do
        WriteLn('msg ', msg.typ, ' ', msg.len, ' ', msg.snr10, ' ', msg.fixed, ' ', Hex(msg.data, msg.len));
      if r.trainReady then
      begin
        s := 'train';
        for code := 0 to Chans[ch].n - 1 do s := s + ' ' + IStr(r.trainSnr10[code]);
        WriteLn(s);
        r.trainReady := False;
      end;
    end;
    WriteLn('frames ', r.frames, ' fails ', r.fails, ' ', r.lastFail);
  end;
end.
