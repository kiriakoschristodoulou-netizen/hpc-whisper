package net.kyriakos.whisper.w3;

import java.util.HashMap;

/**
 * Reads frames of one channel from sound at the modem rate (51,200 samples/s).
 *
 * Finding a frame: the sync symbol repeats after 256 samples; a running
 * correlation of the sound with itself 256 samples later finds it
 * (Schmidl-Cox). The reference symbol then confirms the frame and sets the
 * timing to the sample. Each symbol after that is compared with the one
 * before; the pilots take out what all carriers share (a common turn and a
 * turn growing with frequency, which is how a drifting clock shows).
 */
public final class Rx {
    public interface Sink {
        void onMessage(Rx rx, int type, byte[] msg, float snrDb, int fixed);
        void onTrain(Rx rx, float[] snrDb);
        void onFail(Rx rx, String why);
        /** A frame's header was read: what is coming, and how many symbols long (for the diagnostics log). */
        default void onHeader(Rx rx, int type, int len, int symbols) { }
        /** A frame's sync symbol was measured: the sound is delta (a fraction, +0.001 = 0.1 %) higher than it should be
         *  (the sender's clock and ours differ); quality 0..1. The conversion to the modem rate should use a rate
         *  (1 - delta) times what it used. */
        default void onRateOffset(Rx rx, double delta, double quality) { }
    }

    static final int RB = 1 << 15, MASK = RB - 1, BACK = 8;
    public static boolean DEBUG = false;
    public final Channel ch;
    private final Sink sink;
    private final HashMap<Integer, BitMap> maps = new HashMap<>();
    private final BitMap std;

    // the sound, and the filtered copy the search uses
    private final float[] buf = new float[RB], fb = new float[RB];
    private final float[] metric = new float[RB], energy = new float[RB];
    private long t = 0;                          // samples so far
    private double P, E1, E2;
    private final Biquad[] pre;
    private final int lag;
    private float floor = -1;
    private int resum = 0;

    // state
    private static final int IDLE = 0, SEEK = 1, DECODE = 2;
    private int state = IDLE;
    /** A frame is being read now (its sync was found): the other side is still talking. */
    public boolean busy() { return state == DECODE; }
    private long scan = 600, trig, sym0;
    private int s, hsym, psym, adjust, moved;
    private double tau;
    private int type, len, mapNo;
    private BitMap cur;
    private final float[] pre_re = new float[Channel.N], pre_im = new float[Channel.N];
    private float[] prevRe, prevIm;
    private BitWriter bits;
    private double errSum; private int errN;
    private float[][] trainErr;
    public int frames, fails, gated;

    public Rx(Channel ch, Sink sink) {
        this.ch = ch; this.sink = sink;
        std = BitMap.standard(ch);
        maps.put(0, std);
        lag = ch.syncLag();
        pre = ch.silent ? new Biquad[]{Biquad.highpass(17500, 0.5412), Biquad.highpass(17500, 1.3066)}
                        : new Biquad[]{Biquad.highpass(300, 0.7071)};
    }

    public void addMap(BitMap m) { if (m.ch.id == ch.id) maps.put(m.number, m); }
    public BitMap map(int n) { return maps.get(n); }

    public void push(float[] x, int off, int n) {
        for (int i = 0; i < n; i++) {
            float v = x[off + i];
            int k = (int) (t & MASK);
            buf[k] = v;
            float f = v;
            for (Biquad b : pre) f = b.run(f);
            fb[k] = f;
            // running sums: window start d = t - 2 lag + 1
            float a = fb[(int) ((t - lag) & MASK)], o = fb[(int) ((t - 2 * lag) & MASK)];
            P += a * f - o * a;
            E2 += f * f - a * a;
            E1 += a * a - o * o;
            if (++resum >= 8192) { resum = 0; recompute(); }
            if (t >= 2 * lag) {
                long d = t - 2 * lag + 1;
                double e = Math.max(0, E2);
                metric[(int) (d & MASK)] = (float) (P / Math.max(1e-24, Math.max(E1, e)));      // 1 only when both halves are full and alike
                energy[(int) (d & MASK)] = (float) (e / lag);
            }
            t++;
            step();
        }
    }

