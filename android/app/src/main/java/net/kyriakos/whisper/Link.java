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
    private final Speaker speaker = new Speaker(listener::muteBetween);
    /** Text from the handheld; text.mirror is the one copy of its page, for every screen and the keyboard. */
    public final TextLink text = new TextLink();
    private Context app;
    private boolean speakerOk;
    private final BitMap[] sendMaps = new BitMap[Channel.COUNT];   // what the handheld measured on our channels
    public volatile long lastHeard = 0;                            // ms, any format 3 message from the handheld
    public volatile boolean handheldAnswers = false;               // it has sent a format 3 message (it listens too)
    /** The pairing check found the silent channel down too weak: answers go on the fast one. */
    public volatile boolean answersOnFast = false;

    private Link() { }

    private static String version(Context c) {
        try { return c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionName; } catch (Exception e) { return "?"; }
    }

    public boolean running() { return listener.isRunning(); }
    public boolean speakerWorks() { return speakerOk; }

    /** Starts listening (and the speaker) for this client. False when the microphone could not be opened. */
    public synchronized boolean attach(Context ctx, Client c) {
        app = ctx.getApplicationContext();
        if (!clients.contains(c)) clients.add(c);
        if (listener.isRunning()) return true;
        DiagLog.start(new java.io.File(app.getFilesDir(), "diagnostics"), "Whisper Tools " + version(app) + " on " + android.os.Build.MANUFACTURER + " "
                + android.os.Build.MODEL + ", Android " + android.os.Build.VERSION.RELEASE);
        DiagLog.log("link starting (for " + c.getClass().getSimpleName() + ")");
        PairCheck.get().load(app);
        boolean ok = listener.start(app, cb);
        if (ok) speakerOk = speaker.start(app);
        DiagLog.log("link " + (ok ? "started" : "could not start: the microphone did not open") + (ok && !speakerOk ? "; the speaker did not open" : "")
                + "; silent loudness " + silentLevel + ", answers on fast " + answersOnFast);
        return ok;
    }

    public synchronized void detach(Client c) {
        clients.remove(c);
        if (clients.isEmpty()) {
            DiagLog.log("link stopping");
            main.removeCallbacks(ackCheck);
            listener.stop();
            speaker.stop();
        }
    }

    // ---------- sending ----------

    public BitMap sendMap(int ch) { BitMap m = sendMaps[ch]; return m != null ? m : BitMap.standard(Channel.get(ch)); }

    /** Peak loudness of what the phone sends on a channel (of full scale). */
    public float level(int ch) { return ch == Channel.FD ? 0.35f : ch == Channel.SD ? silentLevel : 0.5f; }
    /** Peak of the silent channel down: as loud as this phone plays it without an audible side-sound (set by Pair). */
    public volatile float silentLevel = 0.5f;

    public boolean send(int ch, int type, byte[] payload) {
        if (!speakerOk) { DiagLog.log("send " + DiagLog.typeName(type) + ": NOT SENT, no speaker"); return false; }
        if (ch == Channel.SD && answersOnFast) ch = Channel.FD;      // see PairCheck
        Channel c = Channel.get(ch);
        float[] f = type == T_TRAIN ? Tx.train(c, level(ch)) : Tx.frame(c, sendMap(ch), type, payload, level(ch));
        boolean ok = speaker.play(f, ch == Channel.SD);
        DiagLog.log("send " + DiagLog.chan(ch) + " " + DiagLog.describe(type, payload) + String.format(java.util.Locale.US, ", loudness %.2f, %d ms", level(ch), f.length * 1000L / Channel.RATE)
                + (sendMaps[ch] != null ? ", measured map" : "") + (ok ? ", " + speaker.queued() + " queued" : ", NOT SENT: the queue is full"));
        return ok;
    }

    public int queued() { return speaker.queued(); }
    /** The pairing check's test sound (made at the modem rate). */
    public boolean playPattern(float[] f51) { return speakerOk && speaker.play(f51, true); }
    /** The loudness check: played without muting the microphone, which is what it listens with. */
    public boolean playCheck(float[] f51) { return speakerOk && speaker.play(f51, false); }
    /** When everything queued so far will have sounded (currentTimeMillis). */
    public long playEndMs() { return speaker.endMs(); }
    /** Has the fast channel down been measured (a map from the handheld)? */
    public boolean fastDownTrained() { return sendMaps[Channel.FD] != null; }
    public boolean speaking() { return speaker.playing; }
    /** Where the phone's sound goes, and how often its output had to be opened again. */
    public String soundRoute() { return speaker.route; }
    public int soundReopened() { return speaker.reopened; }

    // ---------- hearing ----------

    private boolean waitingLogged;

    private final Runnable ackCheck = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            // never over the handheld: if a frame of its is coming in, wait for its end
            if (listener.hearingFrame()) { if (!waitingLogged) DiagLog.log("text: answer waits, a frame is coming in"); waitingLogged = true; main.postDelayed(this, 40); return; }
            waitingLogged = false;
            // the answer should sound about 0.3 s after the handheld's frame ended (it was read ~40 ms after):
            // wait for that, less the time this phone's sound takes to come out
            text.quietMs = Math.max(30, 260 - speaker.delayMs());
            byte[] a = text.ackIfDue(now);
            if (a != null) DiagLog.log("text: answering after " + text.quietMs + " ms of quiet (sound delay " + speaker.delayMs() + " ms)");
            if (a != null) send(Channel.SD, T_TEXT_ACK, a);
            long next = text.nextCheck(System.currentTimeMillis());
            if (next >= 0) main.postDelayed(this, next);
        }
    };

    private final Listener.Callback cb = new Listener.Callback() {
        @Override public void onFrame(Receiver.Frame f) {
            text.mirror.apply(f, System.currentTimeMillis());       // Classic text: into the one shared copy too
            for (Client c : clients) c.onFrame(f);
        }
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
        @Override public void onPairMarker(long pos) { PairCheck.get().onMarker(pos); }
        @Override public void onMessage(int ch, int type, byte[] p, float snr) {
            long now = System.currentTimeMillis();
            if (type == net.kyriakos.whisper.w3.Pair.REPORT) PairCheck.get().onReport(p);
            lastHeard = now;
            handheldAnswers = true;
            text.heard(now);
            if (type == T_TEXT) {
                int before = text.mirror.L;
                Receiver.Frame f = text.onText(p, now);
                DiagLog.log("text: page " + before + " -> " + text.mirror.L + " bytes" + (f == null ? " (nothing new)" : ""));
                if (f != null) for (Client c : clients) c.onFrame(f);
                main.removeCallbacks(ackCheck);
                main.postDelayed(ackCheck, Math.max(10, text.nextCheck(now)));
            } else if (type == T_MAP) {
                BitMap m = BitMap.fromMessage(p);
                if (m != null && (m.ch.id == Channel.SD || m.ch.id == Channel.FD)) { sendMaps[m.ch.id] = m; DiagLog.log("map for " + DiagLog.chan(m.ch.id) + ": " + m.bitsPerSymbol() + " bits a symbol"); }
            } else if (type == T_HELLO) {
                boolean reply = p.length >= 4 && (p[3] & 1) != 0;
                if (!reply) {
                    DiagLog.log("the handheld has just started: maps forgotten");
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
