package net.kyriakos.whisper.w3;

/**
 * The pairing sound check (docs/FORMAT3.md, section 7): two 2 kHz markers 2.69 s
 * apart with 32 short tones between them, from 500 Hz to 21.5 kHz. Found by its
 * markers whatever the speaker, microphone, rates or room; the time between the
 * markers gives the two devices' real rates, each tone how well that frequency
 * gets through. The same as handheld/wpair.pas. Plain Java (tested).
 */
public final class Pair {
    public static final int N = 32;
    public static final int[] HZ = {500, 1000, 1500, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000,
            13000, 14000, 15000, 16000, 17000, 17500, 18000, 18500, 19000, 19400, 19800, 20200, 20400, 20600, 20800, 21000, 21200, 21500};
    public static final int LEAD_MS = 150, MARK_MS = 250, GAP_MS = 100, STEP_MS = 70, TAIL_MS = 100, MARK_HZ = 2000, LEAD_HZ = 21700;
    public static final int A_MS = LEAD_MS, STEPS_MS = A_MS + MARK_MS + GAP_MS, B_MS = STEPS_MS + N * STEP_MS + GAP_MS,
            AB_MS = B_MS - A_MS, TOTAL_MS = B_MS + MARK_MS + TAIL_MS;
    public static final int REPORT = 0x34, REPORT_LEN = 40;   // 38 measurements, the ladder step to use + 1 (0 = none), its quality

    public static final class Result {
        public boolean found, clipped;
        public final int[] snr10 = new int[N];   // tenths of a dB above the background
        public int scale10k, peak, aAt;
        public int ladder = -1, ladderQ;          // the loudness the other side should use (its ladder step), and how clean it was
        public String why = "";                   // why it was not found
        public int band10(int loHz, int hiHz) {
            int s = 0, k = 0;
            for (int i = 0; i < N; i++) if (HZ[i] >= loHz && HZ[i] <= hiHz) { s += snr10[i]; k++; }
            return k > 0 ? s / k : -999;
        }
    }

    /** The pattern at this rate, full scale = 1. */
    public static float[] pattern(int rate) {
        float[] x = new float[(int) ((long) TOTAL_MS * rate / 1000)];
        tone(x, rate, 0, LEAD_MS, LEAD_HZ, 1000 / 32768f);
        // quieter than at first (16,000 and 11,000): played loud, a handheld's amplifier gave up after the first marker
        tone(x, rate, A_MS, MARK_MS, MARK_HZ, 9000 / 32768f);
        for (int k = 0; k < N; k++) tone(x, rate, STEPS_MS + k * STEP_MS, STEP_MS, HZ[k], 6000 / 32768f);
        tone(x, rate, B_MS, MARK_MS, MARK_HZ, 9000 / 32768f);
        return x;
    }

    private static void tone(float[] x, int rate, int fromMs, int ms, int hz, float peak) {
        int s = (int) ((long) fromMs * rate / 1000), e = (int) ((long) (fromMs + ms) * rate / 1000), ramp = rate / 200;
        for (int t = s; t < e && t < x.length; t++) {
            double g = peak;
            if (t - s < ramp) g = g * (t - s) / ramp;
            if (e - 1 - t < ramp) g = g * (e - 1 - t) / ramp;
            x[t] = (float) (g * Math.sin(2 * Math.PI * hz * (t - s) / rate));
        }
    }

    /** Goertzel power of hz over x[a..b), per sample. */
    static double power(float[] x, int a, int b, double hz, int rate) {
        a = Math.max(0, a); b = Math.min(x.length, b);
        int len = b - a;
        if (len < 16) return 0;
        double c = 2 * Math.cos(2 * Math.PI * hz / rate), s1 = 0, s2 = 0;
        for (int i = a; i < b; i++) { double s0 = x[i] + c * s1 - s2; s2 = s1; s1 = s0; }
        return Math.max(1e-20, (s1 * s1 + s2 * s2 - c * s1 * s2) / len);
    }

