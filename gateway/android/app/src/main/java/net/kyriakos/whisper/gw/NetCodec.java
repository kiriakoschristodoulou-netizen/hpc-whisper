package net.kyriakos.whisper.gw;

import java.util.Arrays;

/**
 * Whisper Net frames (frame version 3, NET-PROTOCOL.md section 2) on the HPC
 * Whisper sound format: Reed-Solomon over GF(16), CRC, and making a frame's
 * symbols. Free of Android classes: tested on a desktop.
 */
public final class NetCodec {
    private NetCodec() {}
    public static final int VERSION = 3, MAXLEN = 53, MAXB = 10;
    public static final int FL_TURN = 0x80, FL_SYNC = 0x40;
    public static final int[] PREAMBLE = {0, 15, 0, 15, 11, 4, 11, 4};

    /** One frame. */
    public static final class Frame {
        public int flags, n, ack, off, fixed, gap, B;
        public byte[] data = new byte[0];
        /** receiver: the block (1 ms) where it ended */
        public long endBlk;
    }

    // ---------- GF(16), x^4 + x + 1 ----------
    private static final int[] EXP = new int[30], LOG = new int[16];
    private static final int[] GEN;
    static {
        int x = 1;
        for (int i = 0; i < 15; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if ((x & 16) != 0) x ^= 0x13; }
        for (int i = 15; i < 30; i++) EXP[i] = EXP[i - 15];
        int[] g = {1};
        for (int i = 1; i <= 4; i++) {
            int[] r = new int[g.length + 1];
            for (int j = 0; j < g.length; j++) { r[j] ^= g[j]; r[j + 1] ^= mul(g[j], EXP[i]); }
            g = r;
        }
        GEN = g;
    }
    static int mul(int a, int b) { return (a != 0 && b != 0) ? EXP[LOG[a] + LOG[b]] : 0; }
    static int div(int a, int b) { return a != 0 ? EXP[(LOG[a] - LOG[b] + 15) % 15] : 0; }

    public static int[] rsEncode(int[] d) {
        int[] r = new int[15];
        System.arraycopy(d, 0, r, 0, 11);
        for (int i = 0; i < 11; i++) {
            int c = r[i];
            if (c != 0) for (int j = 1; j < 5; j++) r[i + j] ^= mul(GEN[j], c);
        }
        int[] out = new int[15];
        System.arraycopy(d, 0, out, 0, 11);
        System.arraycopy(r, 11, out, 11, 4);
        return out;
    }

    private static int polyAt(int[] c, int x) { int y = 0; for (int v : c) y = mul(y, x) ^ v; return y; }

    /** Decoded data (11 nibbles) and how many symbols were corrected; null if it cannot be. */
    public static final class RS { int[] data; int fixed; }

    /** Errors and erasures: 2 * errors + erasures <= 4. eras: symbol indices 0..14 not to trust. */
    public static RS rsDecode(int[] word, int[] eras) {
        int[] c = word.clone();
        int[] S = new int[5];
        boolean bad = false;
        for (int i = 1; i <= 4; i++) { S[i] = polyAt(c, EXP[i]); if (S[i] != 0) bad = true; }
        if (!bad) { RS r = new RS(); r.data = Arrays.copyOf(c, 11); return r; }
        int f = eras == null ? 0 : eras.length;
        if (f > 4) return null;
        int[] lam = {1};
        for (int k = 0; k < f; k++) {
            int X = EXP[14 - eras[k]];
            int[] n = new int[lam.length + 1];
            for (int j = 0; j < lam.length; j++) { n[j] ^= lam[j]; n[j + 1] ^= mul(lam[j], X); }
            lam = n;
        }
        int[] B = lam.clone();
        int L = f;
        for (int r = f + 1; r <= 4; r++) {
            int d = 0;
            for (int j = 0; j < lam.length && j < r; j++) d ^= mul(lam[j], S[r - j]);
            int[] xB = new int[B.length + 1];
            System.arraycopy(B, 0, xB, 1, B.length);
            if (d == 0) { B = xB; continue; }
            int[] T = Arrays.copyOf(lam, Math.max(lam.length, xB.length));
            for (int j = 0; j < xB.length; j++) T[j] ^= mul(d, xB[j]);
            if (2 * L <= r + f - 1) {
                L = r + f - L;
                int[] nb = new int[lam.length];
                for (int j = 0; j < lam.length; j++) nb[j] = div(lam[j], d);
                B = nb;
            } else B = xB;
            lam = T;
        }
        int len = lam.length;
        while (len > 1 && lam[len - 1] == 0) len--;
        lam = Arrays.copyOf(lam, len);
        int deg = len - 1;
        if (deg > 4 || 2 * (deg - f) + f > 4) return null;
        int[] pos = new int[15];
        int np = 0;
        for (int p = 0; p < 15; p++) {
            int xi = EXP[(15 - p) % 15], v = 0;
            for (int i = lam.length - 1; i >= 0; i--) v = mul(v, xi) ^ lam[i];
            if (v == 0) pos[np++] = p;
        }
        if (np != deg) return null;
        int[] Om = new int[4];
        for (int i = 0; i < 4; i++) for (int j = 0; j <= i; j++) Om[i] ^= mul(S[i - j + 1], j < lam.length ? lam[j] : 0);
        for (int q = 0; q < np; q++) {
            int p = pos[q], xi = EXP[(15 - p) % 15];
            int om = 0;
            for (int i = 3; i >= 0; i--) om = mul(om, xi) ^ Om[i];
            int dl = 0;
            for (int i = 1; i < lam.length; i += 2) if (lam[i] != 0) dl ^= mul(lam[i], EXP[(LOG[xi] * (i - 1)) % 15]);
            if (dl == 0) return null;
            c[14 - p] ^= div(om, dl);
        }
        for (int i = 1; i <= 4; i++) if (polyAt(c, EXP[i]) != 0) return null;
        RS r = new RS();
        r.data = Arrays.copyOf(c, 11);
        r.fixed = np;
        return r;
    }

