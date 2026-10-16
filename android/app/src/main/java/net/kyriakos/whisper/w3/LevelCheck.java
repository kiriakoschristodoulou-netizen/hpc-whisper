package net.kyriakos.whisper.w3;

/**
 * How loud this phone can play the silent channel without a side-sound anyone hears.
 *
 * A phone's speaker and its sound processing are not perfectly straight: played loud
 * enough, a sound near 20 kHz makes products far lower down (around 8 kHz on the phone
 * of the first device tests), where they are heard. The phone plays short bursts of
 * the silent channel at falling levels and listens with its own microphone, which is
 * right next to its speaker and hears such products far better than a person would.
 * The loudest level whose burst raises nothing between 1 and 17 kHz above the room is
 * found, and the next quieter one is used: a noisy room can hide a side-sound that a
 * quiet room would let through. Plain Java, tested on a computer (tests/w3/LevelTest).
 */
public final class LevelCheck {
    public static final float[] LEVELS = {0.9f, 0.65f, 0.45f, 0.3f, 0.2f, 0.13f};
    /** When no burst was clean, or the bursts were not found: the quietest. */
    public static final float FALLBACK = 0.13f;
    static final int QUIET_MS = 400, GAP_MS = 250;
    /** A burst that raises 1-17 kHz by this much is heard. */
    static final double RISE_DB = 3;

    public static final class Result {
        public boolean ok;                 // all bursts found
        public int clean = -1;             // the loudest burst that raised nothing (index into LEVELS)
        public int chosen = -1;            // the one to use: one quieter; -1: none was clean
        public final double[] riseDb = new double[LEVELS.length];
        public final double[] bandDb = new double[LEVELS.length];  // the burst in its own band, over the room
        public float level() { return chosen >= 0 ? LEVELS[chosen] : FALLBACK; }
    }

    /** What to play (at the modem rate): quiet, then each level's burst with a gap after it. */
    public static float[] sound() {
        Channel c = Channel.get(Channel.SD);
        float[][] b = new float[LEVELS.length][];
        int n = QUIET_MS * Channel.RATE / 1000;
        for (int i = 0; i < LEVELS.length; i++) { b[i] = Tx.train(c, LEVELS[i]); n += b[i].length + GAP_MS * Channel.RATE / 1000; }
        float[] x = new float[n];
        int at = QUIET_MS * Channel.RATE / 1000;
        for (float[] f : b) { System.arraycopy(f, 0, x, at, f.length); at += f.length + GAP_MS * Channel.RATE / 1000; }
        return x;
    }

    public static int soundMs() { return sound().length * 1000 / Channel.RATE; }

    /** Reads the microphone's recording of the sound (at rate), starting a little before it. */
    public static Result read(float[] x, int n, int rate) {
        Result r = new Result();
        int B = 512, nb = n / B;
        if (nb < 20) return r;
        double[] band = new double[nb], aud = new double[nb];
        float[] re = new float[B], im = new float[B];
        double hz = (double) rate / B;
        int b0 = (int) Math.ceil(19950 / hz), b1 = (int) Math.floor(21250 / hz), a0 = (int) Math.ceil(1000 / hz), a1 = (int) Math.floor(17000 / hz);
        for (int k = 0; k < nb; k++) {
            for (int i = 0; i < B; i++) { double w = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / B); re[i] = (float) (x[k * B + i] * w); im[i] = 0; }
            Fft.run(re, im, -1);
            double sb = 0, sa = 0;
            for (int j = b0; j <= b1; j++) sb += re[j] * re[j] + im[j] * im[j];
            for (int j = a0; j <= a1; j++) sa += re[j] * re[j] + im[j] * im[j];
            band[k] = sb + 1e-20; aud[k] = sa + 1e-20;
        }
        // the room: the quietest stretch of a fifth of a second (the start is quiet by design)
        int w = Math.max(3, (int) (0.2 * rate / B));
        double bgBand = Double.MAX_VALUE, bgAud = Double.MAX_VALUE;
        for (int k = 0; k + w <= nb; k++) {
            double sb = 0, sa = 0;
            for (int j = k; j < k + w; j++) { sb += band[j]; sa += aud[j]; }
            if (sb < bgBand) { bgBand = sb; bgAud = sa; }
        }
        bgBand /= w; bgAud /= w;
        // the bursts, in order: their own band 10 dB over the room
        int found = 0, k = 0;
        while (k < nb && found < LEVELS.length) {
            if (band[k] < bgBand * 10) { k++; continue; }
            int s = k;
            while (k < nb && band[k] >= bgBand * 10) k++;
            if (k - s < 4) continue;                                   // a click, not a burst
            // the middle of the burst (its ends overlap the quiet)
            double[] a = new double[k - s - 2];
            double sb = 0;
            for (int j = s + 1; j < k - 1; j++) { a[j - s - 1] = aud[j]; sb += band[j]; }
            java.util.Arrays.sort(a);
            r.riseDb[found] = 10 * Math.log10(a[a.length / 2] / bgAud);
            r.bandDb[found] = 10 * Math.log10(sb / (k - s - 2) / bgBand);
            found++;
        }
        r.ok = found == LEVELS.length;
        if (r.ok) for (int i = 0; i < LEVELS.length; i++) if (r.riseDb[i] < RISE_DB) { r.clean = i; r.chosen = Math.min(i + 1, LEVELS.length - 1); break; }
        return r;
    }
}
