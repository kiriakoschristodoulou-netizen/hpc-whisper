import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.LevelCheck;
import net.kyriakos.whisper.w3.Resampler;

import java.util.Random;

/**
 * The phone's loudness self-check (LevelCheck) against pretend phones. Each phone
 * plays the check sound through a speaker that is straight up to some loudness and
 * then bends (a soft limit that makes the low products of the first device test);
 * its speaker is much weaker at 20 kHz than at 8 kHz, as phone speakers are; its
 * microphone adds room noise. The check must pick the loudest level that stays
 * clean, and never one that is heard.
 */
public class LevelTest {
    /** The phone: digital sound in, its own microphone's recording out (48,000 samples/s). */
    static float[] phone(float[] x51, double bendAt, double noise, long seed) {
        float[] x = Resampler.convert(x51, Channel.RATE, 48000);
        float[] y = new float[x.length + 9600];
        Random rnd = new Random(seed);
        for (int i = 0; i < x.length; i++) {
            double v = x[i];
            // straight below bendAt, then a smooth, uneven bend (even and odd products)
            double a = Math.abs(v);
            if (a > bendAt) { double over = a - bendAt; v = Math.signum(v) * (bendAt + over - 0.6 * over * over / (1 - bendAt + 1e-9)) + 0.3 * over * over; }
            y[i + 4800] = (float) v;
        }
        // the speaker: products below 17 kHz come out 30 dB stronger than the band near 20 kHz (a crude tilt)
        // done as: band attenuated 30 dB, everything else passed (one-pole high shelf is overkill: split by FFT)
        int n = y.length, N = Integer.highestOneBit(n) * 2;
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < n; i++) re[i] = y[i];
        fft(re, im, -1);
        for (int k = 0; k < N; k++) {
            double f = 48000.0 * Math.min(k, N - k) / N;
            double g = f > 19000 ? 0.0316 : 1.0;                  // -30 dB at 19 kHz and up
            re[k] *= g; im[k] *= g;
        }
        fft(re, im, +1);
        float[] out = new float[n];
        for (int i = 0; i < n; i++) out[i] = (float) (re[i] / N + noise * rnd.nextGaussian());
        return out;
    }

    static void fft(double[] re, double[] im, int sign) {
        int n = re.length;
        for (int i = 1, j = 0; i < n; i++) { int bit = n >> 1; for (; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
        for (int len = 2; len <= n; len <<= 1) {
            double ang = sign * 2 * Math.PI / len;
            for (int i = 0; i < n; i += len)
                for (int k = 0; k < len / 2; k++) {
                    double wr = Math.cos(ang * k), wi = Math.sin(ang * k);
                    int a = i + k, b = a + len / 2;
                    double xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
                }
        }
    }

    /** How much a level's burst puts into 1-17 kHz on this phone, with no room noise (power per sample). */
    static double products(float level, double bend) {
        float[] f = net.kyriakos.whisper.w3.Tx.train(Channel.get(Channel.SD), level);
        float[] y = phone(f, bend, 0, 1);
        int N = Integer.highestOneBit(y.length);
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < N; i++) re[i] = y[i] * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / N));
        fft(re, im, -1);
        double p = 0;
        for (int k = 0; k < N / 2; k++) { double hz = 48000.0 * k / N; if (hz >= 1000 && hz <= 17000) p += re[k] * re[k] + im[k] * im[k]; }
        return p / N / N * 2 / 0.375;
    }

    public static void main(String[] a) {
        float[] s = LevelCheck.sound();
        int fails = 0;
        double quietRoom = 3e-4;
        // the quiet room's noise power in 1-17 kHz (white noise, 48 kHz): sigma^2 * 16/24
        double floor = quietRoom * quietRoom * 16.0 / 24;
        double[] bends = {1.0, 0.7, 0.5, 0.35, 0.25, 0.1};
        for (double bend : bends) {
            // the truth: which levels make a side-sound above a quiet room's noise
            boolean[] heard = new boolean[LevelCheck.LEVELS.length];
            StringBuilder t = new StringBuilder();
            for (int i = 0; i < heard.length; i++) {
                double p = products(LevelCheck.LEVELS[i], bend);
                heard[i] = p > 2 * floor;                    // clearly over a quiet room: 3 dB or more
                t.append(String.format(" %.2f:%+.0fdB", LevelCheck.LEVELS[i], 10 * Math.log10(p / floor)));
            }
            System.out.println("phone that bends at " + bend + ", side-sound over a quiet room:" + t);
            for (double noise : new double[]{quietRoom, 3e-3}) {
                float[] rec = phone(s, bend, noise, 7);
                LevelCheck.Result r = LevelCheck.read(rec, rec.length, 48000);
                boolean ok = r.ok && (r.chosen < 0 || !heard[r.chosen]);
                int best = -1;
                for (int i = 0; i < heard.length; i++) if (!heard[i]) { best = i; break; }
                // not needlessly quiet either: within two steps of the loudest clean level
                if (ok && best >= 0 && r.chosen > best + 2) ok = false;
                System.out.printf("  %s %s room: uses %s (loudest clean %s)%n", ok ? "ok  " : "FAIL", noise <= quietRoom ? "quiet" : "noisy",
                        r.chosen >= 0 ? String.format("%.2f", LevelCheck.LEVELS[r.chosen]) : "none found, " + LevelCheck.FALLBACK,
                        best >= 0 ? String.format("%.2f", LevelCheck.LEVELS[best]) : "none");
                if (!ok) fails++;
            }
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