    public static int crc16(int[] b, int n) {
        int c = 0xFFFF;
        for (int i = 0; i < n; i++) {
            c ^= (b[i] & 255) << 8;
            for (int k = 0; k < 8; k++) c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
        }
        return c;
    }

    public static int blocks(int n) { return ((n + 2) * 2 + 10) / 11; }

    /** The symbols (0..15) of a whole frame: preamble, then the interleaved code words. */
    public static int[] encode(int flags, int n, int ack, int off, byte[] data, int dOff) {
        if (n > MAXLEN) n = MAXLEN;
        int[] all = new int[5 + n];
        all[0] = (flags & 0xC0) | n;
        all[1] = (ack >> 8) & 255; all[2] = ack & 255; all[3] = (off >> 8) & 255; all[4] = off & 255;
        for (int i = 0; i < n; i++) all[5 + i] = data[dOff + i] & 255;
        int c = crc16(all, n + 5);
        int nb = blocks(n), K = nb + 1;
        int[][] words = new int[K][];
        int[] h = new int[11];
        h[0] = VERSION; h[1] = all[0] >> 4; h[2] = all[0] & 15;
        for (int i = 1; i <= 4; i++) { h[1 + 2 * i] = all[i] >> 4; h[2 + 2 * i] = all[i] & 15; }
        words[0] = rsEncode(h);
        int[] nib = new int[nb * 11];
        for (int i = 0; i < n; i++) { nib[2 * i] = all[5 + i] >> 4; nib[2 * i + 1] = all[5 + i] & 15; }
        nib[2 * n] = c >> 12; nib[2 * n + 1] = (c >> 8) & 15; nib[2 * n + 2] = (c >> 4) & 15; nib[2 * n + 3] = c & 15;
        for (int k = 0; k < nb; k++) words[k + 1] = rsEncode(Arrays.copyOfRange(nib, k * 11, k * 11 + 11));
        int[] sy = new int[8 + K * 15];
        System.arraycopy(PREAMBLE, 0, sy, 0, 8);
        for (int t = 0; t < K * 15; t++) sy[8 + t] = words[t % K][t / K];
        return sy;
    }

    /** Parse K de-interleaved, RS-decoded words (11 nibbles each, 0 the header); null if not a frame. */
    public static Frame parse(int[][] w, int K) {
        int[] d = w[0];
        if (d[0] != VERSION) return null;
        int b0 = (d[1] << 4) | d[2], n = b0 & 63;
        if (n > MAXLEN || blocks(n) != K - 1) return null;
        int[] all = new int[5 + n];
        all[0] = b0;
        for (int i = 1; i <= 4; i++) all[i] = (d[1 + 2 * i] << 4) | d[2 + 2 * i];
        int[] by = new int[(K - 1) * 11 / 2];
        for (int i = 0; i < by.length; i++) {
            int p = 2 * i;
            by[i] = (w[1 + p / 11][p % 11] << 4) | w[1 + (p + 1) / 11][(p + 1) % 11];
        }
        for (int i = 0; i < n; i++) all[5 + i] = by[i];
        int c = crc16(all, n + 5);
        if ((c >> 8) != by[n] || (c & 255) != by[n + 1]) return null;
        Frame f = new Frame();
        f.flags = b0 & 0xC0; f.n = n; f.ack = (all[1] << 8) | all[2]; f.off = (all[3] << 8) | all[4];
        f.data = new byte[n];
        for (int i = 0; i < n; i++) f.data[i] = (byte) all[5 + i];
        return f;
    }
}
