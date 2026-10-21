import java.io.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import net.kyriakos.whisper.gw.*;
import net.kyriakos.whisper.gw.NetCodec.Frame;

/** Handheld (Pascal) and phone (Java) frames against each other, through a simulated room. */
public class CrossTest {
    static String hex(byte[] d) { if (d.length == 0) return "-"; StringBuilder s = new StringBuilder(); for (byte b : d) s.append(String.format("%02X", b & 255)); return s.toString(); }
    static String line(int flags, int n, int ack, int off, byte[] d) { return flags + " " + n + " " + ack + " " + off + " " + hex(d); }

    static void wav(String fn, short[] s, int rate) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(44 + s.length * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + s.length * 2).put("WAVEfmt ".getBytes()).putInt(16).putShort((short) 1).putShort((short) 1)
         .putInt(rate).putInt(rate * 2).putShort((short) 2).putShort((short) 16).put("data".getBytes()).putInt(s.length * 2);
        for (short v : s) b.putShort(v);
        Files.write(Paths.get(fn), b.array());
    }
    static short[] readWav(String fn) throws IOException {
        byte[] a = Files.readAllBytes(Paths.get(fn));
        ByteBuffer b = ByteBuffer.wrap(a).order(ByteOrder.LITTLE_ENDIAN);
        short[] s = new short[(a.length - 44) / 2];
        for (int i = 0; i < s.length; i++) s[i] = b.getShort(44 + 2 * i);
        return s;
    }

    public static void main(String[] a) throws Exception {
        Room room = new Room();
        if (a[0].equals("make")) {            // make out.wav list.txt nf seed noise
            int nf = Integer.parseInt(a[3]);
            Random r = new Random(Long.parseLong(a[4]));
            room.noise = Double.parseDouble(a[5]); room.rnd = new Random(r.nextLong());
            List<int[]> syms = new ArrayList<>(); List<String> lst = new ArrayList<>();
            for (int k = 0; k < nf; k++) {
                int n = r.nextInt(NetCodec.MAXLEN + 1);
                int flags = (k == nf - 1 ? NetCodec.FL_TURN : 0) | (k == 0 ? NetCodec.FL_SYNC : 0);
                int ack = r.nextInt(65536), off = r.nextInt(65536);
                byte[] d = new byte[n]; r.nextBytes(d);
                syms.add(NetCodec.encode(flags, n, ack, off, d, 0));
                lst.add(line(flags, n, ack, off, d));
            }
            short[] p = NetTx.turn(syms, 48000, 18000, 20, 0.8, 19800, 150, 100, 60, 150);
            short[] pad = new short[p.length + 96000];
            System.arraycopy(p, 0, pad, 48000, p.length);
            wav(a[1], room.pass(pad, 48000, 43200), 43200);
            Files.write(Paths.get(a[2]), lst);
        } else {                              // read in.wav rate band list.txt noise
            int rate = Integer.parseInt(a[2]), band = Integer.parseInt(a[3]);
            room.noise = Double.parseDouble(a[5]);
            short[] s = room.pass(readWav(a[1]), rate, 48000);
            List<String> got = new ArrayList<>();
            NetRx rx = new NetRx(48000, band, 20, new NetRx.Listener() {
                public void onFrame(Frame f) { got.add(line(f.flags, f.n, f.ack, f.off, f.data)); }
                public void onUnreadable() { got.add("unreadable"); }
            });
            float[] x = new float[4800];
            for (int i = 0; i < s.length; i += 4800) {
                int k = Math.min(4800, s.length - i);
                for (int j = 0; j < k; j++) x[j] = s[i + j] / 32768f;
                rx.push(x, 0, k, 1);
            }
            Files.write(Paths.get(a[4]), got);
            System.out.println("quiet for " + rx.quietFor());
        }
    }
}
