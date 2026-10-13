package net.kyriakos.whisper;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

/**
 * HPC Whisper sound format, version 2: the receiver. A line-by-line port of
 * modem.js (the page's receiver), kept free of Android classes so the same
 * file is tested on a desktop against the same recordings. See docs/FORMAT.md.
 */
public final class Receiver {
    public static final int GRID_START = 18000, GRID_STEP = 100, GRID_N = 36;
    public static final int[] BANDS = {18000, 18500, 19000, 19500, 20000};
    public static final double[] SPEEDS = {0.048, 0.032, 0.020};
    public static final int[] PREAMBLE = {0, 15, 0, 15, 11, 4, 11, 4};
    public static final int VERSION = 2, MAXLEN = 44;

    /** One frame read: "the document is L bytes long, and from o it reads bytes". */
    public static final class Frame {
        public int seq, doc, L, o, fixed, bandHz, ms, gap, B;
        public byte[] bytes;
    }

    public interface Listener {
        void onFrame(Frame f);
        void onUnreadable(int bandHz, int ms);
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
    static final class RS { int[] data; int fixed; }

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

    public static int bodyBlocks(int n) { return (int) Math.ceil((n + 4) * 2 / 11.0); }

    // ---------- the receiver ----------
    private final int blk, cap = 12000;
    private final double[][] preRe = new double[GRID_N][cap + 1], preIm = new double[GRID_N][cap + 1];
    private final double[] acc = new double[GRID_N * 2], oc = new double[GRID_N], os = new double[GRID_N];
    private final double[] cw = new double[GRID_N], sw = new double[GRID_N];
    private int inBlk = 0;
    /** Blocks (1 ms each) heard so far. */
    public int n = 0;
    private final Listener listener;
    public int framesRead = 0, unreadable = 0, gaps = 0, corrected = 0;

    private static final class Cand { double score; boolean full; int band, bandHz, si; double D; int start, age; }
    private static final class Pending {
        int band, bandHz, si, start, pstart, B; double D, score, ref; boolean full;
        int[] ghostD = new int[0];          // ghost distances (grid steps) ...
        double[][] ghostW = new double[0][];  // ... and their strength for each of the 16 tones
    }
    private final Map<Integer, Cand> cands = new HashMap<>();
    private final List<Pending> pending = new ArrayList<>();

    public Receiver(int rate, Listener listener) {
        this.listener = listener;
        blk = Math.round(rate / 1000f);
        for (int t = 0; t < GRID_N; t++) {
            double w = 2 * Math.PI * (GRID_START + t * GRID_STEP) / rate;
            cw[t] = Math.cos(w); sw[t] = Math.sin(w); oc[t] = 1;
        }
    }

    /** Feed samples (any number). */
    public void push(float[] x, int off, int len, int stride) {
        for (int i = 0; i < len; i++) {
            double v = x[off + i * stride];
            for (int t = 0; t < GRID_N; t++) {
                double c = oc[t], s = os[t];
                acc[2 * t] += v * c; acc[2 * t + 1] -= v * s;
                oc[t] = c * cw[t] - s * sw[t];
                os[t] = s * cw[t] + c * sw[t];
            }
            if (++inBlk == blk) { endBlock(); inBlk = 0; }
        }
    }

    private void endBlock() {
        if ((n & 63) == 0) for (int t = 0; t < GRID_N; t++) { double r = Math.hypot(oc[t], os[t]); oc[t] /= r; os[t] /= r; }
        int k = n % cap, k1 = (n + 1) % cap;
        for (int t = 0; t < GRID_N; t++) {
            preRe[t][k1] = preRe[t][k] + acc[2 * t];
            preIm[t][k1] = preIm[t][k] + acc[2 * t + 1];
            acc[2 * t] = 0; acc[2 * t + 1] = 0;
        }
        n++;
        search();
        readPending();
    }

    /** Power of grid tone t over blocks [a, b). */
    public double pow(int t, int a, int b) {
        int A = a % cap, Bk = b % cap;
        double re = preRe[t][Bk] - preRe[t][A], im = preIm[t][Bk] - preIm[t][A];
        return re * re + im * im;
    }

    private int symS; private double symShare, symP;
    private void sym(int band, int a, int b) {
        int best = -1; double bv = -1, sum = 0;
        for (int i = 0; i < 16; i++) {
            double v = pow(band + i, a, b);
            sum += v;
            if (v > bv) { bv = v; best = i; }
        }
        symS = best; symShare = sum > 0 ? bv / sum : 0; symP = bv;
    }

    private final double[] rv = new double[16];

