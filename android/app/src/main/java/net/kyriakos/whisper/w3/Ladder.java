package net.kyriakos.whisper.w3;

/**
 * The handheld's loudness ladder (docs/FORMAT3.md, section 7): after its test sound
 * the handheld plays its silent channel at six falling peaks (29,000 down to 5,100 of
 * 32,767), each a TRAIN frame, with 150 ms between them. It cannot judge them itself
 * (it does not listen while it plays); the phone does, and tells it which to use.
 *
 * Each burst is a TRAIN frame (known phases on every carrier), so the phone's own
 * receiver measures, carrier by carrier, how clean it arrived: the signal against
 * everything else, the room's noise and the speaker's distortion alike (a speaker
 * driven too hard puts its products right on the carriers). Louder steps beat the
 * noise better until the speaker starts to distort. From the quietest step read, the
 * phone goes one step louder only while that clearly helps (2.5 dB better for 3 dB
 * louder; less means the speaker is already bending, even if a noisy room hides it),
 * and stops once a step reaches 22 dB (enough for 1 bit a carrier), unless it also
 * raises the audible range (1-17 kHz) by 3 dB or more, when a quieter one is taken.
 * Plain Java (tests/w3/LadderTest).
 */
public final class Ladder {
    public static final int STEPS = 6, GAP_MS = 150;
    /** Where to start listening for the ladder: this long before the end of the test sound (ms). */
    public static final int BEFORE_END_MS = 300;
    static final double GOOD_DB = 22;

    public static final class Result {
        public boolean found;
        public int choice = -1;
        public final double[] qDb = new double[STEPS];      // how clean each step arrived: the receiver's SNR (dB), -99 = unread
        public final double[] riseDb = new double[STEPS];   // the audible range over the room
        public String why = "";
    }

    /** x: what the microphone heard (at rate), from 0.3 s before the end of the test sound (START_MS) on. */
    public static Result read(float[] x, int n, int rate) {
        Result r = new Result();
        int B = 512, nb = n / B;
        if (nb < 20) { r.why = "too short"; return r; }
        float[] re = new float[B], im = new float[B];
        double hz = (double) rate / B;
        double[] band = new double[nb];
        int b0 = (int) Math.ceil(19950 / hz), b1 = (int) Math.floor(21250 / hz);
        for (int k = 0; k < nb; k++) {
            for (int i = 0; i < B; i++) { re[i] = x[k * B + i] * (float) (0.5 - 0.5 * Math.cos(2 * Math.PI * i / B)); im[i] = 0; }
            Fft.run(re, im, -1);
            double s = 0;
            for (int j = b0; j <= b1; j++) s += re[j] * re[j] + im[j] * im[j];
            band[k] = s + 1e-20;
        }
        double[] sorted = band.clone();
        java.util.Arrays.sort(sorted);
        double room = sorted[nb / 10];                       // the quiet between and after the bursts
        // the bursts, in order: 10 dB over the room (and, in a very quiet room, no lower than 35 dB under the
        // loudest: the speaker's own tails would otherwise join them), at least 4 blocks long
        room = Math.max(room, sorted[nb - 1] * 3.16e-5);
        int[] from = new int[STEPS], to = new int[STEPS];
        int found = 0, k = 0;
        while (k < nb && found < STEPS) {
            if (band[k] < room * 10) { k++; continue; }
            int s = k;
            while (k < nb && band[k] >= room * 10) k++;
            if (k - s < 4) continue;
            from[found] = s * B; to[found] = k * B; found++;
        }
        if (found < STEPS) { r.why = found + " of the " + STEPS + " loudness steps were heard"; return r; }
        // the room, for the audible range: the gap before the first burst (or the quietest stretch)
        double roomAud = Double.MAX_VALUE;
        if (from[0] >= rate / 10) roomAud = audible(x, from[0] - rate / 10, from[0] - rate / 50, rate);
        for (int i = 0; i + 1 < STEPS; i++) if (from[i + 1] - to[i] > rate / 10) roomAud = Math.min(roomAud, audible(x, to[i] + rate / 40, from[i + 1] - rate / 40, rate));
        if (roomAud == Double.MAX_VALUE) { r.why = "no quiet between the loudness steps"; return r; }
        for (int i = 0; i < STEPS; i++) {
            int a = Math.max(0, from[i] - rate / 20), b = Math.min(n, to[i] + rate / 20);
            r.qDb[i] = trainSnr(x, a, b, rate);
            r.riseDb[i] = 10 * Math.log10(audible(x, from[i], to[i], rate) / Math.max(roomAud, 1e-30));
        }
        double top = -99;
        for (int i = 0; i < STEPS; i++) top = Math.max(top, r.qDb[i]);
        if (top <= -99) { r.why = "the loudness steps could not be read"; return r; }
        // from the quietest step that was read, one louder at a time while that clearly helps (2.5 dB of the 3 dB
        // louder: a step that helps less is already distorting, even if a noisy room hides it), until clean enough
        int best = STEPS - 1;
        while (best > 0 && r.qDb[best] < 0) best--;
        while (best > 0 && r.qDb[best] < GOOD_DB && r.qDb[best - 1] >= r.qDb[best] + 2.5) best--;
        while (best < STEPS - 1 && r.riseDb[best] >= 3) best++;      // heard: quieter
        r.choice = best; r.found = true;
        return r;
    }

