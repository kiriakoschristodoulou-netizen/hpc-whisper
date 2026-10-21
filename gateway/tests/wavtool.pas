program wavtool;
{ Whisper Net: make a turn as a WAV file with the handheld's player, or read
  frames from a WAV with the handheld's receiver. Used to check the handheld
  and phone implementations against each other.
  wavtool make out.wav rate bandHz nframes seed list.txt
  wavtool read in.wav rate bandHz list.txt        (rate = the file's rate)
  list.txt: one frame per line: flags n ack off hexdata }
{$mode objfpc}{$H+}
uses sysutils, classes, wnframe, wnrx;

var seed: LongWord;
function Rnd(n: Integer): Integer;
begin
  seed := seed * 1103515245 + 12345;
  Result := (seed shr 8) mod LongWord(n);
end;

procedure WriteWav(const fn: string; const s: array of SmallInt; n, rate: Integer);
var fs: TFileStream; h: array[0..43] of Byte; dl: LongInt;
  procedure P32(o: Integer; v: LongWord); begin h[o]:=v and 255; h[o+1]:=(v shr 8) and 255; h[o+2]:=(v shr 16) and 255; h[o+3]:=v shr 24; end;
begin
  dl := n * 2;
  h[0]:=Ord('R');h[1]:=Ord('I');h[2]:=Ord('F');h[3]:=Ord('F'); P32(4, 36 + dl);
  h[8]:=Ord('W');h[9]:=Ord('A');h[10]:=Ord('V');h[11]:=Ord('E');
  h[12]:=Ord('f');h[13]:=Ord('m');h[14]:=Ord('t');h[15]:=32; P32(16,16); h[20]:=1;h[21]:=0;h[22]:=1;h[23]:=0;
  P32(24, rate); P32(28, rate * 2); h[32]:=2;h[33]:=0;h[34]:=16;h[35]:=0;
  h[36]:=Ord('d');h[37]:=Ord('a');h[38]:=Ord('t');h[39]:=Ord('a'); P32(40, dl);
  fs := TFileStream.Create(fn, fmCreate);
  fs.WriteBuffer(h, 44); fs.WriteBuffer(s[0], dl); fs.Free;
end;

function Hex(const f: TNetFrame): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to f.n - 1 do Result := Result + IntToHex(f.data[i], 2);
  if Result = '' then Result := '-';
end;

var
  tp: TTurnPlayer; k, i, nf, rate, band, n: Integer; lst: TStringList;
  buf: array of SmallInt; tmp: array[0..1023] of SmallInt; f: TNetFrame; fr: TNetFrame;
  rx: TNetRx; fs: TFileStream; hdr: array[0..43] of Byte; sm: array of SmallInt; cnt: Integer;
begin
  if ParamCount < 5 then begin WriteLn('usage'); Halt(2); end;
  lst := TStringList.Create;
  rate := StrToInt(ParamStr(3)); band := StrToInt(ParamStr(4));
  if ParamStr(1) = 'make' then
  begin
    nf := StrToInt(ParamStr(5)); seed := StrToInt(ParamStr(6));
    TpInit(tp, rate); tp.bandHz := band; tp.symMs := 20; tp.volume := 80; tp.nf := nf;
    tp.leadHz := 0; tp.leadMs := 0;
    for k := 0 to nf - 1 do
    begin
      FillChar(f, SizeOf(f), 0);
      f.n := Rnd(NET_MAXLEN + 1);
      if k = nf - 1 then f.flags := FL_TURN;
      if k = 0 then f.flags := f.flags or FL_SYNC;
      f.ack := Rnd(65536); f.off := Rnd(65536);
      for i := 0 to f.n - 1 do f.data[i] := Rnd(256);
      EncodeNet(f.flags, f.n, f.ack, f.off, f.data, tp.f[k]);
      lst.Add(Format('%d %d %d %d %s', [f.flags, f.n, f.ack, f.off, Hex(f)]));
    end;
    TpStart(tp);
    SetLength(buf, rate * 40); n := rate;           { a second of silence first }
    while TpFill(tp, tmp, 1024) do begin Move(tmp, buf[n], 2048); Inc(n, 1024); end;
    Move(tmp, buf[n], 2048); Inc(n, 1024);
    n := n + rate;
    WriteWav(ParamStr(2), buf, n, rate);
    lst.SaveToFile(ParamStr(6 + 1));
  end
  else
  begin
    fs := TFileStream.Create(ParamStr(2), fmOpenRead);
    fs.ReadBuffer(hdr, 44);
    n := (fs.Size - 44) div 2; SetLength(sm, n); fs.ReadBuffer(sm[0], n * 2); fs.Free;
    NrInit(rx, rate, band, 20);
    i := 0;
    while i < n do begin k := 4410; if i + k > n then k := n - i; NrPush(rx, sm[i], k); Inc(i, k); end;
    while NrTake(rx, fr) do
      lst.Add(Format('%d %d %d %d %s', [fr.flags, fr.n, fr.ack, fr.off, Hex(fr)]));
    lst.SaveToFile(ParamStr(5));
  end;
end.