    /** The expected tone's share of the band if it is the strongest, or a close second
     *  (behind a ghost of itself); -1 if not. */
    private double ranked(int band, int a, int b, int want) {
        int best = -1, second = -1; double sum = 0;
        for (int i = 0; i < 16; i++) { rv[i] = pow(band + i, a, b); sum += rv[i]; }
        for (int i = 0; i < 16; i++) {
            if (best < 0 || rv[i] > rv[best]) { second = best; best = i; }
            else if (second < 0 || rv[i] > rv[second]) second = i;
        }
        double share = sum > 0 ? rv[want] / sum : 0;
        boolean ok = (want == best && share >= 0.3)
                || (want == second && rv[want] >= 0.2 * rv[best] && (rv[want] + rv[best]) / sum >= 0.6);
        return ok ? Math.max(share, 0.5) : -1;
    }

    /** Some sound chips add a "ghost" of every tone at a fixed distance (the Jornada 720:
     *  900 Hz lower, at the top of the band louder than the tone). Measured on the
     *  preamble's known tones; see modem.js learnGhosts. */
    private void learnGhosts(Pending F) {
        java.util.Set<Integer> skip = new java.util.HashSet<>(Arrays.asList(0, 1, -1, 2, -2, 15, -15, 4, -4, 7, -7, 11, -11));
        List<Object[]> found = new ArrayList<>();      // {d, med, low, sum[16], count[16]}
        for (int d = -35; d <= 35; d++) {
            if (skip.contains(d)) continue;
            double[] sumT = new double[16]; int[] cntT = new int[16];
            List<Double> all = new ArrayList<>();
            for (int k = 0; k < PREAMBLE.length; k++) {
                int v = PREAMBLE[k], g = F.band + v, t = g + d;
                if (t < 0 || t >= GRID_N) continue;
                int a = winA(F.pstart, F.D, k), b = winB(F.pstart, F.D, k);
                double pg = pow(g, a, b);
                if (!(pg > 0)) continue;
                double r = pow(t, a, b) / pg;
                sumT[v] += r; cntT[v]++;
                all.add(r);
            }
            if (all.size() < 3) continue;
            java.util.Collections.sort(all);
            found.add(new Object[]{d, all.get(all.size() >> 1), all.get((all.size() - 1) >> 2), sumT, cntT});
        }
        if (found.isEmpty()) { F.ghostD = new int[0]; F.ghostW = new double[0][]; return; }
        double[] meds = new double[found.size()];
        for (int i = 0; i < meds.length; i++) meds[i] = (Double) found.get(i)[1];
        Arrays.sort(meds);
        double floor = meds[meds.length >> 1];
        List<Object[]> keep = new ArrayList<>();
        for (Object[] x : found)
            if ((Double) x[1] >= Math.max(0.05, 8 * floor) && (Double) x[2] >= Math.max(0.02, 3 * floor)) keep.add(x);
        keep.sort((x, y) -> Double.compare((Double) y[1], (Double) x[1]));
        int nk = Math.min(3, keep.size());
        F.ghostD = new int[nk]; F.ghostW = new double[nk][];
        for (int i = 0; i < nk; i++) {
            Object[] x = keep.get(i);
            double[] sumT = (double[]) x[3]; int[] cntT = (int[]) x[4];
            List<double[]> pts = new ArrayList<>();
            for (int v = 0; v < 16; v++)
                if (cntT[v] > 0) pts.add(new double[]{v, Math.log(Math.max(1e-3, Math.min(8, sumT[v] / cntT[v])))});
            double[] w = new double[16];
            for (int v = 0; v < 16; v++) {
                double[] lo = pts.get(0), hi = pts.get(pts.size() - 1);
                for (double[] p : pts) { if (p[0] <= v) lo = p; if (p[0] >= v && hi[0] >= p[0]) hi = p; }
                if (pts.size() == 1 || hi[0] == lo[0]) w[v] = Math.exp(lo[1]);
                else w[v] = Math.exp(lo[1] + (hi[1] - lo[1]) * (v - lo[0]) / (hi[0] - lo[0]));
                if (v < pts.get(0)[0]) w[v] = Math.exp(pts.get(0)[1]);
                if (v > pts.get(pts.size() - 1)[0]) w[v] = Math.exp(pts.get(pts.size() - 1)[1]);
            }
            F.ghostD[i] = (Integer) x[0]; F.ghostW[i] = w;
        }
    }

    private final double[] amp = new double[GRID_N];

