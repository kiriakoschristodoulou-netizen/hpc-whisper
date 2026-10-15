package net.kyriakos.whisper.w3;

import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;

/**
 * Sends one file in numbered packets (docs/FORMAT3.md, section 6): an offer,
 * then 16 packets at a time; after each batch it waits up to 1.5 s for the
 * receiver's FILE_NEED, and sends again what it lists. Plain Java (tested on
 * a computer); the same logic is in handheld/wfile.pas.
 *
 * Call next(now) whenever the sender's channel is free: it returns the next
 * message to send ({type, payload...} as a Msg), or null to wait.
 */
public final class FileSend {
    public static final int PACKET = 1024, BATCH = 16;
    public static final long WAIT_MS = 1500;
    public static final int MAX_POLLS = 6;
    public static final int T_OFFER = 0x10, T_DATA = 0x11, T_NEED = 0x12, T_CANCEL = 0x13;

    public static final class Msg {
        public final int type; public final byte[] payload;
        Msg(int type, byte[] payload) { this.type = type; this.payload = payload; }
    }

    public final int id, kind;
    public final String name;
    public final byte[] data;
    public final int packets;
    private final boolean[] confirmed;
    private final ArrayDeque<Integer> again = new ArrayDeque<>();
    private int nextNew = 0, inBatch = 0;
    private boolean offerDue = true;
    private long waitUntil = -1;          // waiting for FILE_NEED until then
    private int polls = 0;
    private boolean offerSentThisBatch = false;
    private boolean everHeard = false, blindRepeatDone = false;
    public boolean done, failed, confirmedAll;
    public int sentPackets = 0;

    public FileSend(int id, String name, int kind, byte[] data) {
        this.id = id & 0xFFFF; this.name = name; this.kind = kind; this.data = data;
        packets = Math.max(1, (data.length + PACKET - 1) / PACKET);
        confirmed = new boolean[packets];
    }

    public int confirmedCount() { int n = 0; for (boolean b : confirmed) if (b) n++; return n; }
    /** 0..1: how far it is (packets confirmed, or sent when nothing is confirmed). */
    public float progress() {
        if (done) return 1;
        return everHeard ? confirmedCount() / (float) packets : Math.min(nextNew, packets) / (float) packets;
    }

    public byte[] offer() {
        byte[] n = name.getBytes(StandardCharsets.UTF_8);
        int nl = Math.min(n.length, 200);
        byte[] p = new byte[9 + nl];
        p[0] = (byte) (id >> 8); p[1] = (byte) id;
        p[2] = (byte) (data.length >> 24); p[3] = (byte) (data.length >> 16); p[4] = (byte) (data.length >> 8); p[5] = (byte) data.length;
        p[6] = (byte) (packets >> 8); p[7] = (byte) packets; p[8] = (byte) kind;
        System.arraycopy(n, 0, p, 9, nl);
        return p;
    }

    private byte[] packet(int k) {
        int a = k * PACKET, n = Math.min(PACKET, data.length - a);
        if (n < 0) n = 0;
        byte[] p = new byte[4 + n];
        p[0] = (byte) (id >> 8); p[1] = (byte) id; p[2] = (byte) (k >> 8); p[3] = (byte) k;
        System.arraycopy(data, a, p, 4, n);
        return p;
    }

    public Msg next(long now) {
        if (done || failed) return null;
        if (waitUntil >= 0) {
            if (now < waitUntil) return null;
            waitUntil = -1;
            // no answer
            if (!everHeard) {
                if (nextNew >= packets) {
                    // nobody answers at all: everything once more, then finished (unconfirmed)
                    if (!blindRepeatDone) { blindRepeatDone = true; for (int k = 0; k < packets; k++) again.add(k); }
                    else { done = true; return null; }
                }
            } else {
                if (++polls > MAX_POLLS) { failed = true; return null; }
                offerDue = true;            // the offer asks "what do you still need?"
            }
        }
        // while nothing has been heard back, every batch starts with the offer (it may have been lost)
        if (inBatch == 0 && !everHeard && nextNew > 0 && !offerSentThisBatch) offerDue = true;
        if (offerDue) {
            offerSentThisBatch = true;
            offerDue = false;
            if (inBatch == 0 && everHeard && nextNew > 0) waitUntil = now + WAIT_MS;   // a poll: wait for the answer
            return new Msg(T_OFFER, offer());
        }
        // a batch: what was asked for again first, then new packets
        while (inBatch < BATCH) {
            Integer k = again.poll();
            if (k == null) {
                if (nextNew >= packets) break;
                k = nextNew++;
            } else if (confirmed[k]) continue;
            inBatch++;
            sentPackets++;
            return new Msg(T_DATA, packet(k));
        }
        // the batch is out (or nothing left to send): wait for FILE_NEED
        inBatch = 0;
        offerSentThisBatch = false;
        waitUntil = now + WAIT_MS;
        return null;
    }

    /** FILE_NEED from the receiver. */
    public void onNeed(byte[] p, long now) {
        if (p.length < 3 || ((p[0] & 255) << 8 | (p[1] & 255)) != id) return;
        everHeard = true;
        polls = 0;
        int flags = p[2] & 255;
        if ((flags & 1) != 0) {
            for (int k = 0; k < packets; k++) confirmed[k] = true;
            done = true; confirmedAll = true; return;
        }
        if ((flags & 2) != 0) offerDue = true;
        // it holds every packet below "have" except those it lists (the first 32 missing)
        if (p.length < 5) return;
        int have = (p[3] & 255) << 8 | (p[4] & 255);
        int listed = (p.length - 5) / 2;
        boolean[] missing = new boolean[packets];
        int last = -1;
        for (int i = 5; i + 1 < p.length; i += 2) {
            int k = (p[i] & 255) << 8 | (p[i + 1] & 255);
            if (k < packets) { missing[k] = true; last = k; }
        }
        boolean full = listed >= 32;
        int sure = full ? last + 1 : Math.min(have, packets);     // below this, what is not listed is held
        for (int k = 0; k < sure; k++) if (!missing[k]) confirmed[k] = true;
        again.clear();
        for (int k = 0; k < packets; k++) if (missing[k] && !confirmed[k]) again.add(k);
        // sent but beyond what it has seen: lost at the end of the batch
        if (!full) for (int k = have; k < Math.min(nextNew, packets); k++) if (!confirmed[k]) again.add(k);
        if (confirmedCount() == packets) { done = true; confirmedAll = true; }
        waitUntil = -1;
        inBatch = 0;
    }

    public byte[] cancel() { return new byte[]{(byte) (id >> 8), (byte) id}; }
}