    private void recompute() {
        double p = 0, e1 = 0, e2 = 0;
        long d = t - 2 * lag + 1;
        for (int m = 0; m < lag; m++) {
            float a = fb[(int) ((d + m) & MASK)], b = fb[(int) ((d + m + lag) & MASK)];
            p += a * b; e1 += a * a; e2 += b * b;
        }
        P = p; E1 = e1; E2 = e2;
    }

    /** Has sample index i arrived (window of n from i)? */
    private boolean have(long i, int n) { return i + n <= t; }

    private void step() {
        if (state == IDLE) {
            long last = t - 2 * lag;               // newest d with a metric
            while (scan <= last) {
                int k = (int) (scan & MASK);
                float e = energy[k];
                if (floor < 0) floor = e + 1e-12f;          // the first look
                // a frame: the two halves alike (S), and clearly louder than the recent average. A steady
                // tone (some phones make one at 20 kHz) is alike too, but never louder than its own average.
                if (metric[k] > 0.45f && e > 2f * floor && e > 1e-10f) { state = SEEK; trig = scan; return; }
                floor += (e - floor) * (1f / 4096);         // about 80 ms
                scan++;
            }
        } else if (state == SEEK) {
            if (t - 2 * lag < trig + 256 + lag) return;
            float mx = -1;
            for (long d = trig; d < trig + 256 + lag; d++) mx = Math.max(mx, metric[(int) (d & MASK)]);
            if (mx < 0.5f) { state = IDLE; scan = trig + 1; return; }
            // the metric climbs in a straight line for one lag as the window enters S and is level
            // while it stays inside: the frame starts half a lag after it is half way up
            long dh = trig;
            while (dh > trig - 2 * lag && dh > 0 && metric[(int) ((dh - 1) & MASK)] >= mx / 2) dh--;
            while (metric[(int) (dh & MASK)] < mx / 2) dh++;
            long dS = dh + lag / 2;
            // fine timing on R
            long w = dS + Channel.SYM + Channel.CP - BACK;
            if (!have(w, Channel.N + 2 * Channel.SYM)) return;      // wait for R (and some margin)
            // first a cheap look at S: does its sound lie on our carriers, spread over the band? A voice repeats
            // itself too, a click fills everything; the careful search below costs ten times as much
            if (!sLooksRight(dS + Channel.CP - BACK)) { gated++; state = IDLE; scan = trig + 2L * Channel.SYM; return; }
            // how far off the sender's carriers are, from S (read before R is); and whether S repeats as it should
            if (!rateOffset(dS + 72)) { gated++; state = IDLE; scan = trig + 2L * Channel.SYM; return; }
            float[][] y = fft(w);
            double[] sl = slope(y, true);
            double tauR = sl[0];
            long start = Math.round(dS + tauR - BACK);
            // silent carriers are 200 Hz apart: a shift of 256 samples turns each by whole turns, which
            // R cannot see. Of the three places, keep the one where S and R both match best.
            double bestQ = -1; long bestStart = start;
            int span = Channel.N / (ch.bins[1] - ch.bins[0]);
            for (int k = -1; k <= 1; k++) {
                long st = start + (long) k * span;
                if (k != 0 && span >= Channel.N) continue;
                if (st + Channel.CP - BACK < 0 || !have(st + 2 * Channel.SYM, Channel.N)) continue;
                float[][] ys = fft(st + Channel.CP - BACK), yr = fft(st + Channel.SYM + Channel.CP - BACK);
                // S leaves every second carrier off and R fills them all: so in the right place the "off"
                // carriers hold nothing in S and their share in R. With few carriers the slopes alone can
                // match almost as well 256 samples away.
                double q = slope(ys, false)[1] + slope(yr, true)[1] + 2 * (offShare(yr) - offShare(ys));
                if (q > bestQ) { bestQ = q; bestStart = st; }
            }
            start = bestStart;
            y = fft(start + Channel.SYM + Channel.CP - BACK);
            sl = slope(y, true);
            if (DEBUG) System.err.printf("trig %d dS %d mx %.2f tauR %.1f start %d coh %.2f%n", trig, dS, mx, tauR, start, sl[1]);
            if (sl[1] < 0.5) { state = IDLE; scan = trig + lag; return; }     // not a frame of ours
            sym0 = start; prevRe = y[0]; prevIm = y[1];
            s = 2; adjust = 0; tau = 0; moved = 0;
            hsym = (Codec.HEADER + Codec.HEADER_CHECK) * 8; hsym = (hsym + std.bitsPerSymbol() - 1) / std.bitsPerSymbol();
            psym = -1; cur = std; bits = new BitWriter(); errSum = 0; errN = 0; trainErr = null;
            state = DECODE;
        }
        if (state == DECODE) {
            while (true) {
                long w = sym0 + (long) s * Channel.SYM + Channel.CP - BACK + adjust;
                if (!have(w, Channel.N)) return;
                symbol(w);
                s++;
                if (s == 2 + hsym) {
                    byte[] h = bits.bytes(Codec.HEADER + Codec.HEADER_CHECK);
                    Channel.scramble(h, ch);
                    int[] hd = Codec.readHeader(h);
                    if (DEBUG) System.err.printf("header snr %.1f dB%n", 10 * Math.log10(errN / Math.max(1e-9, errSum)));
                    if (hd == null) { if (DEBUG) System.err.printf("header snr %.1f dB over %d symbols, %d carriers%n", 10 * Math.log10(errN / Math.max(1e-9, errSum)), hsym, errN); fail("header"); return; }
                    type = hd[0]; len = hd[1]; mapNo = hd[2];
                    cur = maps.get(mapNo);
                    if (cur == null) { fail("map " + mapNo + " unknown"); return; }
                    bits = new BitWriter();
                    if (type == Tx.TRAIN) { psym = Tx.TRAIN_SYMBOLS; trainErr = new float[2][ch.count()]; }
                    else psym = (Codec.codedLength(len) * 8 + cur.bitsPerSymbol() - 1) / Math.max(1, cur.bitsPerSymbol());
                    errSum = 0; errN = 0;
                    sink.onHeader(this, type, len, psym);
                }
                if (psym >= 0 && s == 2 + hsym + psym) { finish(); return; }
            }
        }
    }