    /** Which of the band's 16 tones was sent: each candidate's pattern (tone and ghosts) against what was heard. */
    private void symG(Pending F, int a, int b) {
        if (F.ghostD.length == 0) { sym(F.band, a, b); return; }
        for (int t = 0; t < GRID_N; t++) amp[t] = Math.sqrt(pow(t, a, b));
        int best = -1; double bv = -1, sum = 0;
        for (int v = 0; v < 16; v++) {
            int g = F.band + v;
            double dot = amp[g], norm = 1;
            for (int i = 0; i < F.ghostD.length; i++) {
                int t = g + F.ghostD[i]; double wv = F.ghostW[i][v];
                if (t >= 0 && t < GRID_N) { dot += Math.sqrt(wv) * amp[t]; norm += wv; }
            }
            double sc = dot / Math.sqrt(norm), e = sc * sc;
            sum += e;
            if (e > bv) { bv = e; best = v; }
        }
        symS = best; symShare = sum > 0 ? bv / sum : 0; symP = bv;
    }

    private static int winA(int start, double D, int k) { return start + (int) Math.round(k * D + D * 0.25); }
    private static int winB(int start, double D, int k) {
        int a = winA(start, D, k), b = start + (int) Math.round(k * D + D * 0.9);
        return Math.max(b, a + 1);
    }

    private void search() {
        int now = n;
        for (int bi = 0; bi < BANDS.length; bi++) {
            int band = (BANDS[bi] - GRID_START) / GRID_STEP;
            for (int si = 0; si < SPEEDS.length; si++) {
                int key = bi * 4 + si;
                double D = SPEEDS[si] * 1000;
                int start = now - (int) Math.round(PREAMBLE.length * D);
                Cand hit = null;
                if (start > 1) {
                    double sum = 0; int miss = 0;
                    for (int k = 0; k < PREAMBLE.length && miss <= 2; k++) {
                        double sh = ranked(band, winA(start, D, k), winB(start, D, k), PREAMBLE[k]);
                        if (sh < 0) { miss++; continue; }
                        sum += sh;
                    }
                    if (miss <= 2 && sum >= 0.45 * (PREAMBLE.length - miss)) {
                        hit = new Cand();
                        hit.score = sum; hit.full = miss == 0; hit.band = band; hit.bandHz = BANDS[bi];
                        hit.si = si; hit.D = D; hit.start = start;
                    }
                }
                Cand c = cands.get(key);
                if (hit != null) {
                    if (c == null || hit.score >= c.score) cands.put(key, hit);
                    else c.age = 0;
                } else if (c != null && ++c.age > 2) {
                    cands.remove(key);
                    Pending dup = null;
                    for (Pending p : pending)
                        if (Math.abs(p.pstart - c.start) < c.D * 2 && p.band == c.band) { dup = p; break; }
                    if (dup != null) { if (c.score > dup.score) lockFrom(c, dup); }
                    else { Pending p = new Pending(); lockFrom(c, p); pending.add(p); }
                }
            }
        }
    }

    private static void lockFrom(Cand c, Pending p) {
        p.band = c.band; p.bandHz = c.bandHz; p.si = c.si; p.D = c.D; p.score = c.score; p.full = c.full;
        p.start = c.start + (int) Math.round(PREAMBLE.length * c.D); p.pstart = c.start; p.B = 0;
        p.ghostD = new int[0]; p.ghostW = new double[0][];
    }

    private RS decodeBlock(int[] w, double[] conf, boolean light) {
        RS r = rsDecode(w, null);
        if (r != null || light) return r;
        Integer[] order = new Integer[15];
        for (int i = 0; i < 15; i++) order[i] = i;
        Arrays.sort(order, Comparator.comparingDouble(i -> conf[i]));
        for (int f = 1; f <= 4; f++) {
            int[] e = new int[f];
            for (int i = 0; i < f; i++) e[i] = order[i];
            r = rsDecode(w, e);
            if (r != null) return r;
        }
        return null;
    }

