package net.kyriakos.whisper.w3;

/** How many bits each carrier of a channel carries (0 = off; pilots are always on and carry none). */
public final class BitMap {
    public final Channel ch;
    public final int number;           // 0 = the default map
    public final byte[] bits;

    public BitMap(Channel ch, int number, byte[] bits) { this.ch = ch; this.number = number; this.bits = bits; }

    public static BitMap standard(Channel ch) {
        byte[] b = new byte[ch.count()];
        for (int c = 0; c < b.length; c++) b[c] = (byte) (ch.pilot[c] ? 0 : ch.defaultBits);
        return new BitMap(ch, 0, b);
    }

    public int bitsPerSymbol() { int t = 0; for (int c = 0; c < bits.length; c++) if (!ch.pilot[c]) t += bits[c]; return t; }

    /** The map from measured phase signal-to-noise ratios (dB) per carrier (FORMAT3.md, TRAIN). */
    public static BitMap fromSnr(Channel ch, int number, float[] snrDb) {
        byte[] b = new byte[ch.count()];
        for (int c = 0; c < b.length; c++) {
            if (ch.pilot[c]) continue;
            float s = snrDb[c];
            b[c] = (byte) (s >= 23 ? 3 : s >= 16 ? 2 : s >= 10 ? 1 : 0);
        }
        return new BitMap(ch, number, b);
    }

    /** MAP message payload: channel, number, carriers, then 2 bits per carrier. */
    public byte[] toMessage() {
        int n = bits.length;
        byte[] m = new byte[3 + (n + 3) / 4];
        m[0] = (byte) ch.id; m[1] = (byte) number; m[2] = (byte) n;
        for (int c = 0; c < n; c++) m[3 + c / 4] |= (byte) ((bits[c] & 3) << (6 - 2 * (c % 4)));
        return m;
    }

    public static BitMap fromMessage(byte[] m) {
        if (m.length < 3 || (m[0] & 255) >= Channel.COUNT) return null;
        Channel ch = Channel.get(m[0]);
        int n = m[2] & 255;
        if (n != ch.count() || m.length < 3 + (n + 3) / 4) return null;
        byte[] b = new byte[n];
        for (int c = 0; c < n; c++) b[c] = ch.pilot[c] ? 0 : (byte) ((m[3 + c / 4] >> (6 - 2 * (c % 4))) & 3);
        return new BitMap(ch, m[1] & 31, b);
    }
}
