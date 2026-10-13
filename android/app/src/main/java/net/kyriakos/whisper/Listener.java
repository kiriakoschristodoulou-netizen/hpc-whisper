package net.kyriakos.whisper;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;

/**
 * Listens through the microphone and reads frames.
 *
 * - Uses the phone's unprocessed microphone where the phone offers it, and
 *   otherwise the speech-recognition source (on every Android phone, and
 *   also free of most processing): noise suppression and level control would
 *   otherwise eat the high tones.
 * - Records in stereo where the phone allows it, with a receiver for each
 *   microphone: a "dead spot" in the room rarely hits both. A frame read
 *   twice does no harm (the mirror simply gets the same piece twice).
 * - Can keep the last seconds of sound for a diagnostics recording.
 */
public final class Listener {
    public interface Callback {
        void onFrame(Receiver.Frame f);
        void onUnreadable();
        void onLevels(float[] levels);
        void onProblem(String message);
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean running;
    private Thread thread;
    public volatile String sourceName = "", channelsName = "";
    public volatile int rate = 0;
    private Receiver[] rx;

    // diagnostics: the first microphone's sound, 16-bit
    private volatile short[] tape;
    private volatile int tapePos;

    public synchronized boolean start(Context ctx, Callback cb) {
        if (running) return true;
        AudioRecord rec = open(ctx);
        if (rec == null) { cb.onProblem("The microphone could not be opened. Another app may be using it."); return false; }
        running = true;
        final int ch = rec.getChannelCount();
        rx = new Receiver[ch];
        for (int c = 0; c < ch; c++) {
            rx[c] = new Receiver(rate, new Receiver.Listener() {
                @Override public void onFrame(Receiver.Frame f) { main.post(() -> cb.onFrame(f)); }
                @Override public void onUnreadable(int bandHz, int ms) { main.post(cb::onUnreadable); }
            });
        }
        thread = new Thread(() -> loop(rec, ch, cb), "whisper-listen");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
        return true;
    }

    public synchronized void stop() {
        running = false;
        if (thread != null) { try { thread.join(1500); } catch (InterruptedException ignored) { } thread = null; }
    }

    public boolean isRunning() { return running; }

    public int framesRead() { int s = 0; Receiver[] r = rx; if (r != null) for (Receiver x : r) s += x.framesRead; return s; }

    /** Start keeping the sound for a diagnostics recording of this many seconds. */
    public void startTape(int seconds) { tapePos = 0; tape = new short[Math.max(1, rate) * seconds]; }
    public boolean tapeFull() { short[] t = tape; return t != null && tapePos >= t.length; }
    public short[] takeTape() { short[] t = tape; tape = null; return t == null ? null : java.util.Arrays.copyOf(t, Math.min(tapePos, t.length)); }

    private AudioRecord open(Context ctx) {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        boolean unprocessed = am != null
                && "true".equals(am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
        int[] sources = unprocessed
                ? new int[]{MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC}
                : new int[]{MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC};
        String[] names = unprocessed ? new String[]{"unprocessed", "speech recognition", "standard"}
                : new String[]{"speech recognition", "standard"};
        int[] rates = {48000, 44100};
        int[] chans = {AudioFormat.CHANNEL_IN_STEREO, AudioFormat.CHANNEL_IN_MONO};
        for (int s = 0; s < sources.length; s++)
            for (int r : rates)
                for (int c : chans) {
                    try {
                        int min = AudioRecord.getMinBufferSize(r, c, AudioFormat.ENCODING_PCM_16BIT);
                        if (min <= 0) continue;
                        AudioRecord ar = new AudioRecord(sources[s], r, c, AudioFormat.ENCODING_PCM_16BIT, Math.max(min * 4, r));
                        if (ar.getState() == AudioRecord.STATE_INITIALIZED) {
                            rate = r; sourceName = names[s];
                            channelsName = ar.getChannelCount() == 2 ? "two microphones" : "one microphone";
                            return ar;
                        }
                        ar.release();
                    } catch (SecurityException e) {
                        return null;                       // no permission
                    } catch (Exception ignored) { }
                }
        return null;
    }

    private void loop(AudioRecord rec, int ch, Callback cb) {
        short[] buf = new short[2048 * ch];
        float[] f = new float[2048 * ch];
        float[] levels = new float[Receiver.GRID_N];
        long lastLevel = 0;
        try {
            rec.startRecording();
            while (running) {
                int got = rec.read(buf, 0, buf.length);
                if (got <= 0) { if (got < 0) { main.post(() -> cb.onProblem("The microphone stopped.")); break; } continue; }
                for (int i = 0; i < got; i++) f[i] = buf[i] / 32768f;
                int frames = got / ch;
                for (int c = 0; c < ch; c++) rx[c].push(f, c, frames, ch);
                short[] t = tape;
                if (t != null) for (int i = 0; i < frames && tapePos < t.length; i++) t[tapePos++] = buf[i * ch];
                long now = System.currentTimeMillis();
                if (now - lastLevel > 100) {
                    lastLevel = now;
                    // how loud each grid tone is over the last 40 ms, the louder microphone of the two
                    float[] lv = new float[Receiver.GRID_N];
                    for (Receiver r : rx) {
                        int b = r.n, a = b - 40;
                        if (a < 1) continue;
                        for (int k = 0; k < lv.length; k++) lv[k] = Math.max(lv[k], (float) r.pow(k, a, b));
                    }
                    System.arraycopy(lv, 0, levels, 0, lv.length);
                    main.post(() -> cb.onLevels(lv));
                }
            }
        } catch (Exception e) {
            main.post(() -> cb.onProblem("The microphone stopped: " + e.getMessage()));
        } finally {
            try { rec.stop(); } catch (Exception ignored) { }
            rec.release();
            running = false;
        }
    }
}