    private void fail(String why) {
        fails++;
        state = IDLE;
        scan = Math.max(sym0 + Channel.SYM, trig + lag);       // never back over where it was triggered: the same noise would trigger it again and again
        sink.onFail(this, why);
    }

    private void finish() {
        state = IDLE;
        scan = sym0 + (long) (2 + hsym + psym) * Channel.SYM;
        if (type == Tx.TRAIN) {
            float[] snr = new float[ch.count()];
            for (int c = 0; c < snr.length; c++) snr[c] = (float) (10 * Math.log10(trainErr[1][c] / Math.max(1e-6, trainErr[0][c])));
            frames++;
            sink.onTrain(this, snr);
            return;
        }
        int[] fixed = new int[1];
        byte[] coded = bits.bytes(Codec.codedLength(len));
        Channel.scramble(coded, ch);
        byte[] msg = Codec.decode(coded, len, fixed);
        if (msg == null) {
            if (DEBUG) System.err.printf("payload failed: snr %.1f dB, adjust %d, symbols %d%n", 10 * Math.log10(errN / Math.max(1e-9, errSum)), adjust, psym);
            fails++; sink.onFail(this, "payload"); return;
        }
        frames++;
        float snr = (float) (10 * Math.log10(errN / Math.max(1e-6, errSum)));
        sink.onMessage(this, type, msg, snr, fixed[0]);
    }

    /** The share of the power on the carriers S leaves off. */
    private double offShare(float[][] y) {
        double off = 0, all = 1e-30;
        for (int c = 0; c < ch.count(); c++) {
            double p = y[0][c] * y[0][c] + y[1][c] * y[1][c];
            all += p;
            if (ch.bins[c] % ch.syncStep() != 0) off += p;
        }
        return off / all;
    }

    /** S at w: at least half the carriers it uses hold a tenth of their average power; on a fast channel, the
     *  upper half of the band holds at least a hundredth of what the lower half holds (the same test as the
     *  handheld's). */
    private boolean sLooksRight(long w) {
        float[][] y = fft(w);
        int n = ch.count(), step = ch.syncStep(), cnt = 0, on = 0;
        double sum = 0, lo = 0, hi = 0;
        double[] p = new double[n];
        for (int c = 0; c < n; c++) {
            p[c] = -1;
            if (ch.bins[c] % step != 0) continue;
            p[c] = (double) y[0][c] * y[0][c] + (double) y[1][c] * y[1][c];
            sum += p[c]; cnt++;
            if (c < n / 2) lo += p[c]; else hi += p[c];
        }
        if (cnt == 0 || sum <= 0) return false;
        for (int c = 0; c < n; c++) if (p[c] >= 0 && p[c] * 10 * cnt >= sum) on++;
        if (on * 2 < cnt) return false;
        return ch.silent || hi * 100 >= lo;
    }