    /** The phone's receiver reads the TRAIN frame in x[a..b): the average over the carriers of their SNR (dB), or -99. */
    static double trainSnr(float[] x, int a, int b, int rate) {
        float[] seg = new float[b - a + rate / 10];
        System.arraycopy(x, a, seg, 0, b - a);
        float[] y = rate == Channel.RATE ? seg : Resampler.convert(seg, rate, Channel.RATE);
        final double[] got = {-99};
        Rx rx = new Rx(Channel.get(Channel.SU_NARROW), new Rx.Sink() {
            public void onMessage(Rx r, int type, byte[] msg, float snrDb, int fixed) { }
            public void onTrain(Rx r, float[] snrDb) {
                double s = 0; int k = 0;
                for (int c = 0; c < snrDb.length; c++) if (!r.ch.pilot[c]) { s += snrDb[c]; k++; }
                if (k > 0 && got[0] <= -99) got[0] = s / k;
            }
            public void onFail(Rx r, String why) { }
        });
        rx.push(y, 0, y.length);
        return got[0];
    }

    /** Power spectrum (half, per bin) of x[a..b), Hann window, zero-padded to a power of two. */
    static double[] power(float[] x, int a, int b, int rate) {
        int n = b - a, N = 1;
        while (N < n) N <<= 1;
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < n; i++) re[i] = x[a + i] * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / n));
        fft(re, im);
        double[] p = new double[N / 2];
        for (int i = 0; i < N / 2; i++) p[i] = re[i] * re[i] + im[i] * im[i];
        return p;
    }

    static double around(double[] p, double df, double f) {
        int c = (int) Math.round(f / df), w = Math.max(1, (int) Math.round(30 / df));
        double s = 0;
        for (int i = Math.max(0, c - w); i <= Math.min(p.length - 1, c + w); i++) s += p[i];
        return s;
    }

    static double audible(float[] x, int a, int b, int rate) {
        if (b - a < 256) return 1e-30;
        double[] p = power(x, a, b, rate);
        double df = (double) rate / p.length / 2, s = 0;
        for (int i = (int) (1000 / df); i < p.length && i * df < 17000; i++) s += p[i];
        return s / ((double) (b - a) * p.length) + 1e-30;       // power per sample, whatever the length
    }

    static void fft(double[] re, double[] im) {
        int n = re.length;
        for (int i = 1, j = 0; i < n; i++) { int bit = n >> 1; for (; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
        for (int len = 2; len <= n; len <<= 1) {
            double ang = -2 * Math.PI / len;
            for (int i = 0; i < n; i += len)
                for (int k = 0; k < len / 2; k++) {
                    double wr = Math.cos(ang * k), wi = Math.sin(ang * k);
                    int a = i + k, b = a + len / 2;
                    double xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
                }
        }
    }
}
