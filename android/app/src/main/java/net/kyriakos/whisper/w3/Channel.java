package net.kyriakos.whisper.w3;

/** The five sound channels of format 3 (docs/FORMAT3.md, section 1). */
public final class Channel {
    public static final int SU_NARROW = 0, SU_WIDE = 1, SD = 2, FU = 3, FD = 4, COUNT = 5;
    public static final int RATE = 51200, N = 512, CP = 128, SYM = N + CP, FADE = 26;
    public static final String[] NAMES = {"silent up", "silent up (wide)", "silent down", "fast up", "fast down"};

    public final int id;
    public final int[] bins;          // carrier bins, lowest first (bin b = b x 100 Hz)
    public final boolean[] pilot;
    public final int defaultBits;
    public final boolean silent;
    public final float level;         // default peak, full scale = 1

    private Channel(int id, int[] bins, boolean[] pilot, int defaultBits, boolean silent, float level) {
        this.id = id; this.bins = bins; this.pilot = pilot; this.defaultBits = defaultBits; this.silent = silent; this.level = level;
    }

    public int count() { return bins.length; }

    /** S uses the carriers on multiples of this bin step, so it repeats after N / syncStep samples, which no other symbol does. */
    public int syncStep() { return 2 * (bins[1] - bins[0]); }
    public int syncLag() { return N / syncStep(); }

    private static Channel make(int id, int from, int to, int step, boolean silent) {
        int n = (to - from) / step + 1;
        int[] b = new int[n];
        boolean[] p = new boolean[n];
        for (int i = 0; i < n; i++) b[i] = from + i * step;
        if (silent) { p[0] = true; p[n - 1] = true; }
        else { for (int i = 0; i < n; i += 10) p[i] = true; p[n - 1] = true; }
        return new Channel(id, b, p, silent ? 2 : 1, silent, silent ? 0.5f : 0.125f);
    }

    private static final Channel[] ALL = {
            make(SU_NARROW, 200, 212, 2, true),
            make(SU_WIDE, 182, 212, 2, true),
            make(SD, 194, 208, 2, true),
            make(FU, 10, 189, 1, false),
            make(FD, 5, 119, 1, false),
    };

    public static Channel get(int id) { return ALL[id]; }

    /** The fixed quarter turns of S, R and TRAIN: P[i] = (x_i >> 9) & 3, x_(i+1) = (x_i * 25173 + 13849) mod 65536, x_0 = 11. */
    public static final int[] P = new int[256];
    /** The scrambling bytes: W[i] = (y_i >> 8) & 255, same rule, y_0 = 0x1D0F. */
    public static final byte[] W = new byte[4096];
    static {
        int x = 11;
        for (int i = 0; i < P.length; i++) { P[i] = (x >> 9) & 3; x = (x * 25173 + 13849) & 0xFFFF; }
        int y = 0x1D0F;
        for (int i = 0; i < W.length; i++) { W[i] = (byte) (y >> 8); y = (y * 25173 + 13849) & 0xFFFF; }
    }
    public static int sPhase(int c) { return P[(c * 7) & 255]; }
    public static int rPhase(int c) { return P[(c * 7 + 101) & 255]; }
    public static int trainStep(int c, int s) { return P[(c * 3 + s * 11) & 255]; }
    public static void scramble(byte[] b) { for (int i = 0; i < b.length; i++) b[i] ^= W[i & 4095]; }
}
