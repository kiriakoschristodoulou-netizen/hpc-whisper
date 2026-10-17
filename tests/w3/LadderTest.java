import net.kyriakos.whisper.w3.Ladder;
import net.kyriakos.whisper.w3.Pair;
import net.kyriakos.whisper.w3.Resampler;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/**
 * The handheld's loudness ladder, read by the phone (Ladder), against pretend handhelds.
 * The handheld's whole test sound (pattern and ladder) comes from its own code
 * (pairtool turn). Each pretend speaker is straight up to a knee and then bends ever
 * harder (a cubic, then a hard limit), and adds the Jornada's ghost: a copy 900 Hz
 * lower, 6 dB down. The phone hears it with room noise, at 48,000 samples/s.
 *   java -cp cls LadderTest turn.wav
 * Checks: the test sound and all six steps are found; the step chosen is never one where
 * the speaker distorts noticeably (its products 30 dB down or less, in a silent room), and
 * reads at 10 dB or more whenever any step read at 12. (Which of two clean steps is taken
 * can vary with the room's noise: readings vary by 1-2 dB; both are fine.)
 */
public class LadderTest {
    static float[] readWav(String p, int[] rate) throws Exception {
        byte[] d = Files.readAllBytes(Paths.get(p));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        rate[0] = b.getInt(24);
        float[] x = new float[(d.length - 44) / 2];
        b.position(44);
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        return x;
    }

    /** The pretend handheld speaker: straight to the knee, then bending; then its ghost 900 Hz lower. */
    static float[] speaker(float[] x, double knee, int rate) {
        int n = x.length;
        double[] y = new double[n];
        for (int i = 0; i < n; i++) {
            double v = x[i], a = Math.abs(v);
            if (a > knee) { double o = a - knee; a = knee + o - 0.8 * o * o / (2 * knee) - 0.4 * o * o * o / (knee * knee); }
            a = Math.min(a, knee * 1.25);
            y[i] = Math.signum(v) * a;
        }
        // the ghost: the same sound shifted 900 Hz down (single sideband), 6 dB lower
        int N = Integer.highestOneBit(n) * 2;
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < n; i++) re[i] = y[i];
        LevelTest.fft(re, im, -1);
        for (int k = N / 2 + 1; k < N; k++) { re[k] = 0; im[k] = 0; }        // analytic signal
        for (int k = 1; k < N / 2; k++) { re[k] *= 2; im[k] *= 2; }
        LevelTest.fft(re, im, +1);
        float[] out = new float[n];
        for (int i = 0; i < n; i++) {
            double ph = -2 * Math.PI * 900.0 * i / rate, ar = re[i] / N, ai = im[i] / N;
            double ghost = ar * Math.cos(ph) - ai * Math.sin(ph);
            out[i] = (float) (y[i] + 0.5 * ghost);
        }
        return out;
    }

    static final double[] measured = new double[2];          // the best step's reading, and the chosen one's

    static int run(float[] turn, int rate, double knee, double noise, long seed, StringBuilder log) {
        float[] y = speaker(turn, knee, rate);
        float[] z = Resampler.convert(y, rate, 48000);
        float[] heard = new float[z.length + 48000];
        Random rnd = new Random(seed);
        for (int i = 0; i < heard.length; i++) heard[i] = (float) (noise * rnd.nextGaussian());
        for (int i = 0; i < z.length; i++) heard[i + 24000] += 0.03f * z[i];     // about as loud as the Jornada at the phone
        Pair.Result p = Pair.analyze(heard, heard.length, 48000);
        if (!p.found) { log.append("test sound not found: ").append(p.why); return -2; }
        int from = p.aAt + (int) ((long) (Pair.TOTAL_MS - Pair.A_MS - Ladder.BEFORE_END_MS) * 48000 / 1000 * p.scale10k / 10000);
        float[] rest = new float[heard.length - from];
        System.arraycopy(heard, from, rest, 0, rest.length);
        Ladder.Result r = Ladder.read(rest, rest.length, 48000);
        if (!r.found) { log.append("ladder not read: ").append(r.why); return -2; }
        measured[0] = -99; for (double q : r.qDb) measured[0] = Math.max(measured[0], q); measured[1] = r.qDb[r.choice];
        for (int i = 0; i < Ladder.STEPS; i++) log.append(String.format(" %d:%.0f(%+.0f)", i, r.qDb[i], r.riseDb[i]));
        return r.choice;
    }

    /** Without noise: how far under the carriers the speaker's products lie, per step. */
    static double[] distortion(float[] turn, int rate, double knee) {
        StringBuilder sb = new StringBuilder();
        float[] y = speaker(turn, knee, rate);
        float[] z = Resampler.convert(y, rate, 48000);
        float[] heard = new float[z.length + 48000];
        for (int i = 0; i < z.length; i++) heard[i + 24000] = 0.03f * z[i];
        Random rnd = new Random(1);
        for (int i = 0; i < heard.length; i++) heard[i] += (float) (1e-6 * rnd.nextGaussian());   // a whisper of a floor
        Pair.Result p = Pair.analyze(heard, heard.length, 48000);
        int from = p.aAt + (int) ((long) (Pair.TOTAL_MS - Pair.A_MS - Ladder.BEFORE_END_MS) * 48000 / 1000);
        float[] rest = new float[heard.length - from];
        System.arraycopy(heard, from, rest, 0, rest.length);
        Ladder.Result r = Ladder.read(rest, rest.length, 48000);
        if (!p.found || !r.found) { System.out.println("  (no reference: " + p.why + r.why + ")"); return new double[Ladder.STEPS]; }
        return r.qDb;
    }

    static double dmax(double[] d) { double m = -99; for (double v : d) m = Math.max(m, v); return m; }

    public static void main(String[] a) throws Exception {
        int[] rate = new int[1];
        float[] turn = readWav(a[0], rate);
        int fails = 0;
        double[] knees = {1.0, 0.75, 0.55, 0.4, 0.28, 0.2};
        double[] noises = {1e-4, 1e-3, 2.5e-3};
        int[][] choice = new int[knees.length][noises.length];
        for (int ki = 0; ki < knees.length; ki++) {
            double[] dist = distortion(turn, rate[0], knees[ki]);
            StringBuilder d = new StringBuilder();
            for (int i = 0; i < Ladder.STEPS; i++) d.append(String.format(" %d:%.0f", i, dist[i]));
            System.out.println("speaker bends at " + knees[ki] + "; each step without room noise (receiver SNR, dB):" + d);
            for (int ni = 0; ni < noises.length; ni++) {
                StringBuilder log = new StringBuilder();
                int c = run(turn, rate[0], knees[ki], noises[ni], 5 + ki, log);
                choice[ki][ni] = c;
                // never a step where the speaker distorts noticeably (products 30 dB down or less, in a silent room);
                // and good enough to type with (10 dB) whenever any step was
                boolean ok = c >= 0 && dist[c] >= 30 && (measured[0] < 12 || measured[1] >= 10);
                System.out.printf("  %s room noise %.0e: step %d chosen; measured%s%n", ok ? "ok  " : "FAIL", noises[ni], c, log);
                if (!ok) fails++;
            }
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
