program mediatest;
{ The handheld's screen decoder (wscreen) and WAV decoder (wwav), against files made by the phone's Java. }
{$mode objfpc}{$H+}
uses SysUtils, Classes, wscreen, wwav;

function Load(const fn: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(fn, fmOpenRead);
  SetLength(Result, f.Size);
  if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  f.Free;
end;

var s: TScreen; dir: string; k, i, bad, diff: Integer; m, pic, w: TBytes; wv: TWav; buf: array[0..4095] of SmallInt;
    n, total: Integer; e, p: Double; x: Double;
begin
  dir := ParamStr(1); bad := 0;
  ScrInit(s);
  k := 0;
  while FileExists(dir + '/scr_' + IntToStr(k) + '.bin') do
  begin
    m := Load(dir + '/scr_' + IntToStr(k) + '.bin');
    if not ScrApply(s, m, Length(m)) then begin WriteLn('message ', k, ' not read'); Inc(bad); end;
    Inc(k);
  end;
  pic := Load(dir + '/scr_pic.bin');
  diff := 0;
  for i := 0 to 640 * 240 - 1 do
    if (i mod 640 < s.tw * 16) and (i div 640 < 192) and (s.pix[i] <> pic[i]) then Inc(diff);
  WriteLn('screen: ', k, ' messages, ', s.tiles, ' tiles, ', s.tw, ' x ', s.th, ' tiles, ', diff, ' pixels differ');
  if (diff <> 0) or (k = 0) then Inc(bad);
  { the WAV: a 440 + 1234 Hz tone made by Adpcm.java }
  w := Load(ParamStr(2));
  if not WavOpen(wv, @w[0], Length(w)) then begin WriteLn('WAV not opened'); Inc(bad); end
  else
  begin
    total := 0; e := 0; p := 0;
    repeat
      n := WavRead(wv, buf, 4096);
      for i := 0 to n - 1 do
      begin
        x := Trunc(12000 * Sin(2 * Pi * 440 * (total + i) / wv.rate) + 4000 * Sin(2 * Pi * 1234 * (total + i) / wv.rate));
        p := p + x * x; e := e + (x - buf[i]) * (x - buf[i]);
      end;
      total := total + n;
    until n = 0;
    WriteLn('wav: rate ', wv.rate, ', ', total, ' samples, SNR ', (10 * Ln(p / e) / Ln(10)):0:1, ' dB');
    if (total <> wv.total) or (p / e < 100) then Inc(bad);
  end;
  if bad = 0 then WriteLn('ALL PASS') else WriteLn(bad, ' FAILED');
  Halt(bad);
end.
