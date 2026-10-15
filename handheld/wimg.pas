unit wimg;
{ Pictures (from the phone, or files on the handheld): their size, and decoding them straight down to a
  small 16-bit (5-6-5) picture that fits the screen.

  PNG: decoded here (all colour types and depths; interlaced PNGs are not
  supported). JPEG: through Free Pascal's own pasjpeg, which can also reduce
  the size while decoding (1/2, 1/4, 1/8). Rows are shrunk as they come, so a
  large picture never needs much memory beyond what pasjpeg itself keeps.

  No Windows calls: tested on Linux against real books. }
{$mode objfpc}{$H+}

interface

const
  IMG_UNKNOWN = 0; IMG_PNG = 1; IMG_JPEG = 2; IMG_GIF = 3;

function ImageKind(p: PByte; n: Integer): Integer;
{ width and height from the first bytes of a picture (64 KB is plenty) }
function ImageSize(p: PByte; n: Integer; out w, h: Integer): Boolean;
{ decodes to exactly tw x th pixels, top row first, 5-6-5; transparency is laid on bgRGB ($RRGGBB).
  pix must hold tw * th words. Returns False when the picture cannot be decoded. }
function DecodeImage(p: PByte; n: Integer; tw, th: Integer; bgRGB: LongWord; pix: PWord): Boolean;

implementation

uses winf, jmorecfg, jpeglib, jdeferr, jerror, jdapimin, jdapistd, jdmarker;

function BE32(p: PByte): LongWord; inline;
begin
  Result := (LongWord(p[0]) shl 24) or (LongWord(p[1]) shl 16) or (LongWord(p[2]) shl 8) or p[3];
end;

function ImageKind(p: PByte; n: Integer): Integer;
begin
  Result := IMG_UNKNOWN;
  if n < 8 then Exit;
  if (p[0] = $89) and (p[1] = Ord('P')) and (p[2] = Ord('N')) and (p[3] = Ord('G')) then Result := IMG_PNG
  else if (p[0] = $FF) and (p[1] = $D8) then Result := IMG_JPEG
  else if (p[0] = Ord('G')) and (p[1] = Ord('I')) and (p[2] = Ord('F')) then Result := IMG_GIF;
end;

function ImageSize(p: PByte; n: Integer; out w, h: Integer): Boolean;
var i, len: Integer; m: Byte;
begin
  Result := False; w := 0; h := 0;
  case ImageKind(p, n) of
    IMG_PNG:
      if n >= 24 then begin w := BE32(p + 16); h := BE32(p + 20); Result := True; end;
    IMG_GIF:
      if n >= 10 then begin w := p[6] or (p[7] shl 8); h := p[8] or (p[9] shl 8); Result := True; end;
    IMG_JPEG:
      begin
        i := 2;
        while i + 9 < n do
        begin
          if p[i] <> $FF then begin Inc(i); Continue; end;
          m := p[i + 1];
          if (m = $FF) then begin Inc(i); Continue; end;
          if (m = $D8) or (m = $01) or ((m >= $D0) and (m <= $D7)) then begin Inc(i, 2); Continue; end;
          len := (p[i + 2] shl 8) or p[i + 3];
          if (m in [$C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF]) then
          begin
            h := (p[i + 5] shl 8) or p[i + 6];
            w := (p[i + 7] shl 8) or p[i + 8];
            Result := True; Exit;
          end;
          i := i + 2 + len;
        end;
      end;
  end;
  if (w <= 0) or (h <= 0) or (w > 20000) or (h > 20000) then Result := False;
end;

{ ---------- shrinking rows as they come ---------- }

type
  TShrink = record
    sw, sh, tw, th: Integer;
    tx: array of Integer;           { target column of each source column }
    acc: array of LongWord;         { per target pixel: r, g, b, count }
    curTy, sy: Integer;
    pix: PWord;
    bgR, bgG, bgB: Integer;
  end;

procedure ShrinkInit(var s: TShrink; sw, sh, tw, th: Integer; pix: PWord; bg: LongWord);
var x: Integer;
begin
  s.sw := sw; s.sh := sh; s.tw := tw; s.th := th; s.pix := pix;
  SetLength(s.tx, sw);
  for x := 0 to sw - 1 do s.tx[x] := (Int64(x) * tw) div sw;
  SetLength(s.acc, tw * 4);
  FillChar(s.acc[0], tw * 16, 0);
  s.curTy := 0; s.sy := 0;
  s.bgR := (bg shr 16) and 255; s.bgG := (bg shr 8) and 255; s.bgB := bg and 255;
  FillChar(pix^, tw * th * 2, 0);
