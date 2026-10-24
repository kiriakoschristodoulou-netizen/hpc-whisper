package net.kyriakos.whisper.gw;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import net.kyriakos.whisper.gw.NetCodec.Frame;

/**
 * The phone's side of a Whisper Net conversation (NET-PROTOCOL.md 3.4): hears
 * the handheld's turn, and answers it. Time is counted in the samples it is
 * given, so a test can run it faster than real time.
 */
public final class Session implements Link.Listener, NetRx.Listener {
    public interface Audio { void play(short[] pcm, int rate); }

    public static final class Settings {
        public int rate = 48000;
        public int upHz = 19000, downHz = 19000, symMs = 20;
        public double volume = 0.8;
        public int leadHz = 18700, leadMs = 700;
        public int replyDelayMs = 500, quietMs = 1200, afterMs = 150;
    }

    private final Settings st;
    private final Audio audio;
    private final Gateway gw;
    private final Link link;
    private final NetRx rx;
    /** Where to tell what happens (optional). */
    public java.util.function.Consumer<String> log;
    private void say(String m) { if (log != null) log.accept(m); }
    private boolean haveTurn;                 // a frame with TURN was heard
    private long turnEnd;                      // block (ms) where it ended
    private boolean heard;                     // frames heard since we last spoke
    private long turns, framesIn;
    public long framesHeard() { return framesIn; }
    public long turnsAnswered() { return turns; }
    public long lastHeardMs = -1;              // in the sample clock
    private final float[] zeros = new float[4800];

    public Session(Settings st, Audio audio, Gateway gw, Random rnd) {
        this.st = st; this.audio = audio; this.gw = gw;
        link = new Link(this, rnd);
        rx = new NetRx(st.rate, st.upHz, st.symMs, this);
    }

    public Link link() { return link; }
    public Gateway gateway() { return gw; }
    public NetRx rx() { return rx; }

    // Link.Listener
    public void onData(byte[] b, int off, int len) { gw.feed(b, off, len); }
    public void onPeerReset() { gw.reset(); say("the handheld started a new session"); }

    // NetRx.Listener
    public void onFrame(Frame f) {
        framesIn++; heard = true; lastHeardMs = rx.n;
        link.receive(f);
        if ((f.flags & NetCodec.FL_TURN) != 0) { haveTurn = true; turnEnd = f.endBlk; }
    }
    public void onUnreadable() { heard = true; lastHeardMs = rx.n; say("a frame could not be read"); }

    /** Samples from the microphone (mono, -1..1). */
    public void onAudio(float[] x, int n) {
        rx.push(x, 0, n, 1);
        if (rx.reading()) return;
        boolean speak = false;
        if (haveTurn && rx.n >= turnEnd + st.replyDelayMs) speak = true;
        else if (heard && !haveTurn && rx.quietFor() >= st.quietMs) speak = true;
        if (speak) answer();
    }

    private void answer() {
        gw.pump(link, 320);
        List<Frame> fr = link.turn();
        List<int[]> syms = new ArrayList<>();
        for (Frame f : fr) syms.add(NetCodec.encode(f.flags, f.n, f.ack, f.off, f.data, 0));
        short[] pcm = NetTx.turn(syms, st.rate, st.downHz, st.symMs, st.volume, st.leadHz, st.leadMs, 0, 60, 100);
        haveTurn = false; heard = false; turns++;
        audio.play(pcm, st.rate);
        // the microphone was not listened to meanwhile: let the receiver's clock run on in silence
        long skip = (long) pcm.length * 1000 / st.rate + st.afterMs;
        long samples = skip * st.rate / 1000;
        while (samples > 0) {
            int k = (int) Math.min(zeros.length, samples);
            rx.push(zeros, 0, k, 1);
            samples -= k;
        }
    }

    /** Whether the gateway has something to say (for the screen). */
    public boolean busy() { return gw.hasDown() || link.pending() > 0; }
}
