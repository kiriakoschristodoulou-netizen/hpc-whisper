package net.kyriakos.whisper;

/**
 * The return channel (docs/FORMAT.md): after a piece of text arrives the phone says, silently
 * (19.0 to 20.5 kHz), how much of the handheld's page it holds. The handheld then stops sending
 * what is already here and sends what is missing. Same symbols as modem.js ackSymbols.
 */
public final class Ack {
    private Ack() { }

    public static final int BAND = 19000, TYPE = 1, STEP = 100, MAX_GAP = 15;
    public static final double SYMBOL_S = 0.032;

    /** What the phone holds: P bytes from the start of the page without a gap, and G bytes missing right after them (0 to 15). */
    public static final class State {
        public int doc, p, g, hash;
    }

    /** The 12 bit check over the page number, P, G and the first P bytes (handheld: AckHash). */
    public static int hash(int doc, int p, int g, byte[] bytes) {
        int[] all = new int[4 + p];
        all[0] = doc & 255; all[1] = (p >> 8) & 255; all[2] = p & 255; all[3] = g & 15;
        for (int i = 0; i < p; i++) all[4 + i] = bytes[i] & 255;
        return Receiver.crc16(all, all.length) & 0xFFF;
    }

    /** Null while the phone holds nothing of the page yet. Bytes given up on do not count as held. */
    public static State of(Mirror m) {
        if (m.doc < 0 || m.L <= 0) return null;
        int p = 0;
        while (p < m.L && m.known[p]) p++;
        int g = 0;
        if (p < m.L) {
            int i = p;
            while (i < m.L && !m.known[i] && g < MAX_GAP) { i++; g++; }
        }
        State s = new State();
        s.doc = m.doc; s.p = p; s.g = g;
        s.hash = hash(m.doc, p, g, m.bytes);
        return s;
    }

    public static int[] symbols(int doc, int p, int g, int hash) {
        int[] w = Receiver.rsEncode(new int[]{TYPE, (doc >> 4) & 15, doc & 15, (p >> 12) & 15, (p >> 8) & 15, (p >> 4) & 15, p & 15,
                g & 15, (hash >> 8) & 15, (hash >> 4) & 15, hash & 15});
        int[] out = new int[Receiver.PREAMBLE.length + w.length];
        System.arraycopy(Receiver.PREAMBLE, 0, out, 0, Receiver.PREAMBLE.length);
        System.arraycopy(w, 0, out, Receiver.PREAMBLE.length, w.length);
        return out;
    }

    /** Tones, phase continuous, soft ends, as modem.js synth (20 ms of quiet before and after). */
    public static short[] pcm(int[] sym, int rate, double amp) {
        int n0 = (int) Math.round(rate * 0.02);
        int nSym = (int) Math.round(sym.length * SYMBOL_S * rate);
        short[] out = new short[nSym + 2 * n0];
        double ph = 0;
        int fade = (int) Math.round(rate * 0.005);
        for (int i = 0; i < nSym; i++) {
            int k = Math.min(sym.length - 1, (int) Math.floor(i / (SYMBOL_S * rate)));
            ph += 2 * Math.PI * (BAND + sym[k] * STEP) / rate;
            double e = 1;
            if (i < fade) e = (double) i / fade; else if (i > nSym - fade) e = (double) (nSym - i) / fade;
            out[n0 + i] = (short) Math.round(32767 * amp * e * Math.sin(ph));
        }
        return out;
    }
}
