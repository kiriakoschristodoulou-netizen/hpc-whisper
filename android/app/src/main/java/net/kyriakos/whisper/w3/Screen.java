package net.kyriakos.whisper.w3;

import java.io.ByteArrayOutputStream;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

/**
 * The picture remote's screen (docs/FORMAT3.md, SCREEN): a picture of up to
 * 640 x 240 pixels in 16 greys, cut into 16 x 16 tiles. Only tiles that
 * differ from what the handheld already has are sent, top rows first, in
 * SCREEN messages of at most about 1,600 bytes. A tile not refreshed for a
 * while is sent again when nothing else is waiting (a lost message heals).
 * Plain Java (tested on a computer).
 */
public final class Screen {
    public static final int T = 16, TILE_BYTES = T * T / 2, MAX_W = 640, MAX_H = 240;
    public static final int MSG_LIMIT = 1600;
    public static final long REFRESH_MS = 20000;

    public int w, h, tw, th;                        // picture size, in pixels and tiles
    private byte[] sent;                            // what the handheld has (4-bit greys, one per byte)
    private byte[] cur;
    private long[] sentAt;
    private boolean[] dirty;
    private int update = 0;
    private boolean sizeChanged = true;

    /** A new picture (greys 0..15, one per byte, w x h). */
    public void set(byte[] grey, int w, int h, long now) {
        w = Math.min(w, MAX_W); h = Math.min(h, MAX_H);
        if (w != this.w || h != this.h || cur == null) {
            this.w = w; this.h = h; tw = (w + T - 1) / T; th = (h + T - 1) / T;
            sent = new byte[tw * T * th * T]; java.util.Arrays.fill(sent, (byte) -1);
            cur = new byte[sent.length]; java.util.Arrays.fill(cur, (byte) 15); sentAt = new long[tw * th]; dirty = new boolean[tw * th];
            sizeChanged = true;
        }
        int W = tw * T;
        for (int y = 0; y < h; y++) System.arraycopy(grey, y * w, cur, y * W, w);
        for (int ty = 0; ty < th; ty++)
            for (int tx = 0; tx < tw; tx++) {
                boolean d = false;
                for (int y = ty * T; y < ty * T + T && !d; y++) {
                    int o = y * W + tx * T;
                    for (int x = 0; x < T; x++) if (cur[o + x] != sent[o + x]) { d = true; break; }
                }
                dirty[ty * tw + tx] = d;
            }
    }

    /** Everything again (the handheld asked for a refresh, or a new view). */
    public void resendAll() { if (sent != null) java.util.Arrays.fill(sent, (byte) -1); if (dirty != null) java.util.Arrays.fill(dirty, true); sizeChanged = true; }

    public int dirtyTiles() { int n = 0; if (dirty != null) for (boolean b : dirty) if (b) n++; return n; }

    /** The next SCREEN message, or null when the handheld has the picture. Stale tiles are refreshed when idle is true. */
    public byte[] next(long now, boolean idle) {
        if (cur == null) return null;
        int W = tw * T;
        ByteArrayOutputStream raw = new ByteArrayOutputStream();
        byte[] packed = null;
        int count = 0;
        int[] order = new int[tw * th];
        int n = 0;
        for (int i = 0; i < tw * th; i++) if (dirty[i]) order[n++] = i;
        if (n == 0 && idle) {
            // the tile sent longest ago, if it is old
            int best = -1;
            for (int i = 0; i < tw * th; i++) if (now - sentAt[i] > REFRESH_MS && (best < 0 || sentAt[i] < sentAt[best])) best = i;
            if (best >= 0) {
                for (int i = 0; i < tw * th && n < 24; i++) { int k = (best + i) % (tw * th); if (now - sentAt[k] > REFRESH_MS) order[n++] = k; }
            }
        }
        if (n == 0) return null;
        byte[] lastGood = null;
        int taken = 0;
        for (int j = 0; j < n; j++) {
            int i = order[j], tx = i % tw, ty = i / tw;
            raw.write(tx); raw.write(ty);
            for (int y = ty * T; y < ty * T + T; y++) {
                int o = y * W + tx * T;
                for (int x = 0; x < T; x += 2) raw.write((cur[o + x] & 15) << 4 | (cur[o + x + 1] & 15));
            }
            count++;
            if (count % 4 == 0 || j == n - 1) {
                byte[] z = pack(raw.toByteArray());
                if (z.length + 3 > MSG_LIMIT && lastGood != null) break;
                lastGood = z; taken = count;
                if (z.length + 3 > MSG_LIMIT) break;
            }
        }
        // mark what goes
        for (int j = 0; j < taken; j++) {
            int i = order[j], tx = i % tw, ty = i / tw;
            for (int y = ty * T; y < ty * T + T; y++) System.arraycopy(cur, y * W + tx * T, sent, y * W + tx * T, T);
            dirty[i] = false; sentAt[i] = now;
        }
        boolean last = dirtyTiles() == 0;
        int flags = (last ? 1 : 0) | (sizeChanged ? 2 : 0);
        sizeChanged = false;
        byte[] m = new byte[3 + lastGood.length];
        m[0] = (byte) (update >> 8); m[1] = (byte) update; m[2] = (byte) flags;
        System.arraycopy(lastGood, 0, m, 3, lastGood.length);
        if (last) update = (update + 1) & 0xFFFF;
        return m;
    }

    private byte[] pack(byte[] records) {
        byte[] r = java.util.Arrays.copyOf(records, records.length + 3);
        r[records.length] = (byte) 255; r[records.length + 1] = (byte) tw; r[records.length + 2] = (byte) th;
        Deflater d = new Deflater(9);
        d.setInput(r); d.finish();
        byte[] out = new byte[r.length + 64];
        int k = d.deflate(out);
        d.end();
        return java.util.Arrays.copyOf(out, k);
    }

    /** Decodes a SCREEN message into a picture (tests; the handheld does this in Pascal). Returns {tw, th} or null. */
    public static int[] apply(byte[] msg, byte[] pic, int picW) {
        try {
            Inflater f = new Inflater();
            f.setInput(msg, 3, msg.length - 3);
            byte[] buf = new byte[70000];
            int n = f.inflate(buf);
            f.end();
            int i = 0;
            while (i + 1 < n) {
                int tx = buf[i] & 255, ty = buf[i + 1] & 255;
                if (tx == 255) return new int[]{ty, buf[i + 2] & 255};
                i += 2;
                for (int y = 0; y < T; y++)
                    for (int x = 0; x < T; x += 2) {
                        int b = buf[i++] & 255, o = (ty * T + y) * picW + tx * T + x;
                        pic[o] = (byte) (b >> 4); pic[o + 1] = (byte) (b & 15);
                    }
            }
        } catch (Exception e) { return null; }
        return null;
    }
}
