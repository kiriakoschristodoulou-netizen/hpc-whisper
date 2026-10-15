program pairtool;
{ The handheld's pairing check (wpair.pas):  pairtool gen RATE out.wav  |  pairtool an in.wav }
{$mode objfpc}{$H+}
uses SysUtils, Classes, wpair;
var x: TSmallArr; f: TFileStream; hdr: array[0..43] of Byte; rate, n, i: Integer; r: TPairResult; d: TBytes; s: string;
procedure W32(o, v: LongInt); begin hdr[o] := v and 255; hdr[o+1] := (v shr 8) and 255; hdr[o+2] := (v shr 16) and 255; hdr[o+3] := (v shr 24) and 255; end;
begin
  if ParamStr(1) = 'gen' then
  begin
    rate := StrToInt(ParamStr(2));
    x := PairPattern(rate);
    FillChar(hdr, 44, 0);
    Move(PChar('RIFF')^, hdr[0], 4); W32(4, 36 + Length(x) * 2); Move(PChar('WAVEfmt ')^, hdr[8], 8);
    W32(16, 16); hdr[20] := 1; hdr[22] := 1; W32(24, rate); W32(28, rate * 2); hdr[32] := 2; hdr[34] := 16;
    Move(PChar('data')^, hdr[36], 4); W32(40, Length(x) * 2);
    f := TFileStream.Create(ParamStr(3), fmCreate); f.WriteBuffer(hdr, 44); f.WriteBuffer(x[0], Length(x) * 2); f.Free;
  end
  else
  begin
    f := TFileStream.Create(ParamStr(2), fmOpenRead); SetLength(d, f.Size); f.ReadBuffer(d[0], f.Size); f.Free;
    rate := d[24] or (d[25] shl 8) or (d[26] shl 16);
    n := (Length(d) - 44) div 2;
    SetLength(x, n); Move(d[44], x[0], n * 2);
    if PairAnalyze(x, n, rate, r) then
    begin
      s := '';
      for i := 0 to PAIR_N - 1 do s := s + ' ' + IntToStr(r.snr10[i] div 10);
      WriteLn('found scale ', r.scale10k, ' peak ', r.peak, ' clipped ', r.clipped, ' at ', r.aAt);
      WriteLn('snr', s);
    end
    else WriteLn('not found');
  end;
end.
