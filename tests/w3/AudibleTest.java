import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Tx;

import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.util.Random;

/**
 * Silent frames must be silent: from both programs, on every silent channel, with
 * several payloads, after each program's own conversion to the speaker's rate
 * (the phone: 48,000; the handheld: 44,100). Up to 3 kHz below the channel's band
 * each part (0-6, 6-12 kHz, 12 kHz to there) must stay 55 dB under the frame's own
 * band, and its edge (the last 3 kHz) 30 dB under it; no sample may reach full scale.
 *   java -cp cls AudibleTest linux/w3tool
 */
public class AudibleTest {
    static int fails = 0;

    static double[] spectrum(float[] x, int rate, double[] fOut) {
        int N = Integer.highestOneBit(x.length) * 2;
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < x.length; i++) re[i] = x[i] * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / x.length));
        LevelTest.fft(re, im, -1);
        double[] p = new double[N / 2];
        for (int k = 0; k < N / 2; k++) p[k] = re[k] * re[k] + im[k] * im[k];
        fOut[0] = (double) rate / N;
        return p;
    }

    static double sum(double[] p, double df, double lo, double hi) {
        double s = 1e-30;
        for (int k = (int) Math.ceil(lo / df); k < p.length && k * df < hi; k++) s += p[k];
        return s;
    }

    static void check(String name, float[] x, int rate, int ch) {
        double lo = ch == Channel.SU_WIDE ? 18150 : 19950;
        double[] df = new double[1];
        double[] p = spectrum(x, rate, df);
        double band = sum(p, df[0], lo, 21250);
        // far below the band: 0-6, 6-12 and 12 kHz to 3 kHz under it, each 55 dB down; the last 3 kHz (its edge) 30 dB
        double e = lo - 3000;
        double a = 10 * Math.log10(sum(p, df[0], 0, 6000) / band), b = 10 * Math.log10(sum(p, df[0], 6000, 12000) / band),
                c = 10 * Math.log10(sum(p, df[0], 12000, e) / band), d = 10 * Math.log10(sum(p, df[0], e, lo - 450) / band);
        float pk = 0;
        for (float v : x) pk = Math.max(pk, Math.abs(v));
        boolean ok = a <= -55 && b <= -55 && c <= -55 && d <= -30 && pk < 0.999f;
        System.out.printf("%s %-38s 0-6k %6.1f  6-12k %6.1f  12-%.1fk %6.1f  edge %6.1f dB  peak %.2f%n", ok ? "ok   " : "FAIL ", name, a, b, e / 1000, c, d, pk);
        if (!ok) fails++;
    }

    static float[] readWav(String path) throws Exception {
        byte[] d = Files.readAllBytes(new File(path).toPath());
        ByteBuffer b = ByteBuffer.wrap(d, 44, d.length - 44).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[(d.length - 44) / 2];
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        return x;
    }

    public static void main(String[] a) throws Exception {
        Random rnd = new Random(3);
        int[] chans = {Channel.SU_NARROW, Channel.SU_WIDE, Channel.SD};
        int[] sizes = {5, 40, 200};
        for (int ch : chans)
            for (int n : sizes) {
                byte[] msg = new byte[n];
                rnd.nextBytes(msg);
                Channel c = Channel.get(ch);
                // the phone: its loudest silent level, then its converter (and its guard against overshoot)
                float[] f = Tx.frame(c, BitMap.standard(c), 1, msg, 0.9f);
                float[] y = Resampler.convert(f, Channel.RATE, 48000);
                float pk = 0; for (float v : y) pk = Math.max(pk, Math.abs(v));
                if (pk > 0.97f) for (int i = 0; i < y.length; i++) y[i] *= 0.97f / pk;
                check("phone, " + Channel.NAMES[ch] + ", " + n + " bytes", y, 48000, ch);
                // the handheld: its own frame maker and converter (the test tool built from its code)
                if (a.length > 0) {
                    File pl = File.createTempFile("aud", ".bin"), out = File.createTempFile("aud", ".wav");
                    Files.write(pl.toPath(), msg);
                    Process pr = new ProcessBuilder(a[0], "tx", "" + ch, "1", pl.getPath(), out.getPath(), "44").inheritIO().start();
                    pr.waitFor();
                    check("handheld, " + Channel.NAMES[ch] + ", " + n + " bytes", readWav(out.getPath()), 44100, ch);
                    pl.delete(); out.delete();
                }
            }
        // the phone's TRAIN frames (link check, loudness check) are silent-channel sound too
        float[] t = Resampler.convert(Tx.train(Channel.get(Channel.SD), 0.9f), Channel.RATE, 48000);
        check("phone, train frame (loudness check)", t, 48000, Channel.SD);
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
