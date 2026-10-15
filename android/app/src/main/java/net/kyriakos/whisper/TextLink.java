package net.kyriakos.whisper;

/**
 * Format 3 text on the phone's side: turns TEXT messages into frames for the
 * keyboard, and tells the handheld what has arrived (TEXT_ACK), once the
 * handheld has been quiet for a moment, so that the answer does not talk
 * over it. Plain Java (tested on a computer).
 */
public final class TextLink {
    // the handheld takes turns: after it plays, it needs a moment to open its microphone again
    static final long QUIET_MS = 450, MIN_GAP_MS = 600;

    public final Mirror mirror = new Mirror();
    private boolean due;
    private long lastText = -1, lastAck = -1;

    /** A TEXT payload: doc id, seq, L (2), o (2), bytes. Returns the frame, or null when malformed. */
    public Receiver.Frame onText(byte[] p, long nowMs) {
        if (p.length < 6) return null;
        Receiver.Frame f = new Receiver.Frame();
        f.doc = p[0] & 255; f.seq = p[1] & 255;
        f.L = ((p[2] & 255) << 8) | (p[3] & 255);
        f.o = ((p[4] & 255) << 8) | (p[5] & 255);
        f.bytes = new byte[p.length - 6];
        System.arraycopy(p, 6, f.bytes, 0, f.bytes.length);
        f.ms = 0; f.bandHz = 0;
        mirror.apply(f, nowMs);
        due = true;
        lastText = nowMs;
        return f;
    }

    /** The TEXT_ACK payload to send now, or null: doc id, known (2), L (2). */
    public byte[] ackIfDue(long nowMs) {
        if (!due || nowMs - lastText < QUIET_MS) return null;
        if (lastAck >= 0 && nowMs - lastAck < MIN_GAP_MS) return null;
        due = false;
        lastAck = nowMs;
        int known = mirror.firstUnknown(0), L = mirror.L;
        return new byte[]{(byte) mirror.doc, (byte) (known >> 8), (byte) known, (byte) (L >> 8), (byte) L};
    }

    /** When to look again for an answer to send (ms from now), or -1. */
    public long nextCheck(long nowMs) {
        if (!due) return -1;
        long a = lastText + QUIET_MS - nowMs, b = lastAck < 0 ? 0 : lastAck + MIN_GAP_MS - nowMs;
        return Math.max(10, Math.max(a, b));
    }

    /** Something else was heard from the handheld: wait for quiet again before answering. */
    public void heard(long nowMs) { if (due) lastText = Math.max(lastText, nowMs); }
}
