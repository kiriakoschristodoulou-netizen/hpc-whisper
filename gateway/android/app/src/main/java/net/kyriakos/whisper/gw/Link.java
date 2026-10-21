package net.kyriakos.whisper.gw;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import net.kyriakos.whisper.gw.NetCodec.Frame;

/**
 * The byte-stream link of Whisper Net (NET-PROTOCOL.md section 3), no sound in
 * it: bytes written are sent in turns, from the last acknowledged byte on, and
 * the bytes of the other side arrive in order, once.
 */
public final class Link {
    public static final int MAXFR = 3, CAP = 8192;

    public interface Listener {
        /** Bytes of the other side's stream, in order. */
        void onData(byte[] b, int off, int len);
        /** The other side started anew: forget every connection. */
        void onPeerReset();
    }

    private final Listener l;
    private final Random rnd;
    private final byte[] buf = new byte[CAP];
    private int start, base, count;          // buf[0..count) = stream bytes base ...
    private boolean acked;                    // anything of this stream acknowledged
    private int next;                         // next offset expected from the other side
    private boolean havePeer;

    public Link(Listener l, Random rnd) {
        this.l = l; this.rnd = rnd;
        restart();
    }

    private void restart() {
        do { start = rnd.nextInt(65536); } while (start == 0);
        base = start; count = 0; acked = false;
    }

    private static int d16(int a, int b) { return (short) (a - b); }

    public int free() { return CAP - count; }
    public int pending() { return count; }
    public boolean peerKnown() { return havePeer; }

    /** Queue bytes; false (nothing taken) if they do not all fit. */
    public boolean write(byte[] b, int off, int len) {
        if (len > free()) return false;
        System.arraycopy(b, off, buf, count, len);
        count += len;
        return true;
    }

    /** The frames of this side's turn: from base, at most MAXFR; the last has TURN. */
    public List<Frame> turn() {
        List<Frame> out = new ArrayList<>();
        int sent = 0;
        do {
            Frame f = new Frame();
            int n = Math.min(NetCodec.MAXLEN, count - sent);
            f.n = n; f.off = (base + sent) & 0xFFFF;
            f.ack = havePeer ? next & 0xFFFF : 0;
            f.data = new byte[n];
            System.arraycopy(buf, sent, f.data, 0, n);
            if (f.off == start && !acked) f.flags |= NetCodec.FL_SYNC;
            sent += n;
            out.add(f);
        } while (sent < count && out.size() < MAXFR);
        out.get(out.size() - 1).flags |= NetCodec.FL_TURN;
        return out;
    }

    /** A frame heard. */
    public void receive(Frame f) {
        int ack = f.ack;
        if ((f.flags & NetCodec.FL_SYNC) != 0) {
            boolean restart = !havePeer || d16(f.off, next) < -170 || d16(f.off, next) > 110;
            if (restart) {
                havePeer = true; next = f.off;
                l.onPeerReset();
                if (acked) { restart(); ack = 0; }
            }
        } else if (!havePeer) return;
        // acknowledgement
        int adv = d16(ack, base);
        if (ack != 0 && adv > 0 && adv <= count) {
            System.arraycopy(buf, adv, buf, 0, count - adv);
            count -= adv; base = ack & 0xFFFF; acked = true;
        }
        // data
        int skip = d16(next, f.off);
        if (skip >= 0 && skip < f.n) {
            l.onData(f.data, skip, f.n - skip);
            next = (f.off + f.n) & 0xFFFF;
        }
    }
}
