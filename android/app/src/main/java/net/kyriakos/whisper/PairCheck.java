package net.kyriakos.whisper;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Ladder;
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
    public Ladder.Result ladder;                // the handheld's loudness ladder, as heard here
    /** The last test sound heard (what was analysed), to share when it was not understood. */
    public volatile float[] lastHeard; public volatile int lastHeardRate;
    private boolean ladderDone;
    /** The self test: what was heard, and where this phone's part of it stands. */
    public final SelfTest test = new SelfTest();
    private boolean pStarted, ownPatternPending, finished;
    private long pEndAt;
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
        DiagLog.log("pair: " + s);
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
        Link.get().answersOnTones = p.getBoolean("answersOnTones", true);
        Link.get().tdLevel = p.getFloat("tdLevel", 0.3f);
        Link.get().fdLevel = p.getFloat("fdLevel", 0.35f);
    }

    private void save() {
        if (app == null) return;
        app.getSharedPreferences("pair", Context.MODE_PRIVATE).edit()
                .putBoolean("answersOnFast", Link.get().answersOnFast)
                .putBoolean("answersOnTones", Link.get().answersOnTones)
                .putFloat("tdLevel", Link.get().tdLevel)
                .putFloat("fdLevel", Link.get().fdLevel)
                .putFloat("silentLevel", Link.get().silentLevel).apply();
    }

    /** Pair pressed on this phone. Ignored while a pairing runs. */
    public void start() {
        Link link = Link.get();
        if (running()) return;
        if (!link.running()) { note = "Connect first."; changed(); return; }
        if (app != null) Listener.forgetCorrection(app);
        steps.clear();
        mine = null; theirs = null; played = false; reported = false;
        test.begin(); pStarted = false; ownPatternPending = false; finished = false; ladderDone = false;
        main.removeCallbacks(testTick); main.removeCallbacks(fallbackP);
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
        if (!level.ok) step("Loudness check: this phone's microphone did not hear its own speaker clearly. Is its sound going to "
                + "Bluetooth or another device (" + link.soundRoute() + ")? Using the quietest level (" + pct(link.silentLevel) + ")");
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
                    state = LISTENING; deadline = now + 15000;
                    note = "Listening for the handheld's test sound (it answers by itself; if not, press Pair on it)...";
                    step("Listening for the handheld's test sound");
                }
                changed();
            }
            if (state == LISTENING && now > deadline && mine == null) {
                state = DONE;
                note = "The handheld's test sound was not heard. Is Whisper Tools running on it, within a metre?";
                step("No test sound from the handheld in 15 s");
                changed();
            }
            if (mine != null && played && ladderDone && pStarted && !reported) {
                reported = true;
                Link.get().send(Link.get().answersOnTones ? Channel.SD : Channel.FD, Pair.REPORT, Pair.report(mine));
                step("Sent the handheld how this phone heard it");
                if (state == DONE) note = theirs != null ? "Done." : "Done here; waiting for the handheld's results...";
                changed();
            }
            if (running() || (mine != null && !reported && !finished)) main.postDelayed(this, 200);
        }
    };

    /** The listener heard the first marker of a test sound (each test sound has two, and a 2 kHz step). */
    public void onMarker(long pos) {
        long now = System.currentTimeMillis();
        if (now - lastMarkerAt < 8000) return;                  // the rest of the same test sound (and its ladder)
        if (state == LEVEL || state == PLAYING) return;         // our own sound (the microphone is muted anyway)
        lastMarkerAt = now;
        test.begin(); pStarted = false; finished = false;
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
        lastHeard = java.util.Arrays.copyOf(x, n); lastHeardRate = rate;
        Pair.Result r = Pair.analyze(x, n, rate);
        if (!r.found) { step("It was not a whole test sound: " + r.why + ". (Share it with the button below.)"); changed(); return; }
        mine = r; lastMineAt = System.currentTimeMillis();
        // the handheld's own clock, from the pitch of its markers (against this microphone's real rate)
        double eff = l.measuredRate > 0 ? l.measuredRate : rate;
        double sc = Pair.pitchScale(x, n, eff, r.aAt, r.bAt);
        if (Double.isNaN(sc)) step("The pitch of the handheld's markers could not be measured; its sound is taken as it says");
        else {
            step(String.format(Locale.US, "The handheld's sound runs %+.3f %% against what it says", (sc - 1) * 100));
            l.setScale(1.0 / sc);
        }
        ladderDone = false;
        step("Measured the handheld's test sound; now its loudness steps...");
        main.removeCallbacks(fallbackP);
        main.postDelayed(fallbackP, 50000);                      // the end mark of its part never came: go on anyway
        // the handheld's loudness ladder follows its test sound: read it once it has ended, then answer
        final long a = pos - rate * 7L / 10 + r.aAt;                   // marker A, in the ring
        main.postDelayed(() -> readLadder(a, r.scale10k), 3700);
        changed();
    }

    private void readLadder(long a, int scale10k) {
        Listener l = Link.get().listener;
        int rate = l.rate;
        long from = a + (long) (Pair.TOTAL_MS - Pair.A_MS - Ladder.BEFORE_END_MS) * rate / 1000 * scale10k / 10000;
        float[] x = new float[rate * 42 / 10];
        int n = l.ringCopy(from, x, x.length);
        ladder = Ladder.read(x, n, rate);
        if (mine != null) { mine.ladder = ladder.found ? ladder.choice : -1; mine.ladderQ = ladder.found ? (int) Math.round(ladder.qDb[ladder.choice]) : 0; }
        if (ladder.found) step(String.format(java.util.Locale.US, "The handheld's loudness: step %d of %d (%.0f dB clean)", ladder.choice + 1, Ladder.STEPS, ladder.qDb[ladder.choice]));
        else step("The handheld's loudness steps were not read: " + ladder.why);
        ladderDone = true;
        if (state == IDLE || state == DONE) {
            // the handheld started: our turn when its part of the self test has ended (its end mark, or the fallback)
            // (this phone's loudness check is skipped, to answer in time)
            theirs = null; reported = false; ownPatternPending = true;
            note = "Heard the handheld's test sound; its self test follows, then this phone's turn...";
            if (test.endH) startBlockP();
        } else if (state == LISTENING) {
            state = DONE;
            if (test.endH) startBlockP();
        }
        main.removeCallbacks(tick);
        main.post(tick);
        changed();
    }

    // ---------- the self test ----------

    private final Runnable fallbackP = () -> { if (!pStarted && (mine != null || !test.heardNothing())) { step("The handheld's end mark was not heard; going on"); startBlockP(); } };

    /** A format 3 test frame from the handheld was read. */
    public void onTestMessage(int stage) {
        if (stage == SelfTest.ST_END_H && !pStarted && (mine != null || ownPatternPending || state == LISTENING || state == DONE))
            main.postDelayed(this::startBlockP, 500);
        changed();
    }

    /** A frame of tones of the self test was read (or the handheld's results). */
    public void onTestTones() {
        if (test.reported) finish();
        else if (test.endH && !pStarted && (mine != null || ownPatternPending || state == LISTENING || state == DONE)) main.postDelayed(this::startBlockP, 500);
        changed();
    }

    /** This phone's part: its test sound if the handheld started, then its frames, then the wait for the handheld's results. */
    private void startBlockP() {
        if (pStarted) return;
        pStarted = true;
        main.removeCallbacks(fallbackP);
        Link link = Link.get();
        if (ownPatternPending) {
            ownPatternPending = false;
            playPattern("Playing this phone's test sound (beeps)...");
        }
        int run = Math.max(0, test.run);
        step("Playing this phone's part of the self test");
        // tones down and fast down each at three loudnesses (the handheld's microphone has no gain control and may clip)
        for (int i = 0; i < SelfTest.NTD; i++) link.sendTest(Link.TD, SelfTest.payload(run, SelfTest.ST_TD, i, SelfTest.TD_LEN), SelfTest.TD_LEVELS[i]);
        for (int i = 0; i < SelfTest.NSD; i++) link.sendTest(Channel.SD, SelfTest.payload(run, SelfTest.ST_SD, i));
        for (int i = 0; i < SelfTest.NFD; i++) link.sendTest(Channel.FD, SelfTest.payload(run, SelfTest.ST_FD, i), SelfTest.FD_LEVELS[i]);
        link.sendTest(Link.TD, SelfTest.payload(run, SelfTest.ST_END_P, 0, SelfTest.TD_LEN), link.tdLevel);       // the end mark: tones
        pEndAt = link.playEndMs();
        note = "Self test: this phone is playing its part; then the handheld tells what it heard (about a minute in all)...";
        main.removeCallbacks(testTick);
        main.postDelayed(testTick, 1000);
        main.removeCallbacks(tick);
        main.post(tick);
        changed();
    }

    private final Runnable testTick = new Runnable() {
        @Override public void run() {
            if (finished) return;
            if (test.reported) { finish(); return; }
            if (System.currentTimeMillis() > pEndAt + 70000) { finish(); return; }
            main.postDelayed(this, 1000);
        }
    };

    /** The handheld's results are in (or did not come): the words, the log, and what this phone decides. */
    private void finish() {
        if (finished) return;
        finished = true;
        main.removeCallbacks(testTick);
        DiagLog.log(test.oneLine());
        for (String l : test.lines()) DiagLog.log("self test: " + l.trim());
        step(test.oneLine().replace("self test: ", "Self test: "));
        if (test.reported) {
            // what the handheld really read of this phone decides how answers go (the test sound's bands only guessed)
            Link link = Link.get();
            boolean sd = test.sdOk(), td = test.tdOk(), fd = test.fdOk();
            link.answersOnTones = !sd && td;                                    // short messages: silent if it works, else tones
            link.answersOnFast = !sd && fd;                                      // the long ones: silent if it works, else fast
            if (!sd && !td && !fd) link.answersOnTones = true;                   // nothing worked: tones are the best chance
            int i = SelfTest.middle(test.tdMask);
            if (i >= 0) link.tdLevel = SelfTest.TD_LEVELS[i];
            i = SelfTest.middle(test.fdMask);
            if (i >= 0) link.fdLevel = SelfTest.FD_LEVELS[i];
            DiagLog.log(String.format(java.util.Locale.US, "self test decided: short answers on %s, long ones on %s, tones at %.2f, fast at %.2f",
                    link.answersOnTones ? "tones" : "the silent channel", link.answersOnFast ? "the fast channel" : "the silent channel", link.tdLevel, link.fdLevel));
            save();
            note = "Self test done. The results are below.";
        } else note = "Self test: this phone's part was played, but the handheld's results did not arrive (an older Whisper Tools on the handheld, or it did not hear the end of this phone's part).";
        changed();
    }

    /** The handheld's report: how it heard this phone. */
    public void onReport(byte[] p) {
        Pair.Result r = Pair.read(p);
        if (!r.found) return;
        theirs = r;
        // (the self test, when it runs, has the last word on how answers go; this is its guess from the test sound's bands)
        if (!test.reported) {
            Link.get().answersOnFast = r.band10(20000, 21200) < 120 && r.band10(500, 12000) >= 150;
            save();
        }
        step("The handheld's results arrived");
        if (state == DONE || state == IDLE) note = "Done.";
        changed();
    }
}