    /**
     * How far the sound's carriers are from where they should be (a fraction): S repeats after one lag, and a
     * carrier whose frequency is off by a fraction d turns by 2 pi d m between one repeat and the next, m being its
     * bin over the sync step (a whole number: 50 for 20 kHz). The turn of each carrier over the repeats gives d.
     * Reads no more than 3 % off; quality is how well the carriers agree.
     */
    private boolean rateOffset(long b) {
        int step = ch.syncStep(), n = ch.count(), K = Channel.N / lag;
        if (K < 2) return true;
        if (!have(b, K * lag + 8)) return true;
        int stride = Math.max(1, (n / step + 1) / 16), used = 0;
        double[] th = new double[n], wt = new double[n], mm = new double[n];
        int cnt = 0;
        double tot = 0, sz = 0;
        for (int c = 0; c < n; c++) {
            if (ch.bins[c] % step != 0) continue;
            if ((cnt++ % stride) != 0) continue;
            double[][] x = new double[K][2];
            for (int k = 0; k < K; k++) {
                double re = 0, im = 0;
                for (int i = 0; i < lag; i++) {
                    double v = buf[(int) ((b + (long) k * lag + i) & MASK)];
                    double a = 2 * Math.PI * ((ch.bins[c] * (long) i) % Channel.N) / Channel.N;
                    re += v * Math.cos(a); im -= v * Math.sin(a);
                }
                x[k][0] = re; x[k][1] = im;
            }
            double zr = 0, zi = 0, e = 0;
            for (int k = 0; k + 1 < K; k++) {
                zr += x[k][0] * x[k + 1][0] + x[k][1] * x[k + 1][1];
                zi += x[k][0] * x[k + 1][1] - x[k][1] * x[k + 1][0];
                e += x[k][0] * x[k][0] + x[k][1] * x[k][1];
            }
            th[used] = Math.atan2(zi, zr) / (2 * Math.PI);
            wt[used] = Math.hypot(zr, zi);
            sz += wt[used];
            mm[used] = ch.bins[c] / (double) step;
            tot += e;
            used++;
        }
        if (used < 2) return true;
        // the repeats of a true S are alike (1); a voice, a click or noise falls far short
        if (sz < 0.45 * tot) return false;
        // a coarse reading from the carriers that turn least, then the rest, each corrected for whole turns
        int lo = 0;
        for (int i = 1; i < used; i++) if (mm[i] < mm[lo]) lo = i;
        double d = th[lo] / mm[lo];
        for (int pass = 0; pass < 2; pass++) {
            double num = 0, den = 0;
            for (int i = 0; i < used; i++) {
                double r = th[i] - d * mm[i];
                r -= Math.rint(r);
                num += wt[i] * (d * mm[i] + r) * mm[i]; den += wt[i] * mm[i] * mm[i];
            }
            d = num / den;
        }
        double sw = 0, sr = 0;
        for (int i = 0; i < used; i++) {
            double r = th[i] - d * mm[i];
            r -= Math.rint(r);
            sw += wt[i]; sr += wt[i] * r * r;
        }
        double rms = Math.sqrt(sr / Math.max(sw, 1e-30));
        double q = Math.max(0, 1 - rms / 0.1);
        if (Math.abs(d) > 0.03) q = 0;
        sink.onRateOffset(this, d, q);
        return true;
    }

    private float[][] fft(long w) {
        for (int i = 0; i < Channel.N; i++) { pre_re[i] = buf[(int) ((w + i) & MASK)]; pre_im[i] = 0; }
        Fft.run(pre_re, pre_im, -1);
        int n = ch.count();
        float[] re = new float[n], im = new float[n];
        for (int c = 0; c < n; c++) { re[c] = pre_re[ch.bins[c]]; im[c] = pre_im[ch.bins[c]]; }
        return new float[][]{re, im};
    }

