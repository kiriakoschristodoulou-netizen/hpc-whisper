package net.kyriakos.whisper.w3;

/** Makes frames at the modem rate, 51,200 samples per second (docs/FORMAT3.md). */
public final class Tx {
    public static final int TRAIN = 0x30, TRAIN_SYMBOLS = 24;

    /** Gray value -> phase step index. */
    static int grayIndex(int g) { return g ^ (g >> 1) ^ (g >> 2); }

    /** A whole frame, peak at the given level (0..1). */
    public static float[] frame(Channel ch, BitMap map, int type, byte[] msg, float level) {
        BitMap std = BitMap.standard(ch);
        byte[] hdr = Codec.header(type, msg.length, map.number);
        byte[] body = type != TRAIN ? Codec.encode(msg) : new byte[0];
        Channel.scramble(hdr); Channel.scramble(body);          // so that no data lines the phases up
        int hb = std.bitsPerSymbol(), pb = map.bitsPerSymbol();
        int hsym = (hdr.length * 8 + hb - 1) / hb;
        int psym = type == TRAIN ? TRAIN_SYMBOLS : (body.length * 8 + pb - 1) / pb;
        int nsym = 2 + hsym + psym;
        int n = ch.count();
        int[][] steps = new int[nsym][n];          // phase steps in eighths of a turn; -1 = carrier off
        int[] ph = new int[n];
        // S and R: fixed phases (absolute, not steps)
        int[][] abs = new int[2][n];
        for (int c = 0; c < n; c++) {
            abs[0][c] = (ch.bins[c] % ch.syncStep() == 0) ? 2 * Channel.sPhase(c) : -1;
            abs[1][c] = 2 * Channel.rPhase(c);
        }
        BitReader hr = new BitReader(hdr), pr = new BitReader(body);
        for (int s = 2; s < nsym; s++) {
            boolean head = s < 2 + hsym;
            BitMap m = head ? std : map;
            BitReader r = head ? hr : pr;
            for (int c = 0; c < n; c++) {
                if (ch.pilot[c]) { steps[s][c] = 0; continue; }
                if (!head && type == TRAIN) { steps[s][c] = 2 * Channel.trainStep(c, s - 2 - hsym); continue; }
                int nb = m.bits[c];
                if (nb == 0) { steps[s][c] = -1; continue; }
                steps[s][c] = grayIndex(r.take(nb)) * (8 >> nb);
            }
            if (!head && type == TRAIN) for (int c = 0; c < n; c++) if (ch.pilot[c]) steps[s][c] = 2 * Channel.trainStep(c, s - 2 - hsym);
        }
        // the sound
        int N = Channel.N, CP = Channel.CP, SYM = Channel.SYM, F = Channel.FADE;
        float[] out = new float[nsym * SYM + F];
        float[] re = new float[N], im = new float[N];
        for (int s = 0; s < nsym; s++) {
            java.util.Arrays.fill(re, 0); java.util.Arrays.fill(im, 0);
            for (int c = 0; c < n; c++) {
                int p;
                if (s < 2) { if (abs[s][c] < 0) continue; p = abs[s][c]; if (s == 1) ph[c] = p; }
                else { if (steps[s][c] < 0) continue; ph[c] = (ph[c] + steps[s][c]) & 7; p = ph[c]; }
                double a = Math.PI * p / 4, amp = s == 0 ? 1.41421356 : 1;        // S uses half the carriers: as much power as the others
                re[ch.bins[c]] = (float) (amp * Math.cos(a)); im[ch.bins[c]] = (float) (amp * Math.sin(a));
            }
            Fft.run(re, im, +1);
            int base = s * SYM + CP;
            for (int k = -CP; k < N + F; k++) {
                float w = 1;
                if (k < -CP + F) w = (float) (0.5 - 0.5 * Math.cos(Math.PI * (k + CP) / F));
                else if (k >= N) w = (float) (0.5 + 0.5 * Math.cos(Math.PI * (k - N) / F));
                out[base + k] += re[((k % N) + N) % N] * w;
            }
        }
        // level: RMS a third of the peak, then clip at the peak
        double e = 0;
        int from = 2 * SYM;
        for (int i = from; i < out.length; i++) e += out[i] * out[i];
        float g = (float) (level / 3 / Math.sqrt(e / Math.max(1, out.length - from) + 1e-20));
        for (int i = 0; i < out.length; i++) { float v = out[i] * g; out[i] = v > level ? level : v < -level ? -level : v; }
        return out;
    }

    public static float[] train(Channel ch, float level) { return frame(ch, BitMap.standard(ch), TRAIN, new byte[0], level); }

    static final class BitReader {
        final byte[] b; int pos;
        BitReader(byte[] b) { this.b = b; }
        int take(int n) {
            int v = 0;
            for (int i = 0; i < n; i++) {
                int bit = pos < b.length * 8 ? (b[pos >> 3] >> (7 - (pos & 7))) & 1 : 0;
                v = (v << 1) | bit; pos++;
            }
            return v;
        }
    }
}
