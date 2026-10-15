package net.kyriakos.whisper;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Pair;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The pairing check on the phone's side (docs/FORMAT3.md, section 7): each
 * device plays a 3-second test sound (beeps) and measures the other's; each then
 * tells the other how it heard it, and the senders adjust: the phone answers on
 * the fast channel when its silent band does not reach the handheld.
 * Either side can start; the other answers by itself.
 */
public final class PairCheck {
    public interface Watcher { void onPair(); }
    public static final int IDLE = 0, PLAYING = 1, LISTENING = 2, DONE = 3;

    private static PairCheck instance;
    public static synchronized PairCheck get() { if (instance == null) instance = new PairCheck(); return instance; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<Watcher> watchers = new CopyOnWriteArrayList<>();
    public int state = IDLE;
    public Pair.Result mine, theirs;            // how this phone hears the handheld; how the handheld hears this phone
    public String note = "";
    private boolean played, reported;
    private long playEnd, deadline;
    private Context app;

    private PairCheck() { }

    public void watch(Watcher w) { if (!watchers.contains(w)) watchers.add(w); }
    public void unwatch(Watcher w) { watchers.remove(w); }
    private void changed() { for (Watcher w : watchers) w.onPair(); }

    /** Loads what the last pairing decided. */
    public void load(Context c) {
        app = c.getApplicationContext();
        SharedPreferences p = app.getSharedPreferences("pair", Context.MODE_PRIVATE);
        Link.get().answersOnFast = p.getBoolean("answersOnFast", false);
    }

    private void save() {
        if (app == null) return;
        app.getSharedPreferences("pair", Context.MODE_PRIVATE).edit().putBoolean("answersOnFast", Link.get().answersOnFast).apply();
    }

    /** Plays this phone's test sound, then listens for the handheld's. */
    public void start() {
        Link link = Link.get();
        if (!link.running()) { note = "Connect first."; changed(); return; }
        state = PLAYING; played = false; reported = false;
        if (mine != null && System.currentTimeMillis() - lastMineAt > 15000) mine = null;
        note = "Playing this phone's test sound (beeps)...";
        link.playPattern(Pair.pattern(Channel.RATE));
        playEnd = System.currentTimeMillis() + Pair.TOTAL_MS + 900;
        main.removeCallbacks(tick);
        main.postDelayed(tick, 200);
        changed();
    }

    private long lastMineAt;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            if (state == PLAYING && now >= Math.max(playEnd, Link.get().playEndMs())) {
                played = true;
                if (mine != null) state = DONE;
                else { state = LISTENING; deadline = now + 10000; note = "Listening for the handheld's test sound (press Pair on it if it does not start by itself)..."; }
                changed();
            }
            if (state == LISTENING && now > deadline) {
                state = DONE;
                note = "The handheld's test sound was not heard. Is Whisper Tools running on it, with the phone within a metre?";
                changed();
            }
            if (mine != null && played && !reported) {
                reported = true;
                Link.get().send(Channel.FD, Pair.REPORT, Pair.report(mine));
                if (state == DONE) note = "Done: the results below. The handheld shows its side.";
                changed();
            }
            if (state == PLAYING || state == LISTENING || (mine != null && !reported)) main.postDelayed(this, 200);
        }
    };

    /** The listener heard the first marker of a test sound. */
    public void onMarker(long pos) {
        main.postDelayed(() -> analyze(pos), 3400);
    }

    private void analyze(long pos) {
        Listener l = Link.get().listener;
        int rate = l.rate;
        if (rate <= 0) return;
        float[] x = new float[rate * 42 / 10];
        int n = l.ringCopy(pos - rate * 7L / 10, x, x.length);
        Pair.Result r = Pair.analyze(x, n, rate);
        if (!r.found) return;
        mine = r; lastMineAt = System.currentTimeMillis();
        if (state == IDLE || state == DONE) {
            start();                                    // the handheld started: our turn
            note = "Heard the handheld's test sound; now playing this phone's...";
        } else if (state == LISTENING) state = DONE;
        main.removeCallbacks(tick);
        main.post(tick);
        changed();
    }

    /** The handheld's report: how it heard this phone. */
    public void onReport(byte[] p) {
        Pair.Result r = Pair.read(p);
        if (!r.found) return;
        theirs = r;
        // the phone's silent band does not reach the handheld (but the fast one does): answer on the fast one
        Link.get().answersOnFast = r.band10(19400, 20800) < 120 && r.band10(500, 12000) >= 150;
        save();
        changed();
    }
}
