import java.io.*;
import java.net.*;
import java.util.*;
import net.kyriakos.whisper.gw.*;

/**
 * The phone side of the end-to-end test: the real Session, Gateway, receiver
 * and transmitter, with a simulated room between it and the handheld program
 * (Pascal netsim) that talks to it over TCP:
 *   'P' n + n samples: the handheld played this turn (43.2 kHz)
 *   'O'              : the handheld opened its microphone
 *   'M' n            : the handheld wants n samples of microphone
 *   'S' ms           : the handheld waits ms
 * Time is the number of samples fed, so it runs faster than real time.
 */
public class E2ESim {
    static final int HR = 43200, PR = 48000;
    static Session sess;
    static Room room = new Room();
    static Random noiseRnd = new Random(5);
    static double noise = 150;
    static long G = 0, skipUntil = 0, cursor = 0;
    static short[] hear = new short[HR * 1200];
    static long turns = 0, replies = 0;
    static boolean trace = false;

    static void mix(int at, short[] y) {
        if (at + y.length >= hear.length) hear = Arrays.copyOf(hear, Math.max(hear.length * 2, at + y.length + 1));
        for (int i = 0; i < y.length; i++) hear[at + i] = (short) Math.max(-32768, Math.min(32767, hear[at + i] + y[i]));
    }

    static void feed(short[] x) {
        float[] f = new float[480];
        int i = 0;
        while (i < x.length) {
            if (G < skipUntil) { int k = (int) Math.min(x.length - i, skipUntil - G); i += k; G += k; continue; }
            int k = Math.min(480, x.length - i);
            for (int j = 0; j < k; j++) f[j] = (float) ((x[i + j] + noise * noiseRnd.nextGaussian()) / 32768.0);
            i += k; G += k;
            sess.onAudio(f, k);
        }
    }

    public static void main(String[] a) throws Exception {
        trace = a.length > 0;
        if (System.getenv("E2E_NOISE") != null) noise = Double.parseDouble(System.getenv("E2E_NOISE"));
        room.noise = 0; room.ghost = 0.25; room.echo = 0.2;
        Gateway gw = new Gateway(s -> { if (trace) System.err.println("gw: " + s); });
        gw.remap = h -> h.equals("192.168.55.77") ? "127.0.0.1" : h;
        Session.Settings st = new Session.Settings();
        sess = new Session(st, (pcm, rate) -> {
            replies++;
            int start = (int) Math.round(G * (double) HR / PR);
            mix(start, room.pass(pcm, PR, HR));
            skipUntil = G + pcm.length + (long) st.afterMs * PR / 1000;
        }, gw, new Random(77));
        ServerSocket ss = new ServerSocket(0);
        System.out.println("PORT " + ss.getLocalPort());
        System.out.flush();
        Socket s = ss.accept();
        DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
        OutputStream out = new BufferedOutputStream(s.getOutputStream());
        try {
            while (true) {
                int c = in.read();
                if (c < 0) break;
                int n = in.readInt();
                switch (c) {
                    case 'P': {
                        byte[] raw = new byte[n * 2];
                        in.readFully(raw);
                        short[] p = new short[n];
                        for (int i = 0; i < n; i++) p[i] = (short) ((raw[2 * i] & 255) | (raw[2 * i + 1] << 8));
                        turns++;
                        feed(room.pass(p, HR, PR));
                        out.write('k'); out.flush();
                        break;
                    }
                    case 'O': cursor = Math.round(G * (double) HR / PR); out.write('k'); out.flush(); break;
                    case 'S': feed(new short[n * 48]); out.write('k'); out.flush(); break;
                    case 'M': {
                        feed(new short[(int) ((long) n * PR / HR)]);
                        byte[] raw = new byte[n * 2];
                        for (int i = 0; i < n; i++) {
                            int idx = (int) cursor + i;
                            double v = (idx < hear.length ? hear[idx] : 0) + noise * noiseRnd.nextGaussian();
                            short sv = (short) Math.max(-32768, Math.min(32767, Math.round(v)));
                            raw[2 * i] = (byte) sv; raw[2 * i + 1] = (byte) (sv >> 8);
                        }
                        cursor += n;
                        out.write(raw); out.flush();
                        break;
                    }
                }
            }
        } catch (EOFException e) { /* the handheld program ended */ }
        System.err.println("phone: turns heard " + turns + ", replies " + replies + ", frames " + sess.framesHeard() + ", gateway up " + gw.bytesUp + " B, down " + gw.bytesDown + " B");
        gw.close();
        System.exit(0);
    }
}
