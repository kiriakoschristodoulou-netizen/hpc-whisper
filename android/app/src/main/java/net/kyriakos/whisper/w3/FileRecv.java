package net.kyriakos.whisper.w3;

import java.nio.charset.StandardCharsets;

/**
 * Receives one file (docs/FORMAT3.md, section 6). After the sender goes
 * quiet (QUIET_MS without a packet), needDue() turns true and need() gives
 * the FILE_NEED answer: every packet held below "have", except the listed
 * missing ones. Plain Java (tested on a computer).
 */
public final class FileRecv {
    public static final long QUIET_MS = 250;
    /** How long without a packet before answering: when the answer is a frame of tones (2-3 s, the phone deaf while it sounds) the sender's gaps between packets (about 1.5 s) must not count as quiet. */
    public static final long QUIET_TONES_MS = 2200;
    public volatile long quietMs = QUIET_MS;

    public final int id, size, packets, kind;
    public final String name;
    private final byte[] data;
    private final boolean[] got;
    private int have = 0, count = 0;
    private long lastHeard;
    private boolean answered = true;
    public long started;

    private FileRecv(int id, int size, int packets, int kind, String name, long now) {
        this.id = id; this.size = size; this.packets = packets; this.kind = kind; this.name = name;
        data = new byte[size]; got = new boolean[packets];
        lastHeard = now; started = now; answered = false;
    }

    /** A new transfer from a FILE_OFFER, or null when malformed or too large. */
    public static FileRecv fromOffer(byte[] p, long now, int maxSize) {
        if (p.length < 9) return null;
        int id = (p[0] & 255) << 8 | (p[1] & 255);
        int size = (p[2] & 255) << 24 | (p[3] & 255) << 16 | (p[4] & 255) << 8 | (p[5] & 255);
        int packets = (p[6] & 255) << 8 | (p[7] & 255);
        if (size < 0 || size > maxSize || packets != Math.max(1, (size + FileSend.PACKET - 1) / FileSend.PACKET)) return null;
        String name = new String(p, 9, p.length - 9, StandardCharsets.UTF_8);
        return new FileRecv(id, size, packets, p[8] & 255, safeName(name), now);
    }

    public static int idOf(byte[] p) { return p.length >= 2 ? (p[0] & 255) << 8 | (p[1] & 255) : -1; }

    /** No folders, nothing odd: letters, digits and a few signs. */
    public static String safeName(String n) {
        StringBuilder o = new StringBuilder();
        for (int i = 0; i < n.length() && o.length() < 100; i++) {
            char c = n.charAt(i);
            if (Character.isLetterOrDigit(c) || c == ' ' || c == '-' || c == '_' || c == '.' || c == '(' || c == ')') o.append(c);
            else o.append('_');
        }
        String s = o.toString().trim();
        while (s.startsWith(".")) s = s.substring(1);
        return s.isEmpty() ? "file" : s;
    }

    public void onOffer(long now) { lastHeard = now; answered = false; }

    public void onData(byte[] p, long now) {
        if (p.length < 4 || idOf(p) != id) return;
        int k = (p[2] & 255) << 8 | (p[3] & 255);
        lastHeard = now; answered = false;
        if (k >= packets || got[k]) return;
        int a = k * FileSend.PACKET, n = Math.min(FileSend.PACKET, size - a);
        if (p.length - 4 != n) return;
        System.arraycopy(p, 4, data, a, n);
        got[k] = true; count++;
        have = Math.max(have, k + 1);
    }

    public boolean complete() { return count == packets; }
    public int received() { return count; }
    public byte[] data() { return data; }

    public boolean needDue(long now) { return !answered && now - lastHeard >= quietMs; }

    public byte[] need() {
        answered = true;
        boolean all = complete();
        int n = 0;
        int[] miss = new int[32];
        if (!all) for (int k = 0; k < have && n < 32; k++) if (!got[k]) miss[n++] = k;
        byte[] p = new byte[5 + 2 * n];
        p[0] = (byte) (id >> 8); p[1] = (byte) id; p[2] = (byte) (all ? 1 : 0);
        p[3] = (byte) (have >> 8); p[4] = (byte) have;
        for (int i = 0; i < n; i++) { p[5 + 2 * i] = (byte) (miss[i] >> 8); p[6 + 2 * i] = (byte) miss[i]; }
        return p;
    }

    /** FILE_NEED for a file whose offer was never heard: please send the offer again. */
    public static byte[] needOffer(int id) { return new byte[]{(byte) (id >> 8), (byte) id, 2, 0, 0}; }
}
