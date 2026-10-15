import net.kyriakos.whisper.w3.*;
import java.io.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;

/** The phone's modem on the command line, for tests against the handheld's (w3tool.pas).
 *  tx CH TYPE payload.bin out.wav RATE [map.bin]   a frame at RATE (from 51,200)
 *  rx CH in.wav [map.bin]                          read frames (the file's rate)
 *  up in.wav out.wav NOISE                         handheld (44,100) -> chip, room -> phone (48,000)
 *  down in.wav out.wav NOISE                       phone (48,000) -> room -> handheld's ADC (43,229.6, written as 44,100) */
public class W3Tool {
    static float[] readWav(String p, int[] rate) throws IOException {
        byte[] b = Files.readAllBytes(Paths.get(p));
        ByteBuffer bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN);
        rate[0] = bb.getInt(24); int ch = bb.getShort(22);
        int o = 12, sz = 0;
        while (o + 8 <= b.length) { sz = bb.getInt(o + 4); if (b[o] == 'd' && b[o + 1] == 'a') break; o += 8 + sz; }
        o += 8; if (sz <= 0 || o + sz > b.length) sz = b.length - o;
        int n = sz / (2 * ch); float[] x = new float[n];
        for (int i = 0; i < n; i++) x[i] = bb.getShort(o + i * 2 * ch) / 32768f;
        return x;
    }
    static void writeWav(String p, float[] x, int rate) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(44 + x.length * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + x.length * 2).put("WAVE".getBytes()).put("fmt ".getBytes())
         .putInt(16).putShort((short) 1).putShort((short) 1).putInt(rate).putInt(rate * 2).putShort((short) 2).putShort((short) 16)
         .put("data".getBytes()).putInt(x.length * 2);
        for (float v : x) b.putShort((short) Math.max(-32767, Math.min(32767, Math.round(v * 32767))));
        Files.write(Paths.get(p), b.array());
    }
    static BitMap map(int ch, String p) throws IOException {
        if (p == null) return BitMap.standard(Channel.get(ch));
        return BitMap.fromMessage(Files.readAllBytes(Paths.get(p)));
    }
    static String hex(byte[] b) { StringBuilder s = new StringBuilder(); for (byte v : b) s.append(String.format("%02x", v)); return s.toString(); }

    public static void main(String[] a) throws Exception {
        switch (a[0]) {
            case "tx": {
                int ch = Integer.parseInt(a[1]), type = Integer.parseInt(a[2]), rate = Integer.parseInt(a[5]);
                byte[] pl = Files.readAllBytes(Paths.get(a[3]));
                Channel c = Channel.get(ch);
                float[] f = type == Tx.TRAIN ? Tx.train(c, c.level) : Tx.frame(c, map(ch, a.length > 6 ? a[6] : null), type, pl, c.level);
                f = Sim.pad(f, 4000, 4000);                 // frames follow silence
                writeWav(a[4], rate == 51200 ? f : Resampler.convert(f, 51200, rate), rate);
                break;
            }
            case "rx": {
                int ch = Integer.parseInt(a[1]); int[] rate = new int[1];
                float[] x = readWav(a[2], rate);
                float[] y = rate[0] == 51200 ? x : Resampler.convert(x, rate[0], 51200);
                Rx rx = new Rx(Channel.get(ch), new Rx.Sink() {
                    public void onMessage(Rx r, int t, byte[] m, float s, int f) { System.out.printf("msg %d %d %d %d %s%n", t, m.length, Math.round(s * 10), f, hex(m)); }
                    public void onTrain(Rx r, float[] s) { StringBuilder b = new StringBuilder("train"); for (float v : s) b.append(' ').append(Math.round(v * 10)); System.out.println(b); }
                    public void onFail(Rx r, String w) { }
                });
                if (a.length > 3) rx.addMap(map(ch, a[3]));
                rx.push(y, 0, y.length);
                System.out.println("frames " + rx.frames + " fails " + rx.fails);
                break;
            }
            case "up": case "down": {
                int[] rate = new int[1];
                float[] x = readWav(a[1], rate);
                Sim.NOISE = Double.parseDouble(a[3]);
                float[] y;
                if (a[0].equals("up")) {           // the file is the handheld's 44,100 output
                    float[] x432 = Sim.chip(Sim.pad(x, 4000, 4000));
                    float[] air = Resampler.convert(x432, 43200, 48000 * 1.00012);
                    y = Sim.room(air, 48000, Sim.NOISE, 0.5);
                    writeWav(a[2], y, 48000);
                } else {                            // the file is the phone's 48,000 output
                    float[] air = Resampler.convert(Sim.pad(x, 4000, 4000), 48000, 43229.6);
                    y = Sim.room(air, 43229.6, Sim.NOISE, 0.5);
                    writeWav(a[2], y, 44100);       // the handheld says 44,100
                }
                break;
            }
        }
    }
}