end;

procedure ShrinkFlush(var s: TShrink);
var x, c: Integer; r, g, b: LongWord; row: PWord;
begin
  if (s.curTy < 0) or (s.curTy >= s.th) then Exit;
  row := s.pix + s.curTy * s.tw;
  for x := 0 to s.tw - 1 do
  begin
    c := s.acc[x * 4 + 3];
    if c = 0 then
    begin
      if x > 0 then row[x] := row[x - 1];          { more target than source columns: repeat }
      Continue;
    end;
    r := s.acc[x * 4] div c; g := s.acc[x * 4 + 1] div c; b := s.acc[x * 4 + 2] div c;
    row[x] := ((r shr 3) shl 11) or ((g shr 2) shl 5) or (b shr 3);
  end;
  FillChar(s.acc[0], s.tw * 16, 0);
end;

{ one source row as r, g, b, a bytes (a = 255 opaque) }
procedure ShrinkRow(var s: TShrink; rgba: PByte);
var x, ty, t, a: Integer;
begin
  ty := (Int64(s.sy) * s.th) div s.sh;
  if ty <> s.curTy then
  begin
    ShrinkFlush(s);
    while s.curTy + 1 < ty do                 { target rows with no source row: copy }
    begin
      Inc(s.curTy);
      if s.curTy < s.th then Move((s.pix + (s.curTy - 1) * s.tw)^, (s.pix + s.curTy * s.tw)^, s.tw * 2);
    end;
    s.curTy := ty;
  end;
  for x := 0 to s.sw - 1 do
  begin
    t := s.tx[x] * 4;
    a := rgba[x * 4 + 3];
    if a = 255 then
    begin
      Inc(s.acc[t], rgba[x * 4]); Inc(s.acc[t + 1], rgba[x * 4 + 1]); Inc(s.acc[t + 2], rgba[x * 4 + 2]);
    end
    else
    begin
      Inc(s.acc[t], (rgba[x * 4] * a + s.bgR * (255 - a)) div 255);
      Inc(s.acc[t + 1], (rgba[x * 4 + 1] * a + s.bgG * (255 - a)) div 255);
      Inc(s.acc[t + 2], (rgba[x * 4 + 2] * a + s.bgB * (255 - a)) div 255);
    end;
    Inc(s.acc[t + 3]);
  end;
  Inc(s.sy);
end;

procedure ShrinkDone(var s: TShrink);
begin
  ShrinkFlush(s);
  while s.curTy + 1 < s.th do
  begin
    Inc(s.curTy);
    Move((s.pix + (s.curTy - 1) * s.tw)^, (s.pix + s.curTy * s.tw)^, s.tw * 2);
  end;
  SetLength(s.tx, 0); SetLength(s.acc, 0);
end;

{ ---------- PNG ---------- }

function Paeth(a, b, c: Integer): Integer; inline;
var p, pa, pb, pc: Integer;
begin
  p := a + b - c;
  pa := Abs(p - a); pb := Abs(p - b); pc := Abs(p - c);
  if (pa <= pb) and (pa <= pc) then Result := a
  else if pb <= pc then Result := b
  else Result := c;
end;

function DecodePng(p: PByte; n: Integer; tw, th: Integer; bg: LongWord; pix: PWord): Boolean;
var i, len, w, h, depth, ctype, interlace, chans, bpp, rowBytes, x, y, v, sh, mask, k: Integer;
    idat: PByte; idatLen, idatCap: Integer; pal: array[0..255, 0..3] of Byte; nPal: Integer;
    trnsGray, trnsR, trnsG, trnsB: Integer; hasTrnsKey: Boolean;
    inf: TInflater; cur, prev, rgba: PByte; filt: Byte; s: TShrink; typ: LongWord; maxv: Integer;