    /** On the reference symbol (ref) or the sync symbol: {window early by (samples), coherence 0..1}. */
    private double[] slope(float[][] y, boolean ref) {
        int n = ch.count();
        double[] zr = new double[n], zi = new double[n];
        for (int c = 0; c < n; c++) {
            if (!ref && ch.bins[c] % ch.syncStep() != 0) { zr[c] = 0; zi[c] = 0; continue; }     // S leaves these off
            double a = Math.PI * 2 * (ref ? Channel.rPhase(c) : Channel.sPhase(c)) / 4;
            double cr = Math.cos(a), ci = -Math.sin(a);
            zr[c] = y[0][c] * cr - y[1][c] * ci; zi[c] = y[0][c] * ci + y[1][c] * cr;
        }
        // the room's response: the strongest arrival tells how early the window is
        java.util.Arrays.fill(pre_re, 0); java.util.Arrays.fill(pre_im, 0);
        for (int c = 0; c < n; c++) { pre_re[ch.bins[c]] = (float) zr[c]; pre_im[ch.bins[c]] = (float) zi[c]; }
        Fft.run(pre_re, pre_im, +1);
        int g = ch.bins[1] - ch.bins[0], span = Channel.N / g, best = 0;
        double bm = -1;
        for (int k = 0; k < span; k++) { double m = pre_re[k] * pre_re[k] + pre_im[k] * pre_im[k]; if (m > bm) { bm = m; best = k; } }
        // a delay of d samples turns carrier c by -2 pi bins[c] d / N; here d = -early
        int d0 = best <= span / 2 ? best : best - span;   // the window starts d0 samples early
        double th = -2 * Math.PI * g * d0 / Channel.N;
        // refine: across many carriers a small slope error adds up, so fit what is left (twice)
        for (int it = 0; it < 2; it++) {
            double mr = 0, mi = 0;
            for (int c = 0; c < n; c++) { double a = -th * c; mr += zr[c] * Math.cos(a) - zi[c] * Math.sin(a); mi += zr[c] * Math.sin(a) + zi[c] * Math.cos(a); }
            double m0 = Math.atan2(mi, mr), sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
            for (int c = 0; c < n; c++) {
                double a = -th * c - m0, r = zr[c] * Math.cos(a) - zi[c] * Math.sin(a), i = zr[c] * Math.sin(a) + zi[c] * Math.cos(a);
                double wgt = Math.hypot(r, i), ph = Math.atan2(i, r);
                sw += wgt; sx += wgt * c; sy += wgt * ph; sxx += wgt * c * c; sxy += wgt * c * ph;
            }
            double den = sw * sxx - sx * sx;
            if (Math.abs(den) > 1e-12) th += (sw * sxy - sx * sy) / den;
        }
        double early = -th * Channel.N / (2 * Math.PI * g);
        double sr = 0, si = 0, sa = 0;
        for (int c = 0; c < n; c++) {
            double a = -th * c, cr = Math.cos(a), ci = Math.sin(a);
            sr += zr[c] * cr - zi[c] * ci; si += zr[c] * ci + zi[c] * cr;
            sa += Math.hypot(zr[c], zi[c]);
        }
        return new double[]{early, Math.hypot(sr, si) / Math.max(1e-20, sa)};
    }

