package net.kyriakos.whisper;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.LevelCheck;
import net.kyriakos.whisper.w3.Pair;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Pairing, on the phone's side (docs/FORMAT3.md, section 7).
 *
 * Started here: first the phone finds how loud it can play the silent channel
 * without a side-sound (LevelCheck, about 3 s, with its own microphone); then it
 * plays its test sound (beeps) and listens for the handheld's. Started on the
 * handheld: the phone hears the handheld's test sound and answers with its own.
 * Each side then tells the other how it heard it, and the senders adjust.
 */
public final class PairCheck {
    public interface Watcher { void onPair(); }
    public static final int IDLE = 0, LEVEL = 1, PLAYING = 2, LISTENING = 3, DONE = 4;

    private static PairCheck instance;
    public static synchronized PairCheck get() { if (instance == null) instance = new PairCheck(); return instance; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final CopyOnWriteArrayList<Watcher> watchers = new CopyOnWriteArrayList<>();
    public int state = IDLE;
    public Pair.Result mine, theirs;            // how this phone heard the handheld; how the handheld heard this phone
    public LevelCheck.Result level;             // the last loudness check
    public String note = "";
    /** What happened, step by step, for the Pair card. */
    public final List<String> steps = new ArrayList<>();
    private boolean played, reported;
    private long playEnd, deadline, lastMarkerAt, lastMineAt;
    private Context app;

    private PairCheck() { }

    public void watch(Watcher w) { if (!watchers.contains(w)) watchers.add(w); }
    public void unwatch(Watcher w) { watchers.remove(w); }
    private void changed() { for (Watcher w : watchers) w.onPair(); }

    private void step(String s) {
        steps.add(new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date()) + "  " + s);
        while (steps.size() > 12) steps.remove(0);
    }

    public boolean running() { return state == LEVEL || state == PLAYING || state == LISTENING; }

    /** Loads what the last pairing decided. */
    public void load(Context c) {
        app = c.getApplicationContext();
        SharedPreferences p = app.getSharedPreferences("pair", Context.MODE_PRIVATE);
        Link.get().answersOnFast = p.getBoolean("answersOnFast", false);
        Link.get().silentLevel = p.getFloat("silentLevel", 0.45f);
    }

    private void save() {
        if (app == null) return;
        app.getSharedPreferences("pair", Context.MODE_PRIVATE).edit()
                .putBoolean("answersOnFast", Link.get().answersOnFast)
                .putFloat("silentLevel", Link.get().silentLevel).apply();
    }

    /** Pair pressed on this phone. Ignored while a pairing runs. */
    public void start() {
        Link link = Link.get();
        if (running()) return;
        if (!link.running()) { note = "Connect first."; changed(); return; }
        steps.clear();
        mine = null; theirs = null; played = false; reported = false;
        state = LEVEL;
        note = "Finding how loud this phone can play without a side-sound (a few faint clicks may be heard)...";
        step("Pair pressed here: checking this phone's loudness");
        float[] s = LevelCheck.sound();
        final long from = link.listener.ringNow();
        link.playCheck(s);
        final long waitMs = Math.max(LevelCheck.soundMs(), link.playEndMs() - System.currentTimeMillis()) + 400;
        main.postDelayed(() -> afterLevel(from), waitMs);
        changed();
    }

    private void afterLevel(long from) {
        Link link = Link.get();
        Listener l = link.listener;
        int n = (int) Math.min(l.ringNow() - from, (long) l.rate * 6 - 1);
        float[] x = new float[Math.max(1, n)];
        n = l.ringCopy(from, x, x.length);
        level = LevelCheck.read(x, n, l.rate);
        link.silentLevel = level.level();
        save();
        if (!level.ok) step("Loudness check: the bursts were not heard clearly; using the quietest level (" + pct(link.silentLevel) + ")");
        else if (level.clean < 0) step("Loudness check: every level made a side-sound; using the quietest (" + pct(link.silentLevel) + ")");
        else step("Loudness check: clean up to " + pct(LevelCheck.LEVELS[level.clean]) + "; using " + pct(link.silentLevel));
        playPattern("Playing this phone's test sound (beeps)...");
    }

    private static String pct(float v) { return Math.round(v * 100) + " %"; }

    private void playPattern(String why) {
        Link link = Link.get();
        state = PLAYING; played = false;
        note = why;
        step("Playing this phone's test sound");
        link.playPattern(Pair.pattern(Channel.RATE));
        playEnd = System.currentTimeMillis() + Pair.TOTAL_MS + 300;
        main.removeCallbacks(tick);
        main.postDelayed(tick, 200);
        changed();
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            if (state == PLAYING && now >= Math.max(playEnd, Link.get().playEndMs())) {
                played = true;
                if (mine != null) { state = DONE; }
                else {
                    state = LISTENING; deadline = now + 10000;
                    note = "Listening for the handheld's test sound (it answers by itself; if not, press Pair on it)...";
                    step("Listening for the handheld's test sound");
                }
                changed();
            }
            if (state == LISTENING && now > deadline) {
                state = DONE;
                note = "The handheld's test sound was not heard. Is Whisper Tools running on it, within a metre?";
                step("No test sound from the handheld in 10 s");
                changed();
            }
            if (mine != null && played && !reported) {
                reported = true;
                Link.get().send(Channel.FD, Pair.REPORT, Pair.report(mine));
                step("Sent the handheld how this phone heard it");
                if (state == DONE) note = theirs != null ? "Done." : "Done here; waiting for the handheld's results...";
                changed();
            }
            if (running() || (mine != null && !reported)) main.postDelayed(this, 200);
        }
    };

    /** The listener heard the first marker of a test sound (each test sound has two, and a 2 kHz step). */
    public void onMarker(long pos) {
        long now = System.currentTimeMillis();
        if (now - lastMarkerAt < 4500) return;                  // the rest of the same test sound
        if (state == LEVEL || state == PLAYING) return;         // our own sound (the microphone is muted anyway)
        lastMarkerAt = now;
        step("Heard the start of a test sound");
        changed();
        main.postDelayed(() -> analyze(pos), 3400);
    }

    private void analyze(long pos) {
        Listener l = Link.get().listener;
        int rate = l.rate;
        if (rate <= 0) return;
        float[] x = new float[rate * 42 / 10];
        int n = l.ringCopy(pos - rate * 7L / 10, x, x.length);
        Pair.Result r = Pair.analyze(x, n, rate);
        if (!r.found) { step("It was not a whole test sound (or too faint to measure)"); changed(); return; }
        mine = r; lastMineAt = System.currentTimeMillis();
        step("Measured the handheld's test sound");
        if (state == IDLE || state == DONE) {
            // the handheld started: our turn (its loudness check is skipped, to answer in time)
            steps.clear();
            step("The handheld started pairing; measured its test sound");
            theirs = null; reported = false;
            playPattern("Heard the handheld's test sound; now playing this phone's...");
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
        // this phone's silent band does not reach the handheld (but the fast one does): answer on the fast one
        Link.get().answersOnFast = r.band10(20000, 21200) < 120 && r.band10(500, 12000) >= 150;
        save();
        step("The handheld's results arrived");
        if (state == DONE || state == IDLE) note = "Done.";
        changed();
    }
}
