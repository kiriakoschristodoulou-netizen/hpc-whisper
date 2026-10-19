package net.kyriakos.whisper;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * The phone's copy of the handheld's document (as modem.js Mirror): each frame
 * says "the document is L bytes long, and from o it reads ...". Missing bytes
 * are known to be missing, and fill in when a repeat arrives. Also notes when
 * each byte first arrived, so the keyboard can decide what has settled.
 */
public final class Mirror {
    public int doc = -1, L = 0;
    public byte[] bytes = new byte[1024];
    public boolean[] known = new boolean[1024];
    public long[] since = new long[1024];
    /** Bytes given up on (a gap that did not fill in time): treated as nothing, so the text after them can go on. */
    public boolean[] skipped = new boolean[1024];

    private void grow(int need) {
        if (need <= bytes.length) return;
        int m = bytes.length;
        while (m < need) m *= 2;
        bytes = Arrays.copyOf(bytes, m); known = Arrays.copyOf(known, m); since = Arrays.copyOf(since, m); skipped = Arrays.copyOf(skipped, m);
    }

    /** True when the handheld started a new document (everything before is finished). */
    public boolean apply(Receiver.Frame f, long now) {
        boolean fresh = false;
        if (f.doc != doc) { doc = f.doc; L = 0; Arrays.fill(known, false); Arrays.fill(skipped, false); fresh = true; }
        grow(Math.max(f.L, f.o + f.bytes.length));
        if (f.L < L) { Arrays.fill(known, f.L, L, false); Arrays.fill(skipped, f.L, L, false); }
        L = f.L;
        for (int i = 0; i < f.bytes.length; i++) {
            int at = f.o + i;
            if (at >= f.L) break;
            if (!known[at] || bytes[at] != f.bytes[i]) since[at] = now;
            bytes[at] = f.bytes[i];
            known[at] = true;
            skipped[at] = false;
        }
        return fresh;
    }

    public int firstUnknown(int from) {
        for (int i = from; i < L; i++) if (!known[i] && !skipped[i]) return i;
        return L;
    }

    /** True when bytes from..to are all given up or known (nothing still to wait for). */
    public boolean complete(int from, int to) { return firstUnknown(from) >= to; }

    /** Gives up on the missing bytes from a (up to the next byte that is known). Returns where the gap ends. */
    public int skipGap(int a) {
        int i = a;
        while (i < L && !known[i]) { skipped[i] = true; i++; }
        return i;
    }

    /** Text of [a, b); a run of missing bytes shows as gapMark (bytes given up on show as nothing). */
    public String text(int a, int b, String gapMark) {
        StringBuilder out = new StringBuilder();
        int i = a;
        while (i < b) {
            if (skipped[i] && !known[i]) { i++; continue; }
            if (!known[i]) { int j = i; while (j < b && !known[j] && !skipped[j]) j++; out.append(gapMark); i = j; continue; }
            int j = i; while (j < b && known[j]) j++;
            String part = new String(bytes, i, j - i, StandardCharsets.UTF_8);
            if (part.indexOf('\uFFFD') >= 0) part = part.replace("\uFFFD", "");     // a character cut by a gap
            out.append(part);
            i = j;
        }
        return out.toString();
    }
}
