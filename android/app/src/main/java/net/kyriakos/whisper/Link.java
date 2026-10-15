package net.kyriakos.whisper;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Tx;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The one connection to the handheld, shared by the keyboard, the app's
 * screens, file transfers and the remote: the microphone (Listener), the
 * speaker (Speaker), confirmations of text (TextLink), and the bit maps
 * measured by link checks. It runs while anyone uses it.
 */
public final class Link {
    public static final int T_TEXT = 0x01, T_TEXT_ACK = 0x02, T_FILE_OFFER = 0x10, T_FILE_DATA = 0x11, T_FILE_NEED = 0x12,
            T_FILE_CANCEL = 0x13, T_SCREEN = 0x20, T_INPUT = 0x21, T_TRAIN = 0x30, T_MAP = 0x31, T_HELLO = 0x32, T_CHECK = 0x33;

    public interface Client {
        default void onFrame(Receiver.Frame f) { }                 // text, from either format
        default void onMessage(int ch, int type, byte[] payload, float snrDb) { }
        default void onLevels(float[] levels) { }
        default void onProblem(String message) { }
        default void onUnreadable() { }
        default void onTrain(int ch, float[] snrDb) { }
    }

    private static Link instance;
    public static synchronized Link get() { if (instance == null) instance = new Link(); return instance; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<Client> clients = new CopyOnWriteArrayList<>();
    public final Listener listener = new Listener();
    private final Speaker speaker = new Speaker(listener::muteUntil);
    public final TextLink text = new TextLink();
    private Context app;
    private boolean speakerOk;
    private final BitMap[] sendMaps = new BitMap[Channel.COUNT];   // what the handheld measured on our channels
    public volatile long lastHeard = 0;                            // ms, any format 3 message from the handheld
    public volatile boolean handheldAnswers = false;               // it has sent a format 3 message (it listens too)

    private Link() { }

    public boolean running() { return listener.isRunning(); }
    public boolean speakerWorks() { return speakerOk; }

    /** Starts listening (and the speaker) for this client. False when the microphone could not be opened. */
    public synchronized boolean attach(Context ctx, Client c) {
        app = ctx.getApplicationContext();
        if (!clients.contains(c)) clients.add(c);
        if (listener.isRunning()) return true;
        boolean ok = listener.start(app, cb);
        if (ok) speakerOk = speaker.start();
        return ok;
    }

    public synchronized void detach(Client c) {
        clients.remove(c);
        if (clients.isEmpty()) {
            main.removeCallbacks(ackCheck);
            listener.stop();
            speaker.stop();
        }
    }

    // ---------- sending ----------

    public BitMap sendMap(int ch) { BitMap m = sendMaps[ch]; return m != null ? m : BitMap.standard(Channel.get(ch)); }

    /** Peak loudness of what the phone sends on a channel (of full scale). */
    public static float level(int ch) { return ch == Channel.FD ? 0.35f : 0.9f; }

    public boolean send(int ch, int type, byte[] payload) {
        if (!speakerOk) return false;
        Channel c = Channel.get(ch);
        float[] f = type == T_TRAIN ? Tx.train(c, level(ch)) : Tx.frame(c, sendMap(ch), type, payload, level(ch));
        return speaker.play(f, ch == Channel.SD);
    }

    public int queued() { return speaker.queued(); }
    /** When everything queued so far will have sounded (currentTimeMillis). */
    public long playEndMs() { return speaker.endMs(); }
    /** Has the fast channel down been measured (a map from the handheld)? */
    public boolean fastDownTrained() { return sendMaps[Channel.FD] != null; }
    public boolean speaking() { return speaker.playing; }

    // ---------- hearing ----------

    private final Runnable ackCheck = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            byte[] a = text.ackIfDue(now);
            if (a != null) send(Channel.SD, T_TEXT_ACK, a);
            long next = text.nextCheck(System.currentTimeMillis());
            if (next >= 0) main.postDelayed(this, next);
        }
    };

    private final Listener.Callback cb = new Listener.Callback() {
        @Override public void onFrame(Receiver.Frame f) { for (Client c : clients) c.onFrame(f); }
        @Override public void onUnreadable() { for (Client c : clients) c.onUnreadable(); }
        @Override public void onLevels(float[] l) { for (Client c : clients) c.onLevels(l); }
        @Override public void onProblem(String m) { for (Client c : clients) c.onProblem(m); }
        @Override public void onTrain(int ch, float[] snr) {
            // the handheld trained the fast channel up: the map goes back to it on the silent channel
            if (ch == Channel.FU) {
                BitMap m = BitMap.fromSnr(Channel.get(ch), nextMapNumber(), snr);
                if (m.bitsPerSymbol() >= 8) {
                    listener.addMap(m);
                    send(Channel.SD, T_MAP, m.toMessage());
                }
            }
            for (Client c : clients) c.onTrain(ch, snr);
        }
        @Override public void onMessage(int ch, int type, byte[] p, float snr) {
            long now = System.currentTimeMillis();
            lastHeard = now;
            handheldAnswers = true;
            text.heard(now);
            if (type == T_TEXT) {
                Receiver.Frame f = text.onText(p, now);
                if (f != null) for (Client c : clients) c.onFrame(f);
                main.removeCallbacks(ackCheck);
                main.postDelayed(ackCheck, Math.max(10, text.nextCheck(now)));
            } else if (type == T_MAP) {
                BitMap m = BitMap.fromMessage(p);
                if (m != null && (m.ch.id == Channel.SD || m.ch.id == Channel.FD)) sendMaps[m.ch.id] = m;
            } else if (type == T_HELLO) {
                boolean reply = p.length >= 4 && (p[3] & 1) != 0;
                if (!reply) {
                    resetMaps();                                      // a handheld that has just started knows no maps
                    if (System.currentTimeMillis() - lastHello > 3000) { lastHello = System.currentTimeMillis(); main.postDelayed(() -> sayHello(true), 300); }
                }
            } else if (type == T_CHECK && p.length >= 1 && p[0] == Channel.FD) {
                send(Channel.FD, T_TRAIN, new byte[0]);                 // the handheld asks to measure the fast channel down
            }
            for (Client c : clients) c.onMessage(ch, type, p, snr);
        }
    };

    private long lastHello = 0;
    private int mapNo = 1;
    private int nextMapNumber() { mapNo = mapNo % 31 + 1; return mapNo; }

    /** Forget the measured maps (the handheld uses the standard ones again after its next start). */
    public void resetMaps() {
        for (int i = 0; i < sendMaps.length; i++) sendMaps[i] = null;
    }

    /** HELLO: format version 3, what this phone can hear and play (bit = channel), and whether it answers one. */
    public void sayHello(boolean reply) {
        int hear = (1 << Channel.SU_NARROW) | (1 << Channel.SU_WIDE) | (1 << Channel.FU);
        int play = speakerOk ? (1 << Channel.SD) | (1 << Channel.FD) : 0;
        send(Channel.SD, T_HELLO, new byte[]{3, (byte) hear, (byte) play, (byte) (reply ? 1 : 0)});
    }
}
