unit wscreen;
{ HPC Whisper 3: the picture remote's screen, as the phone sends it
  (docs/FORMAT3.md, SCREEN): zlib streams of 16 x 16 tiles in 16 greys. The
  picture is kept here, one grey (0..15) per byte; the program draws the
  tiles that changed. No Windows calls: tested on Linux. }
{$mode objfpc}{$H+}
interface

const
  SCR_MAXW = 640; SCR_MAXH = 240; SCR_T = 16;
  SCR_TW = SCR_MAXW div SCR_T; SCR_TH = SCR_MAXH div SCR_T;

type
  TScreen = record
    pix: array[0..SCR_MAXW * SCR_MAXH - 1] of Byte;
    tw, th: Integer;                    { the picture's size in tiles }
    changed: array[0..SCR_TH - 1, 0..SCR_TW - 1] of Boolean;
    anyChanged: Boolean;
    update: Integer;
    messages, tiles: Integer;
  end;

procedure ScrInit(var s: TScreen);
{ a SCREEN message; False when it cannot be read }
function ScrApply(var s: TScreen; const m: array of Byte; n: Integer): Boolean;

implementation

uses winf;

procedure ScrInit(var s: TScreen);
begin
  FillChar(s, SizeOf(s), 0);
  FillChar(s.pix, SizeOf(s.pix), 15);
end;

function ScrApply(var s: TScreen; const m: array of Byte; n: Integer): Boolean;
var st: TInflater; rec: array[0..129] of Byte; tx, ty, x, y, o, b: Integer; flags: Integer;
begin
  Result := False;
  if n < 5 then Exit;
  flags := m[2];
  if (flags and 2) <> 0 then FillChar(s.pix, SizeOf(s.pix), 15);     { a new size or view: start clean }
  st := InfStart(@m[3], n - 3, False);
  if st = nil then Exit;
  try
    while InfRead(st, @rec[0], 2) do
    begin
      tx := rec[0]; ty := rec[1];
      if tx = 255 then
      begin
        if not InfRead(st, @rec[2], 1) then Exit;
        if (ty >= 1) and (ty <= SCR_TW) and (rec[2] >= 1) and (rec[2] <= SCR_TH) then begin s.tw := ty; s.th := rec[2]; end;
        Inc(s.messages);
        s.update := (m[0] shl 8) or m[1];
        Result := True;
        Exit;
      end;
      if not InfRead(st, @rec[2], 128) then Exit;
      if (tx >= SCR_TW) or (ty >= SCR_TH) then Continue;
      for y := 0 to SCR_T - 1 do
      begin
        o := (ty * SCR_T + y) * SCR_MAXW + tx * SCR_T;
        for x := 0 to SCR_T div 2 - 1 do
        begin
          b := rec[2 + y * 8 + x];
          s.pix[o + 2 * x] := b shr 4;
          s.pix[o + 2 * x + 1] := b and 15;
        end;
      end;
      s.changed[ty, tx] := True; s.anyChanged := True;
      Inc(s.tiles);
    end;
  finally
    InfEnd(st);
  end;
end;

end.
