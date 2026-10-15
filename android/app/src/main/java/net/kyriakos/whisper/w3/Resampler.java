package net.kyriakos.whisper.w3;

/**
 * Converts a stream of samples from one rate to another (windowed sinc,
 * 24 taps, 256 sub-steps with straight-line interpolation between them).
 * The rates may be any numbers, such as a handheld's measured 43,229.6.
 *
 * Content near the top of the band is slightly weakened, which the modem
 * does not mind. Images of the input cannot fall on the modem's carriers
 * for any of the rates in use (see docs/FORMAT3.md).
 */
public final class Resampler {
    static final int H = 12, TAPS = 2 * H, PHASES = 256;
    private final float[] table = new float[(PHASES + 1) * TAPS];
    private final float[] hist = new float[TAPS * 2 + 8192];
    private int have = 0;                        // samples in hist
    private double pos = H - 1;                  // output position, in input samples, relative to hist[0]
    private double step;                         // input samples per output sample

    public Resampler(double inRate, double outRate) {
        setRates(inRate, outRate);
        double fc = Math.min(inRate, outRate) / 2 / inRate;                 // cut-off, as a fraction of the input rate
        double beta = 6;
        for (int p = 0; p <= PHASES; p++) {
            double frac = (double) p / PHASES;
            double sum = 0;
            for (int k = 0; k < TAPS; k++) {
                double t = k - (H - 1) - frac;                           // distance from the output point
                double sinc = Math.abs(t) < 1e-9 ? 2 * fc : Math.sin(2 * Math.PI * fc * t) / (Math.PI * t);
                double r = t / (H + 0.5);
                double w = Math.abs(r) >= 1 ? 0 : bessel0(beta * Math.sqrt(1 - r * r)) / bessel0(beta);
                table[p * TAPS + k] = (float) (sinc * w);
                sum += sinc * w;
            }
            for (int k = 0; k < TAPS; k++) table[p * TAPS + k] /= (float) sum;   // unity gain at 0 Hz
        }
    }

    public void setRates(double inRate, double outRate) { step = inRate / outRate; }

    private static double bessel0(double x) {
        double s = 1, t = 1;
        for (int k = 1; k < 30; k++) { t *= (x / (2 * k)) * (x / (2 * k)); s += t; }
        return s;
    }

    /** Converts n input samples; returns how many output samples were written to out (which must be big enough). */
    public int process(float[] in, int off, int n, float[] out, int outOff) {
        int w = 0, i = 0;
        while (i < n) {
            int take = Math.min(n - i, hist.length - have);
            System.arraycopy(in, off + i, hist, have, take);
            have += take; i += take;
            while (pos + H + 1 < have) {
                int base = (int) Math.floor(pos);
                double frac = pos - base;
                double fp = frac * PHASES;
                int p = (int) fp;
                float b = (float) (fp - p);
                int t0 = p * TAPS, t1 = t0 + TAPS;
                int s0 = base - (H - 1);
                float acc0 = 0, acc1 = 0;
                for (int k = 0; k < TAPS; k++) { float x = hist[s0 + k]; acc0 += x * table[t0 + k]; acc1 += x * table[t1 + k]; }
                out[outOff + w++] = acc0 + (acc1 - acc0) * b;
                pos += step;
            }
            // keep the last samples the filter still needs
            int keep = (int) Math.floor(pos) - (H - 1) - 1;
            if (keep > 0) {
                System.arraycopy(hist, keep, hist, 0, have - keep);
                have -= keep; pos -= keep;
            }
        }
        return w;
    }

    /** How many output samples n input samples can make, at most. */
    public int maxOut(int n) { return (int) Math.ceil(n / step) + 4; }

    /** A whole buffer at once. */
    public static float[] convert(float[] in, double inRate, double outRate) {
        Resampler r = new Resampler(inRate, outRate);
        float[] out = new float[r.maxOut(in.length) + TAPS];
        float[] pad = new float[in.length + TAPS];
        System.arraycopy(in, 0, pad, 0, in.length);
        int n = r.process(pad, 0, pad.length, out, 0);
        return java.util.Arrays.copyOf(out, n);
    }
}