    private Frame decodeWith(Pending F, int B, int p, int o, boolean light) {
        int K = B + 1;
        int[][] words = new int[K][15];
        double[][] confs = new double[K][15];
        for (int t = 0; t < K * 15; t++) {
            int st = F.start + (t >= p ? o : 0);
            symG(F, winA(st, F.D, t), winB(st, F.D, t));
            words[t % K][t / K] = symS; confs[t % K][t / K] = symShare;
        }
        RS hr = decodeBlock(words[0], confs[0], light);
        if (hr == null || hr.data[0] != VERSION) return null;
        int[] d = hr.data;
        int hn = (d[1] << 4) | d[2], hseq = (d[3] << 4) | d[4], hdoc = (d[5] << 4) | d[6];
        int hL = (d[7] << 12) | (d[8] << 8) | (d[9] << 4) | d[10];
        if (hn > MAXLEN || bodyBlocks(hn) != B) return null;
        int[] nib = new int[B * 11];
        int fixed = hr.fixed;
        for (int k = 1; k < K; k++) {
            RS r = decodeBlock(words[k], confs[k], light);
            if (r == null) return null;
            fixed += r.fixed;
            System.arraycopy(r.data, 0, nib, (k - 1) * 11, 11);
        }
        int[] by = new int[nib.length / 2];
        for (int i = 0; i < by.length; i++) by[i] = (nib[2 * i] << 4) | nib[2 * i + 1];
        int off = (by[0] << 8) | by[1];
        int crc = (by[2 + hn] << 8) | by[3 + hn];
        int[] all = new int[7 + hn];
        all[0] = hn; all[1] = hseq; all[2] = hdoc; all[3] = hL >> 8; all[4] = hL & 255; all[5] = off >> 8; all[6] = off & 255;
        for (int i = 0; i < hn; i++) all[7 + i] = by[2 + i];
        if (crc16(all, all.length) != crc) return null;
        Frame f = new Frame();
        f.seq = hseq; f.doc = hdoc; f.L = hL; f.o = off; f.fixed = fixed; f.B = B;
        f.bytes = new byte[hn];
        for (int i = 0; i < hn; i++) f.bytes[i] = (byte) by[2 + i];
        return f;
    }

    private double bandPow(int band, int a, int b) {
        double v = 0;
        for (int i = 0; i < 16; i++) v += pow(band + i, a, b);
        return v / Math.max(1, b - a);
    }

    private void readPending() {
        int now = n, maxB = bodyBlocks(MAXLEN);
        for (int i = 0; i < pending.size(); i++) {
            Pending F = pending.get(i);
            if (F.B == 0) { F.B = 1; F.ref = bandPow(F.band, F.pstart, F.start); learnGhosts(F); }
            Frame res = null;
            while (F.B <= maxB) {
                int e = winB(F.start, F.D, (F.B + 1) * 15 - 1);
                if (e > now) break;
                res = decodeWith(F, F.B, Integer.MAX_VALUE, 0, false);
                if (res != null) break;
                F.B++;
            }
            int maxO = Math.max((int) Math.round(F.D * 2.5), 80);
            if (res == null) {
                int last = F.start + (int) Math.round((maxB + 1) * 15 * F.D) + maxO + 20;
                if (last > now) continue;
                if (F.full) res = searchGaps(F, maxO);
            }
            pending.remove(i--);
            if (res == null) {
                if (F.full) { unreadable++; listener.onUnreadable(F.bandHz, (int) Math.round(SPEEDS[F.si] * 1000)); }
                continue;
            }
            int end = F.start + res.gap + (int) Math.round((res.B + 1) * 15 * F.D);
            for (int j = pending.size() - 1; j >= 0; j--) {
                Pending q = pending.get(j);
                if (q.pstart >= F.pstart && q.pstart < end) pending.remove(j);
            }
            i = -1;
            framesRead++; corrected += res.fixed;
            res.bandHz = F.bandHz; res.ms = (int) Math.round(SPEEDS[F.si] * 1000);
            listener.onFrame(res);
        }
    }

    private Frame searchGaps(Pending F, int maxO) {
        int maxB = bodyBlocks(MAXLEN), stopAt = F.start + (int) Math.round((maxB + 1) * 15 * F.D) + maxO;
        LinkedHashSet<Integer> sizes = new LinkedHashSet<>();
        int quiet = 0;
        for (int t = F.start + 15; t < stopAt; t += 5) {
            if (bandPow(F.band, t, t + 5) < 0.1 * F.ref) {
                if (++quiet == 8) {
                    double len = (t - 35 - F.start) / F.D / 15;
                    int[] cand = {(int) Math.round(len) - 1, (int) Math.round(len) - 2, (int) Math.floor(len) - 1};
                    for (int B : cand) if (B >= 1 && B <= maxB) sizes.add(B);
                }
            } else quiet = 0;
        }
        if (sizes.isEmpty()) for (int B = 1; B <= maxB; B++) sizes.add(B);
        for (int B : sizes) { Frame r = searchGap(F, B, maxO); if (r != null) return r; }
        return null;
    }

    private Frame searchGap(Pending F, int B, int maxO) {
        Frame best = null;
        int K = (B + 1) * 15, step = Math.max(1, (int) Math.round(F.D / 8));
        for (int p = 0; p < K; p += 2) {
            for (int o = step; o <= maxO; o += step) {
                Frame t = decodeWith(F, B, p, o, true);
                if (t != null && (best == null || t.fixed < best.fixed)) { best = t; best.gap = o; }
            }
            if (best != null && best.fixed == 0) break;
        }
        if (best != null) gaps++;
        return best;
    }
}
