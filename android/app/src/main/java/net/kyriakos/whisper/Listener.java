package net.kyriakos.whisper;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;

import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.ConcurrentLinkedQueue;

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
 * - Also reads format 3 (docs/FORMAT3.md): the sound is converted to the
 *   modem rate (51,200) at the microphone's measured rate, and read on the
 *   silent and fast channels from the handheld. While the phone itself plays,
 *   format 3 ignores the microphone (it would only hear the phone).
 */
public final class Listener {
    public interface Callback {
        void onFrame(Receiver.Frame f);
        void onUnreadable();
        void onLevels(float[] levels);
        void onProblem(String message);
        /** A format 3 message (on the audio thread's behalf, posted to the main thread). */
        default void onMessage(int ch, int type, byte[] payload, float snrDb) { }
        default void onTrain(int ch, float[] snrDb) { }
    }

    /** The channels the phone listens on (from the handheld). */
    static final int[] LISTEN = {Channel.SU_NARROW, Channel.SU_WIDE, Channel.FU};
    private volatile long muteUntil = 0;
    private final ConcurrentLinkedQueue<BitMap> newMaps = new ConcurrentLinkedQueue<>();
    private Rx[][] rx3;
    private Resampler[] rs3;
    public volatile double measuredRate = 0;
    public volatile int framesW3 = 0, failsW3 = 0;
    private final ArrayList<long[]> recent = new ArrayList<>();      // {hash, time} of messages already passed on

    /** The phone plays until then: format 3 ignores the microphone (nanoTime). */
    public void muteUntil(long nanos) { if (nanos > muteUntil) muteUntil = nanos; }
    /** A bit map for what the handheld sends (from a link check). */
    public void addMap(BitMap m) { newMaps.add(m); }

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
        rx3 = new Rx[ch][LISTEN.length];
        rs3 = new Resampler[ch];
        for (int c = 0; c < ch; c++) {
            rs3[c] = new Resampler(rate, Channel.RATE);
            for (int k = 0; k < LISTEN.length; k++) {
                rx3[c][k] = new Rx(Channel.get(LISTEN[k]), new Rx.Sink() {
                    @Override public void onMessage(Rx r, int type, byte[] msg, float snr, int fixed) {
                        framesW3++;
                        if (fresh(type, msg)) main.post(() -> cb.onMessage(r.ch.id, type, msg, snr));
                    }
                    @Override public void onTrain(Rx r, float[] snr) { main.post(() -> cb.onTrain(r.ch.id, snr)); }
                    @Override public void onFail(Rx r, String why) { failsW3++; }
                });
            }
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

    /** False for a message already passed on from the other microphone (or a repeat within 3 s). */
    private synchronized boolean fresh(int type, byte[] msg) {
        long h = type * 1000003L + Arrays.hashCode(msg), now = System.currentTimeMillis();
        recent.removeIf(e -> now - e[1] > 3000);
        for (long[] e : recent) if (e[0] == h) return false;
        recent.add(new long[]{h, now});
        return true;
    }

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
        float[] mono = new float[2048], conv = new float[4096];
        long t0 = 0, counted = 0;
        double inRate = rate;
        try {
            rec.startRecording();
            while (running) {
                int got = rec.read(buf, 0, buf.length);
                if (got <= 0) { if (got < 0) { main.post(() -> cb.onProblem("The microphone stopped.")); break; } continue; }
                for (int i = 0; i < got; i++) f[i] = buf[i] / 32768f;
                int frames = got / ch;
                long nowN = System.nanoTime();
                boolean muted = nowN < muteUntil;
                if (muted) Arrays.fill(f, 0, got, 0f);
                for (int c = 0; c < ch; c++) rx[c].push(f, c, frames, ch);
                // the microphone's real rate, against the clock (from 2 s after the start)
                if (t0 == 0) { counted += frames; if (counted >= rate * 2L) { t0 = nowN; counted = 0; } }
                else {
                    counted += frames;
                    double el = (nowN - t0) / 1e9;
                    if (el >= 10) {
                        double r = counted / el;
                        if (Math.abs(r - inRate) / inRate > 0.0005) { inRate = r; for (Resampler q : rs3) q.setRates(inRate, Channel.RATE); }
                        measuredRate = r;
                        if (el > 60) { t0 = nowN; counted = 0; }
                    }
                }
                BitMap nm;
                while ((nm = newMaps.poll()) != null) for (Rx[] row : rx3) for (Rx r : row) r.addMap(nm);
                for (int c = 0; c < ch; c++) {
                    if (mono.length < frames) mono = new float[frames];
                    for (int i = 0; i < frames; i++) mono[i] = f[i * ch + c];
                    if (conv.length < rs3[c].maxOut(frames)) conv = new float[rs3[c].maxOut(frames)];
                    int n = rs3[c].process(mono, 0, frames, conv, 0);
                    for (Rx r : rx3[c]) r.push(conv, 0, n);
                }
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
