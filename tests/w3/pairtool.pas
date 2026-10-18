program pairtool;
{ The handheld's pairing check (wpair.pas):  pairtool gen RATE out.wav  |  pairtool turn out.wav  |  pairtool an in.wav
  (turn: the handheld's whole test sound at 44,100: the pattern and the loudness ladder) }
{$mode objfpc}{$H+}
uses SysUtils, Classes, wpair, w3core;
var x, z: TSmallArr; f: TFileStream; hdr: array[0..43] of Byte; rate, n, i: Integer; r: TPairResult; d: TBytes; s: string;
procedure W32(o, v: LongInt); begin hdr[o] := v and 255; hdr[o+1] := (v shr 8) and 255; hdr[o+2] := (v shr 16) and 255; hdr[o+3] := (v shr 24) and 255; end;
begin
  if (ParamStr(1) = 'gen') or (ParamStr(1) = 'turn') then
  begin
    if ParamStr(1) = 'turn' then
    begin
      rate := 44100; x := PairPattern(rate); z := PairLadder(CH_SU, PAIR_LADDER);
      n := Length(x); SetLength(x, n + Length(z)); for i := 0 to High(z) do x[n + i] := z[i];
    end
    else begin rate := StrToInt(ParamStr(2)); x := PairPattern(rate); end;
    FillChar(hdr, 44, 0);
    Move(PChar('RIFF')^, hdr[0], 4); W32(4, 36 + Length(x) * 2); Move(PChar('WAVEfmt ')^, hdr[8], 8);
    W32(16, 16); hdr[20] := 1; hdr[22] := 1; W32(24, rate); W32(28, rate * 2); hdr[32] := 2; hdr[34] := 16;
    Move(PChar('data')^, hdr[36], 4); W32(40, Length(x) * 2);
    if ParamStr(1) = 'turn' then s := ParamStr(2) else s := ParamStr(3);
    f := TFileStream.Create(s, fmCreate); f.WriteBuffer(hdr, 44); f.WriteBuffer(x[0], Length(x) * 2); f.Free;
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
      WriteLn('found scale ', r.scale10k, ' peak ', r.peak, ' clipped ', r.clipped, ' at ', r.aAt, ' pitch ', r.pitchOk, ' ', r.pitchPpm);
      WriteLn('snr', s);
    end
    else WriteLn('not found: ', PairWhy);
  end;
end.
