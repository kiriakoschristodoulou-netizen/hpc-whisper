package net.kyriakos.whisper.w3;

/** Header and payload coding (docs/FORMAT3.md, section 2). */
public final class Codec {
    public static final int HEADER = 3, HEADER_CHECK = 6, MAXLEN = 2047;

    public static int crc16(byte[] b, int off, int n) {
        int c = 0xFFFF;
        for (int i = 0; i < n; i++) {
            c ^= (b[off + i] & 255) << 8;
            for (int k = 0; k < 8; k++) c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
        }
        return c;
    }

    public static byte[] header(int type, int len, int map) {
        byte[] h = new byte[HEADER + HEADER_CHECK];
        h[0] = (byte) type; h[1] = (byte) len; h[2] = (byte) (((len >> 8) & 7) | (map << 3));
        Rs.encode(h, 0, HEADER, HEADER_CHECK, h, HEADER);
        return h;
    }

    /** {type, length, map}, or null. */
    public static int[] readHeader(byte[] h) {
        byte[] c = h.clone();
        if (Rs.decode(c, 0, HEADER + HEADER_CHECK, HEADER_CHECK) < 0) return null;
        int len = (c[1] & 255) | ((c[2] & 7) << 8);
        return new int[]{c[0] & 255, len, (c[2] & 255) >> 3};
    }

    static int blocks(int n) { return (n + 222) / 223; }
    static int check(int k) { return Math.min(32, Math.max(8, 2 * ((k + 7) / 8))); }

    private static int[] sizes(int n) {
        int B = blocks(n);
        int[] k = new int[B];
        for (int b = 0; b < B; b++) k[b] = n / B + (b < n % B ? 1 : 0);
        return k;
    }

    public static int codedLength(int msgLen) {
        int[] k = sizes(msgLen + 2);
        int t = 0;
        for (int x : k) t += x + check(x);
        return t;
    }

    public static byte[] encode(byte[] msg) {
        int n = msg.length + 2;
        byte[] all = new byte[n];
        System.arraycopy(msg, 0, all, 0, msg.length);
        int c = crc16(msg, 0, msg.length);
        all[n - 2] = (byte) (c >> 8); all[n - 1] = (byte) c;
        int[] k = sizes(n);
        byte[][] cw = new byte[k.length][];
        int at = 0, longest = 0;
        for (int b = 0; b < k.length; b++) {
            int p = check(k[b]);
            cw[b] = new byte[k[b] + p];
            System.arraycopy(all, at, cw[b], 0, k[b]);
            Rs.encode(cw[b], 0, k[b], p, cw[b], k[b]);
            at += k[b];
            longest = Math.max(longest, cw[b].length);
        }
        byte[] out = new byte[codedLength(msg.length)];
        int o = 0;
        for (int j = 0; j < longest; j++) for (byte[] w : cw) if (j < w.length) out[o++] = w[j];
        return out;
    }

    /** The message, or null when it cannot be corrected or its check fails. fixed[0] gets the errors corrected. */
    public static byte[] decode(byte[] coded, int msgLen, int[] fixed) {
        int n = msgLen + 2;
        int[] k = sizes(n);
        byte[][] cw = new byte[k.length][];
        int longest = 0;
        for (int b = 0; b < k.length; b++) { cw[b] = new byte[k[b] + check(k[b])]; longest = Math.max(longest, cw[b].length); }
        int o = 0;
        for (int j = 0; j < longest; j++) for (byte[] w : cw) if (j < w.length) w[j] = coded[o++];
        byte[] all = new byte[n];
        int at = 0, f = 0;
        for (int b = 0; b < k.length; b++) {
            int r = Rs.decode(cw[b], 0, cw[b].length, check(k[b]));
            if (r < 0) return null;
            f += r;
            System.arraycopy(cw[b], 0, all, at, k[b]);
            at += k[b];
        }
        int c = crc16(all, 0, msgLen);
        if (((all[n - 2] & 255) << 8 | (all[n - 1] & 255)) != c) return null;
        if (fixed != null) fixed[0] = f;
        byte[] msg = new byte[msgLen];
        System.arraycopy(all, 0, msg, 0, msgLen);
        return msg;
    }
}
