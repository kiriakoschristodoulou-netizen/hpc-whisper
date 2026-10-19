package net.kyriakos.whisper;

import android.content.Context;

import java.util.ArrayList;
import java.util.List;

/**
 * The one place that listens: the keyboard (while it is open) and the app's
 * own screen attach to it, and the microphone is open only while somebody is
 * attached. It keeps the one copy of the handheld's page (Mirror) that the
 * keyboard writes from, and a few numbers for the screens.
 */
public final class Hub implements Listener.Callback {
    public interface Client {
        /** A piece of text arrived (already in the shared copy). */
        void onFrame(Receiver.Frame f);
        void onUnreadable();
        void onLevels(float[] levels);
        void onProblem(String message);
    }

    private static final Hub INSTANCE = new Hub();
    public static Hub get() { return INSTANCE; }

    public final Mirror mirror = new Mirror();
    public final Listener listener = new Listener();
    private final List<Client> clients = new ArrayList<>();
    private Context app;

    /** When the last frame was read (ms since 1970), 0 = none yet; and how many have been read in all. */
    public volatile long lastFrameAt = 0;
    public volatile int frames = 0;
    public volatile String problem = "";

    private Hub() { }

    /** Starts listening (if nobody was) and tells this client about everything heard. False when the microphone cannot be opened. */
    public synchronized boolean attach(Context ctx, Client c) {
        app = ctx.getApplicationContext();
        if (!clients.contains(c)) clients.add(c);
        if (!DiagLog.on()) DiagLog.start(new java.io.File(app.getExternalFilesDir(null) == null ? app.getFilesDir() : app.getExternalFilesDir(null), "log"), "HPC Whisper keyboard");
        if (listener.isRunning()) return true;
        problem = "";
        boolean ok = listener.start(app, this);
        if (!ok && problem.isEmpty()) problem = "The microphone could not be opened.";
        return ok;
    }

    public synchronized void detach(Client c) {
        clients.remove(c);
        if (clients.isEmpty()) listener.stop();
    }

    private synchronized List<Client> copy() { return new ArrayList<>(clients); }

    // ---------- from the listener (main thread) ----------

    @Override public void onFrame(Receiver.Frame f) {
        long now = System.currentTimeMillis();
        long prev = lastFrameAt;
        boolean fresh = mirror.apply(f, now);
        frames++;
        lastFrameAt = now;
        DiagLog.log("heard: page " + f.doc + (fresh ? " (new)" : "") + ", length " + f.L + ", from " + f.o + ", " + f.bytes.length
                + " bytes, " + f.bandHz + " Hz, " + f.ms + " ms a symbol, " + f.fixed + " corrected");
        if (app != null) {
            Sessions.update(app, mirror);
            if (Prefs.cue(app) && prev != 0 && now - prev > 5000) cue();
        }
        for (Client c : copy()) c.onFrame(f);
    }
    /** A short buzz when text arrives after a pause (a setting). */
    private void cue() {
        try {
            android.os.Vibrator v = (android.os.Vibrator) app.getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null) return;
            if (android.os.Build.VERSION.SDK_INT >= 26) v.vibrate(android.os.VibrationEffect.createOneShot(40, android.os.VibrationEffect.DEFAULT_AMPLITUDE));
            else v.vibrate(40);
        } catch (Exception ignored) { }
    }

    @Override public void onUnreadable() { for (Client c : copy()) c.onUnreadable(); }
    @Override public void onLevels(float[] l) { for (Client c : copy()) c.onLevels(l); }
    @Override public void onProblem(String m) { problem = m; DiagLog.log("problem: " + m); for (Client c : copy()) c.onProblem(m); }
}