    static int findMarker(float[] x, int n, int rate, int from) {
        int blk = rate / 200, nb = (n - from) / blk;
        if (nb < 60) return -1;
        double[] p = new double[nb];
        double top = 0, bg = Double.MAX_VALUE;
        for (int i = 0; i < nb; i++) { p[i] = power(x, from + i * blk, from + (i + 1) * blk, MARK_HZ, rate); top = Math.max(top, p[i]); bg = Math.min(bg, p[i]); }
        double thr = Math.max(bg * 20, top / 4);
        int run = 0, first = -1;
        for (int i = 0; i < nb; i++) {
            if (p[i] > thr) { if (run == 0) first = i; if (++run >= 24) return from + first * blk; }
            else run = 0;
        }
        return -1;
    }

    /** Looks for the pattern in x[0..n) recorded at rate (as the sound card says). */
    public static Result analyze(float[] x, int n, int rate) {
        Result r = new Result();
        int a = findMarker(x, n, rate, 0);
        if (a < 0) { r.why = "its first beep was not found"; return r; }
        int b = findMarker(x, n, rate, a + (int) ((long) (AB_MS - 300) * rate / 1000));
        if (b < 0) { r.why = "its second beep was not found (the sound stopped, or was too faint)"; return r; }
        double s = (b - a) * 1000.0 / ((double) AB_MS * rate);
        if (s < 0.95 || s > 1.05) { r.why = String.format(java.util.Locale.US, "its two beeps were %.2f s apart, not 2.69", (b - a) / (double) rate); return r; }
        r.scale10k = (int) Math.round(s * 10000); r.aAt = a;
        int bg1 = a - (LEAD_MS + 40) * rate / 1000, bg0 = Math.max(0, bg1 - 300 * rate / 1000);
        int half = 25 * rate / 1000;
        for (int i = 0; i < N; i++) {
            int c = a + (int) Math.round((STEPS_MS - A_MS + i * STEP_MS + STEP_MS / 2.0) * rate / 1000.0 * s);
            double hz = HZ[i] / s;
            double ps = power(x, c - half, c + half, hz, rate);
            double pn = bg1 - bg0 >= 2 * half ? power(x, bg1 - 2 * half, bg1, hz, rate) : bg1 > 16 ? power(x, bg0, bg1, hz, rate) : 1e-20;
            r.snr10[i] = (int) Math.round(100 * Math.log10(ps / Math.max(pn, 1e-20)));
        }
        float pk = 0;
        for (int i = Math.max(0, a); i < Math.min(n, b + MARK_MS * rate / 1000); i++) pk = Math.max(pk, Math.abs(x[i]));
        r.peak = Math.round(pk * 100); r.clipped = pk >= 0.976f;
        r.found = true;
        return r;
    }

    public static byte[] report(Result r) {
        byte[] b = new byte[REPORT_LEN];
        b[0] = 1; b[1] = (byte) N;
        for (int i = 0; i < N; i++) b[2 + i] = (byte) Math.max(0, Math.min(255, Math.round(r.snr10[i] / 10f) + 20));
        b[34] = (byte) (r.scale10k >> 8); b[35] = (byte) r.scale10k; b[36] = (byte) r.peak; b[37] = (byte) (r.clipped ? 1 : 0);
        b[38] = (byte) (r.ladder + 1); b[39] = (byte) Math.max(0, Math.min(255, r.ladderQ));
        return b;
    }

    public static Result read(byte[] b) {
        Result r = new Result();
        if (b.length < REPORT_LEN || b[0] != 1 || (b[1] & 255) != N) return r;
        for (int i = 0; i < N; i++) r.snr10[i] = ((b[2 + i] & 255) - 20) * 10;
        r.scale10k = (b[34] & 255) << 8 | (b[35] & 255);
        r.peak = b[36] & 255; r.clipped = (b[37] & 1) != 0; r.found = true;
        r.ladder = (b[38] & 255) - 1; r.ladderQ = b[39] & 255;
        return r;
    }
}
