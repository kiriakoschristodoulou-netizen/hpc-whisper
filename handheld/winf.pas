unit winf;
{ Decompression through Free Pascal's own pure-Pascal zlib: raw deflate (as
  used inside zip files) in one go, and zlib streams (as used inside PNG
  pictures) a piece at a time. Kept in its own unit because zlib's names
  (COPY, LEN, ...) would hide the usual ones elsewhere. }
{$mode objfpc}{$H+}
interface

function InflateRaw(src: PByte; srcLen: LongWord; dst: PByte; dstLen: LongWord): Boolean;
{ as much as fits in dst (at most dstLen bytes) from the start of a raw deflate stream; returns the count }
function InflateRawPrefix(src: PByte; srcLen: LongWord; dst: PByte; dstLen: LongWord): LongWord;

type
  TInflater = Pointer;
function InfStart(src: PByte; srcLen: LongWord; raw: Boolean): TInflater;
{ fills dst with exactly n bytes; False at an error or the end of the data }
function InfRead(st: TInflater; dst: PByte; n: LongWord): Boolean;
procedure InfEnd(st: TInflater);
{ a whole zlib stream; nil when damaged or over maxOut bytes }
function InflateAll(src: PByte; srcLen: LongWord; maxOut: LongWord; out outLen: LongWord): PByte;
{ a zlib stream of src into dst (at most cap bytes); its length, or 0 when it does not fit }
function DeflateBuf(src: PByte; n: LongWord; dst: PByte; cap: LongWord): LongWord;

implementation

uses zbase, zinflate, zdeflate;

function InflateRaw(src: PByte; srcLen: LongWord; dst: PByte; dstLen: LongWord): Boolean;
var z: z_stream; r: Integer;
begin
  FillChar(z, SizeOf(z), 0);
  Result := False;
  if inflateInit2(z, -MAX_WBITS) <> Z_OK then Exit;
  z.next_in := Pointer(src); z.avail_in := srcLen;
  z.next_out := Pointer(dst); z.avail_out := dstLen;
  r := inflate(z, Z_FINISH);
  Result := ((r = Z_STREAM_END) or (r = Z_OK) or (r = Z_BUF_ERROR)) and (z.total_out = dstLen);
  inflateEnd(z);
end;

function InflateRawPrefix(src: PByte; srcLen: LongWord; dst: PByte; dstLen: LongWord): LongWord;
var z: z_stream;
begin
  FillChar(z, SizeOf(z), 0);
  Result := 0;
  if inflateInit2(z, -MAX_WBITS) <> Z_OK then Exit;
  z.next_in := Pointer(src); z.avail_in := srcLen;
  z.next_out := Pointer(dst); z.avail_out := dstLen;
  inflate(z, Z_SYNC_FLUSH);
  Result := z.total_out;
  inflateEnd(z);
end;

type
  PInf = ^TInf;
  TInf = record
    z: z_stream;
    ended: Boolean;
  end;

function InfStart(src: PByte; srcLen: LongWord; raw: Boolean): TInflater;
var p: PInf; r: Integer;
begin
  New(p);
  FillChar(p^, SizeOf(TInf), 0);
  if raw then r := inflateInit2(p^.z, -MAX_WBITS) else r := inflateInit(p^.z);
  if r <> Z_OK then begin Dispose(p); Result := nil; Exit; end;
  p^.z.next_in := Pointer(src); p^.z.avail_in := srcLen;
  Result := p;
end;

function InfRead(st: TInflater; dst: PByte; n: LongWord): Boolean;
var p: PInf; r: Integer;
begin
  Result := False;
  p := PInf(st);
  if (p = nil) or (n = 0) then begin Result := p <> nil; Exit; end;
  p^.z.next_out := Pointer(dst); p^.z.avail_out := n;
  while p^.z.avail_out > 0 do
  begin
    if p^.ended then Exit;
    r := inflate(p^.z, Z_SYNC_FLUSH);
    if r = Z_STREAM_END then p^.ended := True
    else if r <> Z_OK then Exit;
  end;
  Result := True;
end;

procedure InfEnd(st: TInflater);
var p: PInf;
begin
  p := PInf(st);
  if p = nil then Exit;
  inflateEnd(p^.z);
  Dispose(p);
end;

function InflateAll(src: PByte; srcLen: LongWord; maxOut: LongWord; out outLen: LongWord): PByte;
var z: z_stream; r: Integer; cap: LongWord; buf, nb: PByte;
begin
  Result := nil; outLen := 0;
  FillChar(z, SizeOf(z), 0);
  if inflateInit(z) <> Z_OK then Exit;
  cap := srcLen * 3 + 4096;
  if cap > maxOut then cap := maxOut;
  GetMem(buf, cap);
  if buf = nil then begin inflateEnd(z); Exit; end;
  z.next_in := Pointer(src); z.avail_in := srcLen;
  z.next_out := Pointer(buf); z.avail_out := cap;
  while True do
  begin
    r := inflate(z, Z_SYNC_FLUSH);
    if r = Z_STREAM_END then Break;
    if (r <> Z_OK) and (r <> Z_BUF_ERROR) then begin FreeMem(buf); inflateEnd(z); Exit; end;
    if z.avail_out = 0 then
    begin
      if cap >= maxOut then begin FreeMem(buf); inflateEnd(z); Exit; end;
      if cap * 2 > maxOut then cap := maxOut else cap := cap * 2;
      GetMem(nb, cap);
      if nb = nil then begin FreeMem(buf); inflateEnd(z); Exit; end;
      Move(buf^, nb^, z.total_out);
      FreeMem(buf); buf := nb;
      z.next_out := Pointer(buf + z.total_out); z.avail_out := cap - z.total_out;
    end
    else if z.avail_in = 0 then begin FreeMem(buf); inflateEnd(z); Exit; end;   { the stream stops short }
  end;
  outLen := z.total_out;
  inflateEnd(z);
  Result := buf;
end;

function DeflateBuf(src: PByte; n: LongWord; dst: PByte; cap: LongWord): LongWord;
var z: z_stream; r: Integer;
begin
  Result := 0;
  FillChar(z, SizeOf(z), 0);
  if deflateInit(z, 6) <> Z_OK then Exit;
  z.next_in := Pointer(src); z.avail_in := n;
  z.next_out := Pointer(dst); z.avail_out := cap;
  r := deflate(z, Z_FINISH);
  if r = Z_STREAM_END then Result := z.total_out;
  deflateEnd(z);
end;

end.