begin
  Result := False;
  if n < 33 then Exit;
  w := BE32(p + 16); h := BE32(p + 20);
  depth := p[24]; ctype := p[25]; interlace := p[28];
  if (w <= 0) or (h <= 0) or (w > 20000) or (h > 20000) or (interlace <> 0) then Exit;
  case ctype of
    0: chans := 1; 2: chans := 3; 3: chans := 1; 4: chans := 2; 6: chans := 4;
  else Exit;
  end;
  if not (depth in [1, 2, 4, 8, 16]) then Exit;
  bpp := (chans * depth + 7) div 8;
  rowBytes := (w * chans * depth + 7) div 8;
  { gather the chunks }
  FillChar(pal, SizeOf(pal), 255); nPal := 0;
  hasTrnsKey := False; trnsGray := -1; trnsR := -1; trnsG := -1; trnsB := -1;
  idatCap := n; GetMem(idat, idatCap); idatLen := 0;
  if idat = nil then Exit;                                 { not enough memory }
  i := 8;
  while i + 12 <= n do
  begin
    len := BE32(p + i); typ := BE32(p + i + 4);
    if (len < 0) or (i + 12 + len > n) then Break;
    if typ = $504C5445 then                                 { PLTE }
    begin
      nPal := len div 3; if nPal > 256 then nPal := 256;
      for k := 0 to nPal - 1 do
      begin pal[k, 0] := p[i + 8 + k * 3]; pal[k, 1] := p[i + 9 + k * 3]; pal[k, 2] := p[i + 10 + k * 3]; end;
    end
    else if typ = $74524E53 then                            { tRNS }
    begin
      if ctype = 3 then
        for k := 0 to len - 1 do begin if k < 256 then pal[k, 3] := p[i + 8 + k]; end
      else if (ctype = 0) and (len >= 2) then begin hasTrnsKey := True; trnsGray := (p[i + 8] shl 8) or p[i + 9]; end
      else if (ctype = 2) and (len >= 6) then
      begin
        hasTrnsKey := True;
        trnsR := (p[i + 8] shl 8) or p[i + 9]; trnsG := (p[i + 10] shl 8) or p[i + 11]; trnsB := (p[i + 12] shl 8) or p[i + 13];
      end;
    end
    else if typ = $49444154 then                            { IDAT }
    begin
      Move((p + i + 8)^, (idat + idatLen)^, len);
      Inc(idatLen, len);
    end
    else if typ = $49454E44 then Break;                     { IEND }
    i := i + 12 + len;
  end;
  if idatLen = 0 then begin FreeMem(idat); Exit; end;
  inf := InfStart(idat, idatLen, False);
  if inf = nil then begin FreeMem(idat); Exit; end;
  GetMem(cur, rowBytes + 1); GetMem(prev, rowBytes + 1); GetMem(rgba, w * 4);
  if (cur = nil) or (prev = nil) or (rgba = nil) then
  begin
    if cur <> nil then FreeMem(cur); if prev <> nil then FreeMem(prev); if rgba <> nil then FreeMem(rgba);
    InfEnd(inf); FreeMem(idat); Exit;
  end;
  FillChar(prev^, rowBytes + 1, 0);
  ShrinkInit(s, w, h, tw, th, pix, bg);
  maxv := (1 shl depth) - 1;
  Result := True;
  for y := 0 to h - 1 do
  begin
    if not InfRead(inf, @filt, 1) or not InfRead(inf, cur, rowBytes) then begin Result := y > h div 2; Break; end;
    { undo the row filter }
    case filt of
      1: for x := bpp to rowBytes - 1 do cur[x] := Byte(cur[x] + cur[x - bpp]);
      2: for x := 0 to rowBytes - 1 do cur[x] := Byte(cur[x] + prev[x]);
      3: for x := 0 to rowBytes - 1 do
           if x >= bpp then cur[x] := Byte(cur[x] + (cur[x - bpp] + prev[x]) shr 1)
           else cur[x] := Byte(cur[x] + prev[x] shr 1);
      4: for x := 0 to rowBytes - 1 do
           if x >= bpp then cur[x] := Byte(cur[x] + Paeth(cur[x - bpp], prev[x], prev[x - bpp]))
           else cur[x] := Byte(cur[x] + prev[x]);
    end;
    { to r, g, b, a }
    for x := 0 to w - 1 do
    begin
      case ctype of
        0, 3:
          begin
            if depth = 16 then v := (cur[x * 2] shl 8) or cur[x * 2 + 1]
            else if depth = 8 then v := cur[x]
            else
            begin
              k := x * depth;
              sh := 8 - depth - (k and 7);
              mask := maxv;
              v := (cur[k shr 3] shr sh) and mask;
            end;
            if ctype = 3 then
            begin
              rgba[x * 4] := pal[v and 255, 0]; rgba[x * 4 + 1] := pal[v and 255, 1];
              rgba[x * 4 + 2] := pal[v and 255, 2]; rgba[x * 4 + 3] := pal[v and 255, 3];
            end
            else
            begin
              if hasTrnsKey and (v = trnsGray) then rgba[x * 4 + 3] := 0 else rgba[x * 4 + 3] := 255;
              if depth = 16 then v := v shr 8 else v := (v * 255) div maxv;
              rgba[x * 4] := v; rgba[x * 4 + 1] := v; rgba[x * 4 + 2] := v;
            end;
          end;
        2:
          if depth = 8 then
          begin
            rgba[x * 4] := cur[x * 3]; rgba[x * 4 + 1] := cur[x * 3 + 1]; rgba[x * 4 + 2] := cur[x * 3 + 2];
            if hasTrnsKey and (cur[x * 3] = trnsR) and (cur[x * 3 + 1] = trnsG) and (cur[x * 3 + 2] = trnsB) then
              rgba[x * 4 + 3] := 0 else rgba[x * 4 + 3] := 255;
          end
          else
          begin
            rgba[x * 4] := cur[x * 6]; rgba[x * 4 + 1] := cur[x * 6 + 2]; rgba[x * 4 + 2] := cur[x * 6 + 4];
            rgba[x * 4 + 3] := 255;
          end;
        4:
          if depth = 8 then
          begin
            rgba[x * 4] := cur[x * 2]; rgba[x * 4 + 1] := cur[x * 2]; rgba[x * 4 + 2] := cur[x * 2];
            rgba[x * 4 + 3] := cur[x * 2 + 1];
          end
          else
          begin
            rgba[x * 4] := cur[x * 4]; rgba[x * 4 + 1] := cur[x * 4]; rgba[x * 4 + 2] := cur[x * 4];
            rgba[x * 4 + 3] := cur[x * 4 + 2];
          end;
        6:
          if depth = 8 then Move(cur[x * 4], rgba[x * 4], 4)
          else
          begin
            rgba[x * 4] := cur[x * 8]; rgba[x * 4 + 1] := cur[x * 8 + 2]; rgba[x * 4 + 2] := cur[x * 8 + 4];
            rgba[x * 4 + 3] := cur[x * 8 + 6];
          end;
      end;
    end;
    ShrinkRow(s, rgba);
    { this row is the next one's "previous" }
    Move(cur^, prev^, rowBytes);
  end;
  ShrinkDone(s);
  InfEnd(inf);
  FreeMem(cur); FreeMem(prev); FreeMem(rgba); FreeMem(idat);
end;

{ ---------- JPEG, through pasjpeg ---------- }

var
  JpegJump: jmp_buf;

procedure JpegErrorExit(cinfo: j_common_ptr); far;
begin
  longjmp(JpegJump, 1);                 { back to DecodeJpeg: never stop the program }
end;

procedure JpegNoMessage(cinfo: j_common_ptr); far;
begin
end;

procedure JpegEmitNothing(cinfo: j_common_ptr; level: int); far;
begin
end;

procedure SrcInit(cinfo: j_decompress_ptr); far;
begin
end;

const
  JpegEoi: array[0..1] of Byte = ($FF, $D9);

function SrcFill(cinfo: j_decompress_ptr): boolean; far;
begin
  { past the end: give an end-of-image marker, as libjpeg advises }
  cinfo^.src^.next_input_byte := @JpegEoi[0];
  cinfo^.src^.bytes_in_buffer := 2;
  Result := True;
end;

procedure SrcSkip(cinfo: j_decompress_ptr; num_bytes: long); far;
begin
  if num_bytes <= 0 then Exit;
  if num_bytes > long(cinfo^.src^.bytes_in_buffer) then SrcFill(cinfo)
  else
  begin
    Inc(cinfo^.src^.next_input_byte, num_bytes);
    Dec(cinfo^.src^.bytes_in_buffer, num_bytes);
  end;
end;

procedure SrcTerm(cinfo: j_decompress_ptr); far;
begin
end;

function DecodeJpeg(p: PByte; n: Integer; tw, th: Integer; bg: LongWord; pix: PWord): Boolean;
var cinfo: jpeg_decompress_struct; jerr: jpeg_error_mgr; src: jpeg_source_mgr;
    row: JSAMPARRAY; rgba: PByte; s: TShrink; x, w, comps, c, m, y, k: Integer; ln: JSAMPROW;
    started: Boolean;
begin
  Result := False;
  rgba := nil; started := False;
  FillChar(cinfo, SizeOf(cinfo), 0);
  FillChar(jerr, SizeOf(jerr), 0);
  cinfo.err := jpeg_std_error(jerr);
  jerr.error_exit := @JpegErrorExit;
  jerr.output_message := @JpegNoMessage;
  jerr.emit_message := @JpegEmitNothing;
  if setjmp(JpegJump) <> 0 then
  begin
    { pasjpeg reported an error }
    if rgba <> nil then FreeMem(rgba);
    jpeg_destroy_decompress(@cinfo);
    Result := started;               { a picture cut short still shows what was decoded }
    if started then ShrinkDone(s);
    Exit;
  end;
  jpeg_create_decompress(@cinfo);
  FillChar(src, SizeOf(src), 0);
  src.next_input_byte := JOCTETptr(p);
  src.bytes_in_buffer := n;
  src.init_source := @SrcInit;
  src.fill_input_buffer := @SrcFill;
  src.skip_input_data := @SrcSkip;
  src.resync_to_restart := @jpeg_resync_to_restart;
  src.term_source := @SrcTerm;
  cinfo.src := @src;
  jpeg_read_header(@cinfo, True);
  { let pasjpeg shrink by 2, 4 or 8 when the picture is still at least as large as wanted }
  m := 1;
  while (m < 8) and (LongInt(cinfo.image_width) div (m * 2) >= tw) and (LongInt(cinfo.image_height) div (m * 2) >= th) do m := m * 2;
  cinfo.scale_num := 1; cinfo.scale_denom := m;
  cinfo.dct_method := JDCT_IFAST;
  cinfo.do_fancy_upsampling := False;
  if cinfo.jpeg_color_space = JCS_GRAYSCALE then cinfo.out_color_space := JCS_GRAYSCALE
  else if (cinfo.jpeg_color_space = JCS_CMYK) or (cinfo.jpeg_color_space = JCS_YCCK) then cinfo.out_color_space := JCS_CMYK
  else cinfo.out_color_space := JCS_RGB;
  jpeg_start_decompress(@cinfo);
  w := cinfo.output_width;
  comps := cinfo.output_components;
  row := cinfo.mem^.alloc_sarray(j_common_ptr(@cinfo), JPOOL_IMAGE, w * comps, 1);
  GetMem(rgba, w * 4);
  if rgba = nil then longjmp(JpegJump, 1);               { not enough memory: clean up as for an error }
  ShrinkInit(s, w, cinfo.output_height, tw, th, pix, bg);
  started := True;
  y := 0;
  while cinfo.output_scanline < cinfo.output_height do
  begin
    jpeg_read_scanlines(@cinfo, row, 1);
    ln := row^[0];
    for x := 0 to w - 1 do
    begin
      if comps = 1 then
      begin
        c := ln^[x];
        rgba[x * 4] := c; rgba[x * 4 + 1] := c; rgba[x * 4 + 2] := c;
      end
      else if comps = 3 then
      begin
        rgba[x * 4] := ln^[x * 3]; rgba[x * 4 + 1] := ln^[x * 3 + 1]; rgba[x * 4 + 2] := ln^[x * 3 + 2];
      end
      else
      begin
        { CMYK as Adobe writes it (inverted) }
        k := ln^[x * 4 + 3];
        rgba[x * 4] := (ln^[x * 4] * k) div 255; rgba[x * 4 + 1] := (ln^[x * 4 + 1] * k) div 255;
        rgba[x * 4 + 2] := (ln^[x * 4 + 2] * k) div 255;
      end;
      rgba[x * 4 + 3] := 255;
    end;
    ShrinkRow(s, rgba);
    Inc(y);
  end;
  ShrinkDone(s);
  jpeg_finish_decompress(@cinfo);
  jpeg_destroy_decompress(@cinfo);
  FreeMem(rgba);
  Result := y > 0;
end;

{ ---------- progressive JPEG: only the small picture in the first scans ----------
  A progressive JPEG first sends one value per 8 x 8 block (the "DC" scans):
  together they are the picture at 1/8 of its size. That is all a picture
  shrunk to fit the screen needs. Reading only those scans keeps memory small
  (one number per block) and skips most of the work. The full decoder would
  keep every coefficient of the whole picture in memory: megabytes for a
  book cover, more than the Jornada could give. }

type
  THuff = record
    used: Boolean;
    maxcode: array[1..17] of LongInt;
    mincode: array[1..16] of LongInt;
    valptr: array[1..16] of Integer;
    vals: array[0..255] of Byte;
  end;
  TBits = record
    p: PByte; n, pos: Integer;
    acc: LongWord; cnt: Integer;
    marker: Boolean;
  end;

procedure BitsInit(var b: TBits; p: PByte; n, pos: Integer);
begin
  b.p := p; b.n := n; b.pos := pos; b.acc := 0; b.cnt := 0; b.marker := False;
end;

function GetBit(var b: TBits): Integer;
var c: Integer;
begin
  if b.cnt = 0 then
  begin
    c := 0;
    if (not b.marker) and (b.pos < b.n) then
    begin
      c := b.p[b.pos];
      if c = $FF then
      begin
        if (b.pos + 1 < b.n) and (b.p[b.pos + 1] = 0) then Inc(b.pos, 2)
        else begin b.marker := True; c := 0; end;          { a marker: stop here, give zeros }
      end
      else Inc(b.pos);
    end;
    b.acc := c; b.cnt := 8;
  end;
  Dec(b.cnt);
  Result := (b.acc shr b.cnt) and 1;
end;

function GetBits(var b: TBits; k: Integer): LongInt;
var i: Integer;
begin
  Result := 0;
  for i := 1 to k do Result := (Result shl 1) or GetBit(b);
end;

function HuffDecode(var b: TBits; const h: THuff): Integer;
var code: LongInt; len: Integer;
begin
  code := 0;
  for len := 1 to 16 do
  begin
    code := (code shl 1) or GetBit(b);
    if (h.maxcode[len] >= 0) and (code <= h.maxcode[len]) then
    begin
      Result := h.vals[(h.valptr[len] + code - h.mincode[len]) and 255];
      Exit;
    end;
  end;
  Result := 0;
end;

function Extend(v: LongInt; s: Integer): LongInt;
begin
  if (s > 0) and (v < (LongInt(1) shl (s - 1))) then Result := v - (LongInt(1) shl s) + 1 else Result := v;
end;

function DecodeJpegDC(p: PByte; n: Integer; tw, th: Integer; bg: LongWord; pix: PWord): Boolean;
type TComp = record id, h, v, tq, bw, bh: Integer; dc: array of SmallInt; done: Boolean; td: Integer; pred: LongInt; end;
var pos, len, i, j, k, m, W, H, nc, hmax, vmax, ri, ns, ss, se, ah, al, c, x, y, bx, by, mx, my, mcusX, mcusY,
    mcuCount, yy, cb, cr, r, g, bb, cls, id, total: Integer;
    comps: array[0..3] of TComp;
    huff: array[0..3] of THuff;
    q: array[0..3] of Integer;
    scomp: array[0..3] of Integer;
    adobeRGB, sof: Boolean;
    bits: TBits; s: TShrink; row: PByte; cnt: array[1..16] of Integer; code: LongInt; v: LongInt;

  procedure DecodeBlock(ci: Integer; bxx, byy: Integer);
  var t: Integer; d: LongInt;
  begin
    t := HuffDecode(bits, huff[comps[ci].td]);
    d := 0;
    if t > 0 then d := Extend(GetBits(bits, t), t);
    comps[ci].pred := comps[ci].pred + d;
    if (bxx < comps[ci].bw) and (byy < comps[ci].bh) then
      comps[ci].dc[byy * comps[ci].bw + bxx] := SmallInt(comps[ci].pred shl al);
  end;

  procedure Restart;
  var t: Integer;
  begin
    { skip to the restart marker and past it, reset the predictions }
    bits.cnt := 0; bits.marker := False;
    while (bits.pos + 1 < n) and not ((p[bits.pos] = $FF) and (p[bits.pos + 1] >= $D0) and (p[bits.pos + 1] <= $D7)) do Inc(bits.pos);
    if bits.pos + 1 < n then Inc(bits.pos, 2);
    for t := 0 to nc - 1 do comps[t].pred := 0;
  end;

  function Sample(ci, xx, yy2: Integer): Integer;
  var a, b2: Integer;
  begin
    a := (xx * comps[ci].h) div hmax; b2 := (yy2 * comps[ci].v) div vmax;
    if a >= comps[ci].bw then a := comps[ci].bw - 1;
    if b2 >= comps[ci].bh then b2 := comps[ci].bh - 1;
    Result := (comps[ci].dc[b2 * comps[ci].bw + a] * q[comps[ci].tq and 3]) div 8 + 128;
    if Result < 0 then Result := 0;
    if Result > 255 then Result := 255;
  end;

begin
  Result := False;
  FillChar(huff, SizeOf(huff), 0);
  for i := 0 to 3 do begin q[i] := 1; comps[i].done := False; comps[i].pred := 0; end;
  nc := 0; W := 0; H := 0; hmax := 1; vmax := 1; ri := 0; adobeRGB := False; sof := False;
  pos := 2;
  while pos + 4 <= n do
  begin
    if p[pos] <> $FF then begin Inc(pos); Continue; end;
    m := p[pos + 1];
    if m = $FF then begin Inc(pos); Continue; end;
    if m = $D9 then Break;                                    { end of the picture }
    if (m = $D8) or ((m >= $D0) and (m <= $D7)) then begin Inc(pos, 2); Continue; end;
    len := (p[pos + 2] shl 8) or p[pos + 3];
    if pos + 2 + len > n then Break;
    k := pos + 4;
    case m of
      $C2, $C6, $CA:                                          { progressive frame }
        begin
          H := (p[k + 1] shl 8) or p[k + 2]; W := (p[k + 3] shl 8) or p[k + 4]; nc := p[k + 5];
          if (nc <> 1) and (nc <> 3) then Exit;               { CMYK and the like: not here }
          for i := 0 to nc - 1 do
          begin
            comps[i].id := p[k + 6 + i * 3];
            comps[i].h := p[k + 7 + i * 3] shr 4; comps[i].v := p[k + 7 + i * 3] and 15;
            comps[i].tq := p[k + 8 + i * 3];
            if comps[i].h < 1 then comps[i].h := 1;
            if comps[i].v < 1 then comps[i].v := 1;
            if comps[i].h > hmax then hmax := comps[i].h;
            if comps[i].v > vmax then vmax := comps[i].v;
          end;
          if (W <= 0) or (H <= 0) then Exit;
          for i := 0 to nc - 1 do
          begin
            comps[i].bw := ((W * comps[i].h + hmax - 1) div hmax + 7) div 8;
            comps[i].bh := ((H * comps[i].v + vmax - 1) div vmax + 7) div 8;
            SetLength(comps[i].dc, comps[i].bw * comps[i].bh);
            if comps[i].bw * comps[i].bh > 0 then FillChar(comps[i].dc[0], comps[i].bw * comps[i].bh * 2, 0);
          end;
          sof := True;
        end;
      $C4:                                                    { Huffman tables }
        while k < pos + 2 + len do
        begin
          cls := p[k] shr 4; id := p[k] and 3;
          total := 0;
          for i := 1 to 16 do begin cnt[i] := p[k + i]; total := total + cnt[i]; end;
          if cls = 0 then
          begin
            huff[id].used := True;
            code := 0; j := 0;
            for i := 1 to 16 do
            begin
              huff[id].valptr[i] := j;
              huff[id].mincode[i] := code;
              code := code + cnt[i];
              j := j + cnt[i];
              if cnt[i] > 0 then huff[id].maxcode[i] := code - 1 else huff[id].maxcode[i] := -1;
              code := code shl 1;
            end;
            for i := 0 to total - 1 do if i < 256 then huff[id].vals[i] := p[k + 17 + i];
          end;
          k := k + 17 + total;
        end;
      $DB:                                                    { quantisation tables: only the first (DC) value is needed }
        while k < pos + 2 + len do
        begin
          id := p[k] and 3;
          if (p[k] shr 4) = 0 then begin q[id] := p[k + 1]; k := k + 65; end
          else begin q[id] := (p[k + 1] shl 8) or p[k + 2]; k := k + 129; end;
        end;
      $DD: ri := (p[k] shl 8) or p[k + 1];                    { restart interval }
      $EE: if (len >= 12) and (p[k + 11] = 0) then adobeRGB := True;    { Adobe: colours stored as RGB }
      $DA:                                                    { a scan }
        begin
          if not sof then Exit;
          ns := p[k];
          for i := 0 to ns - 1 do
          begin
            scomp[i] := -1;
            for j := 0 to nc - 1 do
              if comps[j].id = p[k + 1 + i * 2] then begin scomp[i] := j; comps[j].td := (p[k + 2 + i * 2] shr 4) and 3; end;
          end;
          ss := p[k + 1 + ns * 2]; se := p[k + 2 + ns * 2];
          ah := p[k + 3 + ns * 2] shr 4; al := p[k + 3 + ns * 2] and 15;
          pos := pos + 2 + len;
          if (ss = 0) and (ah = 0) then
          begin
            { the first DC scan of these components: decode it }
            BitsInit(bits, p, n, pos);
            for i := 0 to ns - 1 do if scomp[i] >= 0 then comps[scomp[i]].pred := 0;
            mcuCount := 0;
            if ns = 1 then
            begin
              c := scomp[0];
              if c >= 0 then
                for by := 0 to comps[c].bh - 1 do
                  for bx := 0 to comps[c].bw - 1 do
                  begin
                    if (ri > 0) and (mcuCount > 0) and (mcuCount mod ri = 0) then Restart;
                    DecodeBlock(c, bx, by);
                    Inc(mcuCount);
                  end;
            end
            else
            begin
              mcusX := (W + 8 * hmax - 1) div (8 * hmax);
              mcusY := (H + 8 * vmax - 1) div (8 * vmax);
              for my := 0 to mcusY - 1 do
                for mx := 0 to mcusX - 1 do
                begin
                  if (ri > 0) and (mcuCount > 0) and (mcuCount mod ri = 0) then Restart;
                  for i := 0 to ns - 1 do
                  begin
                    c := scomp[i];
                    if c < 0 then Continue;
                    for y := 0 to comps[c].v - 1 do
                      for x := 0 to comps[c].h - 1 do
                        DecodeBlock(c, mx * comps[c].h + x, my * comps[c].v + y);
                  end;
                  Inc(mcuCount);
                end;
            end;
            for i := 0 to ns - 1 do if scomp[i] >= 0 then comps[scomp[i]].done := True;
            pos := bits.pos;
          end;
          { skip the rest of the scan's data, up to the next marker that is not a restart }
          while pos + 1 < n do
          begin
            if (p[pos] = $FF) and (p[pos + 1] <> 0) and not ((p[pos + 1] >= $D0) and (p[pos + 1] <= $D7)) then Break;
            Inc(pos);
          end;
          Continue;
        end;
    end;
    pos := pos + 2 + len;
  end;
  if not sof then Exit;
  for i := 0 to nc - 1 do if not comps[i].done then Exit;
  { the 1/8 picture, one pixel per block of the first component's grid }
  x := (W + 7) div 8; y := (H + 7) div 8;
  if (x < 1) or (y < 1) then Exit;
  GetMem(row, x * 4);
  if row = nil then Exit;
  ShrinkInit(s, x, y, tw, th, pix, bg);
  for by := 0 to y - 1 do
  begin
    for bx := 0 to x - 1 do
    begin
      if nc = 1 then
      begin
        yy := Sample(0, bx, by);
        row[bx * 4] := yy; row[bx * 4 + 1] := yy; row[bx * 4 + 2] := yy;
      end
      else
      begin
        yy := Sample(0, bx, by); cb := Sample(1, bx, by) - 128; cr := Sample(2, bx, by) - 128;
        if adobeRGB then begin r := yy; g := cb + 128; bb := cr + 128; end
        else
        begin
          r := yy + ((91881 * cr) div 65536);
          g := yy - ((22554 * cb + 46802 * cr) div 65536);
          bb := yy + ((116130 * cb) div 65536);
        end;
        if r < 0 then r := 0; if r > 255 then r := 255;
        if g < 0 then g := 0; if g > 255 then g := 255;
        if bb < 0 then bb := 0; if bb > 255 then bb := 255;
        row[bx * 4] := r; row[bx * 4 + 1] := g; row[bx * 4 + 2] := bb;
      end;
      row[bx * 4 + 3] := 255;
    end;
    ShrinkRow(s, row);
  end;
  ShrinkDone(s);
  FreeMem(row);
  Result := True;
end;

function IsProgressive(p: PByte; n: Integer): Boolean;
var i, len: Integer; m: Byte;
begin
  Result := False;
  i := 2;
  while i + 4 < n do
  begin
    if p[i] <> $FF then begin Inc(i); Continue; end;
    m := p[i + 1];
    if m = $FF then begin Inc(i); Continue; end;
    if (m = $D8) or ((m >= $D0) and (m <= $D7)) then begin Inc(i, 2); Continue; end;
    if m in [$C2, $C6, $CA] then begin Result := True; Exit; end;
    if m in [$C0, $C1, $C3, $C5, $C7, $C9, $CB, $CD..$CF, $DA] then Exit;
    len := (p[i + 2] shl 8) or p[i + 3];
    i := i + 2 + len;
  end;
end;


function DecodeImage(p: PByte; n: Integer; tw, th: Integer; bgRGB: LongWord; pix: PWord): Boolean;
var w, h: Integer;
begin
  Result := False;
  if (tw <= 0) or (th <= 0) then Exit;
  case ImageKind(p, n) of
    IMG_PNG: Result := DecodePng(p, n, tw, th, bgRGB, pix);
    IMG_JPEG:
      if IsProgressive(p, n) and ImageSize(p, n, w, h) and
         ((Int64(w) * h > 1000000) or (((w div 8) * 10 >= tw * 7) and ((h div 8) * 10 >= th * 7))) then
        { large, or large enough at 1/8: only the small picture (little memory, fast) }
        Result := DecodeJpegDC(p, n, tw, th, bgRGB, pix)
      else
        { baseline, or small progressive: the full decoder (pasjpeg) }
        Result := DecodeJpeg(p, n, tw, th, bgRGB, pix);
  end;
end;

end.
