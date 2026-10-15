package net.kyriakos.whisper.w3;

/**
 * Reed-Solomon codes over GF(256), polynomial 0x11D, generator roots
 * alpha^0 .. alpha^(p-1), systematic with the check bytes last.
 * Byte i of an n-byte code word is the coefficient of x^(n-1-i).
 */
public final class Rs {
    static final int[] EXP = new int[512], LOG = new int[256];
    static {
        int x = 1;
        for (int i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if ((x & 0x100) != 0) x ^= 0x11D; }
        for (int i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
    }
    static int mul(int a, int b) { return (a == 0 || b == 0) ? 0 : EXP[LOG[a] + LOG[b]]; }
    static int div(int a, int b) { return a == 0 ? 0 : EXP[LOG[a] + 255 - LOG[b]]; }

    private static final int[][] GEN = new int[33][];
    static int[] gen(int p) {
        if (GEN[p] != null) return GEN[p];
        int[] g = {1};
        for (int i = 0; i < p; i++) {                      // g *= (x - alpha^i), highest power first
            int[] r = new int[g.length + 1];
            for (int j = 0; j < g.length; j++) { r[j] ^= g[j]; r[j + 1] ^= mul(g[j], EXP[i]); }
            g = r;
        }
        return GEN[p] = g;
    }

    /** Writes the p check bytes of data[off .. off+k) to out[outOff ..]. */
    public static void encode(byte[] data, int off, int k, int p, byte[] out, int outOff) {
        int[] g = gen(p);
        int[] r = new int[p];
        for (int i = 0; i < k; i++) {
            int f = (data[off + i] & 255) ^ r[0];
            System.arraycopy(r, 1, r, 0, p - 1);
            r[p - 1] = 0;
            if (f != 0) for (int j = 0; j < p; j++) r[j] ^= mul(g[j + 1], f);
        }
        for (int j = 0; j < p; j++) out[outOff + j] = (byte) r[j];
    }

    /** Corrects cw[off .. off+n) in place (p check bytes); returns the number of errors fixed, or -1. */
    public static int decode(byte[] cw, int off, int n, int p) {
        int[] s = new int[p];
        boolean clean = true;
        for (int i = 0; i < p; i++) {
            int v = 0, a = EXP[i];
            for (int j = 0; j < n; j++) v = mul(v, a) ^ (cw[off + j] & 255);
            s[i] = v;
            if (v != 0) clean = false;
        }
        if (clean) return 0;
        // Berlekamp-Massey: the error locator, lowest power first
        int[] lam = new int[p + 1], b = new int[p + 1];
        lam[0] = 1; b[0] = 1;
        int L = 0, m = 1, bb = 1;
        for (int r = 0; r < p; r++) {
            int d = s[r];
            for (int i = 1; i <= L; i++) d ^= mul(lam[i], s[r - i]);
            if (d == 0) { m++; continue; }
            int[] t = lam.clone();
            int coef = div(d, bb);
            for (int i = 0; i + m <= p; i++) lam[i + m] ^= mul(coef, b[i]);
            if (2 * L <= r) { L = r + 1 - L; b = t; bb = d; m = 1; } else m++;
        }
        if (2 * L > p) return -1;
        // error evaluator: omega = (s * lam) mod x^p
        int[] om = new int[p];
        for (int i = 0; i < p; i++) { int v = 0; for (int j = 0; j <= i && j <= L; j++) v ^= mul(lam[j], s[i - j]); om[i] = v; }
        int found = 0;
        for (int j = 0; j < n; j++) {
            int pw = n - 1 - j;                          // this byte is the coefficient of x^pw
            int xinv = EXP[(255 - pw % 255) % 255];      // X^-1
            int v = 0, xp = 1;
            for (int i = 0; i <= L; i++) { v ^= mul(lam[i], xp); xp = mul(xp, xinv); }
            if (v != 0) continue;
            // Forney (first root alpha^0): e = X * omega(X^-1) / lambda'(X^-1)
            int o = 0; xp = 1;
            for (int i = 0; i < p; i++) { o ^= mul(om[i], xp); xp = mul(xp, xinv); }
            int dl = 0; xp = 1;
            for (int i = 1; i <= L; i += 2) { dl ^= mul(lam[i], xp); xp = mul(xp, mul(xinv, xinv)); }
            if (dl == 0) return -1;
            int e = mul(EXP[pw % 255], div(o, dl));
            cw[off + j] ^= (byte) e;
            found++;
        }
        if (found != L) return -1;
        // check: all syndromes now zero
        for (int i = 0; i < p; i++) {
            int v = 0, a = EXP[i];
            for (int j = 0; j < n; j++) v = mul(v, a) ^ (cw[off + j] & 255);
            if (v != 0) return -1;
        }
        return found;
    }
}