    private void symbol(long w) {
        float[][] y = fft(w);
        int n = ch.count();
        if (moved != 0) {
            // the window was just moved by m samples, which turned every carrier by 2 pi bin m / N: turn it back,
            // so that the comparison with the symbol before sees only the sound
            for (int c = 0; c < n; c++) {
                double a = -2 * Math.PI * ch.bins[c] * moved / Channel.N, co = Math.cos(a), si = Math.sin(a);
                float r = (float) (y[0][c] * co - y[1][c] * si), i = (float) (y[0][c] * si + y[1][c] * co);
                y[0][c] = r; y[1][c] = i;
            }
            moved = 0;
        }
        boolean head = s < 2 + hsym;
        boolean train = !head && type == Tx.TRAIN;
        int ts = s - 2 - hsym;
        double[] dr = new double[n], di = new double[n];
        for (int c = 0; c < n; c++) {
            dr[c] = y[0][c] * prevRe[c] + y[1][c] * prevIm[c];
            di[c] = y[1][c] * prevRe[c] - y[0][c] * prevIm[c];
            if (train) {                            // take out the known step
                double a = -Math.PI * 2 * Channel.trainStep(c, ts) / 4;
                double r = dr[c] * Math.cos(a) - di[c] * Math.sin(a), i = dr[c] * Math.sin(a) + di[c] * Math.cos(a);
                dr[c] = r; di[c] = i;
            }
        }
        prevRe = y[0]; prevIm = y[1];
        // pilots (in training, every carrier): a turn common to all, and one growing with frequency
        double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
        for (int c = 0; c < n; c++) {
            if (!train && !ch.pilot[c]) continue;
            double wgt = Math.hypot(dr[c], di[c]), a = Math.atan2(di[c], dr[c]), x = ch.bins[c];
            sw += wgt; sx += wgt * x; sy += wgt * a; sxx += wgt * x * x; sxy += wgt * x * a;
        }
        double den = sw * sxx - sx * sx, beta = Math.abs(den) > 1e-12 ? (sw * sxy - sx * sy) / den : 0;
        double alpha = sw > 0 ? (sy - beta * sx) / sw : 0;
        BitMap m = head ? std : cur;
        // decide every carrier, then fit the common turn again from all of them (decisions included),
        // which is far steadier than a few pilots alone, and decide again
        int[] idx = new int[n];
        for (int pass = 0; pass < 2; pass++) {
            double qw = 0, qx = 0, qy = 0, qxx = 0, qxy = 0;
            for (int c = 0; c < n; c++) {
                double a = wrap(Math.atan2(di[c], dr[c]) - alpha - beta * ch.bins[c]);
                int nb = train || ch.pilot[c] ? 0 : m.bits[c];
                if (!train && !ch.pilot[c] && nb == 0) continue;
                double e;
                if (nb > 0) {
                    int lv = 1 << nb;
                    double u = a / (2 * Math.PI) * lv;
                    int k = (int) Math.floor(u + 0.5);
                    e = (u - k) * 2 * Math.PI / lv;
                    idx[c] = ((k % lv) + lv) % lv;
                } else e = a;
                if (pass == 0) {
                    double wgt = Math.hypot(dr[c], di[c]), x = ch.bins[c];
                    qw += wgt; qx += wgt * x; qy += wgt * e; qxx += wgt * x * x; qxy += wgt * x * e;
                } else if (train) {
                    trainErr[0][c] += (float) (e * e);
                    trainErr[1][c] += 1;
                } else if (nb > 0) {
                    errSum += e * e; errN++;
                }
            }
            if (pass == 0) {
                double dd = qw * qxx - qx * qx;
                double b2 = Math.abs(dd) > 1e-12 ? (qw * qxy - qx * qy) / dd : 0;
                double a2 = qw > 0 ? (qy - b2 * qx) / qw : 0;
                alpha += a2; beta += b2;
                // follow the drift (from all carriers): a clock drifts by a small fraction of a sample per
                // symbol, so a larger reading is noise or a wrapped phase and is left out
                double dt = -beta * Channel.N / (2 * Math.PI);
                if (Math.abs(dt) < 1) tau += dt;
                if (Math.abs(tau) >= 3) { int mv = (int) Math.round(tau); adjust += mv; tau -= mv; moved = mv; if (DEBUG) System.err.printf("  symbol %d: window moved %d (total %d)%n", s, mv, adjust); }
            }
        }
        if (train) return;
        for (int c = 0; c < n; c++) {
            if (ch.pilot[c]) continue;
            int nb = m.bits[c];
            if (nb == 0) continue;
            int k = idx[c];
            bits.put(k ^ (k >> 1), nb);
        }
    }

    static double wrap(double a) { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; }

    static final class BitWriter {
        byte[] b = new byte[64]; int pos;
        void put(int v, int n) {
            for (int i = n - 1; i >= 0; i--) {
                if ((pos >> 3) >= b.length) b = java.util.Arrays.copyOf(b, b.length * 2);
                if (((v >> i) & 1) != 0) b[pos >> 3] |= (byte) (0x80 >> (pos & 7));
                pos++;
            }
        }
        byte[] bytes(int n) { return java.util.Arrays.copyOf(b, n); }
    }

    /** A second-order high-pass filter at the modem rate. */
    static final class Biquad {
        final float b0, b1, b2, a1, a2; float x1, x2, y1, y2;
        Biquad(double b0, double b1, double b2, double a0, double a1, double a2) {
            this.b0 = (float) (b0 / a0); this.b1 = (float) (b1 / a0); this.b2 = (float) (b2 / a0); this.a1 = (float) (a1 / a0); this.a2 = (float) (a2 / a0);
        }
        static Biquad highpass(double hz, double q) {
            double w = 2 * Math.PI * hz / Channel.RATE, al = Math.sin(w) / (2 * q), c = Math.cos(w);
            return new Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
        }
        float run(float x) {
            float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
    }
}
