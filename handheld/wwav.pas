unit wwav;
{ HPC Whisper 3: WAV files for the handheld's own player: PCM (8 or 16 bit)
  and IMA ADPCM (as the phone makes them), decoded a block at a time to
  16-bit mono. No Windows calls: tested on Linux. }
{$mode objfpc}{$H+}
interface

type
  TWav = record
    ok: Boolean;
    fmt, channels, rate, bits, align, spb: Integer;
    data: PByte; dataLen: Integer;        { points into the file's bytes }
    pos: Integer;                         { next byte of data to decode }
    total: Integer;                       { samples (per channel), when known }
    done: Integer;                        { samples given out so far }
  end;

function WavOpen(var w: TWav; p: PByte; n: Integer): Boolean;
{ up to max samples (mono, 16-bit) into o; returns how many (0 = the end) }
function WavRead(var w: TWav; var o: array of SmallInt; max: Integer): Integer;
function WavSeconds(const w: TWav): Integer;

implementation

const
  STEP: array[0..88] of Integer = (7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60,
    66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
    4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767);
  INDEXT: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);

function U16(p: PByte): Integer; inline; begin Result := p[0] or (p[1] shl 8); end;
function U32(p: PByte): Integer; inline; begin Result := p[0] or (p[1] shl 8) or (p[2] shl 16) or (LongInt(p[3]) shl 24); end;

function WavOpen(var w: TWav; p: PByte; n: Integer): Boolean;
var i, len: Integer;
begin
  FillChar(w, SizeOf(w), 0);
  Result := False;
  if (n < 12) or (p[0] <> Ord('R')) or (p[1] <> Ord('I')) or (p[8] <> Ord('W')) then Exit;
  i := 12;
  while i + 8 <= n do
  begin
    len := U32(p + i + 4);
    if len < 0 then Exit;
    if (p[i] = Ord('f')) and (p[i + 1] = Ord('m')) and (p[i + 2] = Ord('t')) and (len >= 16) and (i + 8 + len <= n) then
    begin
      w.fmt := U16(p + i + 8); w.channels := U16(p + i + 10); w.rate := U32(p + i + 12);
      w.align := U16(p + i + 20); w.bits := U16(p + i + 22);
      if (w.fmt = $11) and (len >= 20) then w.spb := U16(p + i + 26);
    end
    else if (p[i] = Ord('f')) and (p[i + 1] = Ord('a')) and (p[i + 2] = Ord('c')) and (len >= 4) and (i + 12 <= n) then
      w.total := U32(p + i + 8)
    else if (p[i] = Ord('d')) and (p[i + 1] = Ord('a')) and (p[i + 2] = Ord('t')) and (p[i + 3] = Ord('a')) then
    begin
      w.data := p + i + 8;
      w.dataLen := len;
      if i + 8 + len > n then w.dataLen := n - i - 8;
      Break;
    end;
    i := i + 8 + len + (len and 1);
  end;
  if (w.data = nil) or (w.channels < 1) or (w.channels > 2) or (w.rate < 4000) or (w.rate > 48000) then Exit;
  if w.fmt = 1 then w.ok := (w.bits = 8) or (w.bits = 16)
  else if w.fmt = $11 then w.ok := (w.bits = 4) and (w.align > 4 * w.channels) and (w.spb > 1) and (w.channels = 1);
  if w.ok and (w.total = 0) then
  begin
    if w.fmt = 1 then w.total := w.dataLen div (w.channels * (w.bits div 8))
    else w.total := (w.dataLen div w.align) * w.spb;
  end;
  Result := w.ok;
end;

function WavSeconds(const w: TWav): Integer;
begin
  if w.rate > 0 then Result := w.total div w.rate else Result := 0;
end;

function WavRead(var w: TWav; var o: array of SmallInt; max: Integer): Integer;
var n, v, bps, pred, idx, i, code, st, dq, byt: Integer; b: PByte;
begin
  Result := 0;
  if not w.ok then Exit;
  n := 0;
  if w.fmt = 1 then
  begin
    bps := w.channels * (w.bits div 8);
    while (n < max) and (w.pos + bps <= w.dataLen) and (w.done < w.total) do
    begin
      b := w.data + w.pos;
      if w.bits = 16 then
      begin
        v := SmallInt(U16(b));
        if w.channels = 2 then v := (v + SmallInt(U16(b + 2))) div 2;
      end
      else
      begin
        v := (b[0] - 128) shl 8;
        if w.channels = 2 then v := (v + ((b[1] - 128) shl 8)) div 2;
      end;
      o[n] := v; Inc(n); Inc(w.done);
      Inc(w.pos, bps);
    end;
  end
  else
  begin
    { whole ADPCM blocks only: max must hold one }
    while (n + w.spb <= max) and (w.pos + w.align <= w.dataLen) and (w.done < w.total) do
    begin
      b := w.data + w.pos;
      pred := SmallInt(U16(b)); idx := b[2];
      if idx > 88 then idx := 88;
      o[n] := pred; Inc(n); Inc(w.done);
      for i := 0 to w.spb - 2 do
      begin
        if w.done >= w.total then Break;
        byt := b[4 + i div 2];
        if (i and 1) = 0 then code := byt and 15 else code := byt shr 4;
        st := STEP[idx]; dq := st shr 3;
        if (code and 4) <> 0 then dq := dq + st;
        if (code and 2) <> 0 then dq := dq + (st shr 1);
        if (code and 1) <> 0 then dq := dq + (st shr 2);
        if (code and 8) <> 0 then pred := pred - dq else pred := pred + dq;
        if pred > 32767 then pred := 32767 else if pred < -32768 then pred := -32768;
        idx := idx + INDEXT[code and 7];
        if idx < 0 then idx := 0 else if idx > 88 then idx := 88;
        o[n] := pred; Inc(n); Inc(w.done);
      end;
      Inc(w.pos, w.align);
    end;
  end;
  Result := n;
end;

end.
