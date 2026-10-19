package net.kyriakos.whisper;

import android.content.Context;
import android.media.AudioDeviceInfo;
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
 * - Keeps the last 30 seconds of sound and a log of what was heard (DiagLog).
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

    public synchronized boolean start(Context ctx, Callback cb) {
        if (running) return true;
        AudioRecord rec = open(ctx);
        if (rec == null) { cb.onProblem("The microphone could not be opened. Another app may be using it."); return false; }
        running = true;
        final int ch = rec.getChannelCount();
        rx = new Receiver[ch];
        for (int c = 0; c < ch; c++) {
            final int mic = c + 1;
            rx[c] = new Receiver(rate, new Receiver.Listener() {
                @Override public void onFrame(Receiver.Frame f) { main.post(() -> cb.onFrame(f)); }
                @Override public void onUnreadable(int bandHz, int ms) {
                    DiagLog.log("a frame at " + bandHz + " Hz, " + ms + " ms a symbol could not be read (microphone " + mic + ")");
                    main.post(cb::onUnreadable);
                }
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
                            // the phone's own microphone, even when a Bluetooth headset is connected
                            AudioDeviceInfo mic = builtInMic(am);
                            if (mic != null) { try { ar.setPreferredDevice(mic); } catch (Exception ignored) { } }
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

    private static AudioDeviceInfo builtInMic(AudioManager am) {
        if (am == null) return null;
        try {
            for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_INPUTS))
                if (d.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC) return d;
        } catch (Exception ignored) { }
        return null;
    }

    private void loop(AudioRecord rec, int ch, Callback cb) {
        short[] buf = new short[2048 * ch];
        float[] f = new float[2048 * ch];
        long lastLevel = 0, stAt = 0, stBusy = 0, stFrames = 0;
        int stPeak = 0;
        DiagLog.log("microphone open: " + sourceName + ", " + channelsName + ", " + rate + " samples/s");
        try {
            rec.startRecording();
            while (running) {
                int got = rec.read(buf, 0, buf.length);
                if (got <= 0) { if (got < 0) { DiagLog.log("microphone: read error " + got); main.post(() -> cb.onProblem("The microphone stopped.")); break; } continue; }
                long t0 = System.nanoTime();
                for (int i = 0; i < got; i++) f[i] = buf[i] / 32768f;
                int frames = got / ch;
                DiagLog.mic(buf, frames, ch, rate);
                for (int i = 0; i < got; i++) { int v = Math.abs(buf[i]); if (v > stPeak) stPeak = v; }
                for (int c = 0; c < ch; c++) rx[c].push(f, c, frames, ch);
                stFrames += frames;
                stBusy += System.nanoTime() - t0;
                if (t0 - stAt > 10_000_000_000L) {
                    if (stAt != 0 && stFrames > 0)
                        DiagLog.log(String.format(java.util.Locale.US, "listening %.1f s: processor %.0f%% busy, loudest %d%%, frames read %d",
                                (t0 - stAt) / 1e9, 100.0 * stBusy / Math.max(1, t0 - stAt), stPeak * 100 / 32768, framesRead()));
                    stAt = t0; stBusy = 0; stPeak = 0; stFrames = 0;
                }
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
                    main.post(() -> cb.onLevels(lv));
                }
            }
        } catch (Exception e) {
            DiagLog.log("microphone stopped: " + e);
            main.post(() -> cb.onProblem("The microphone stopped: " + e.getMessage()));
        } finally {
            try { rec.stop(); } catch (Exception ignored) { }
            rec.release();
            running = false;
            DiagLog.log("microphone closed");
        }
    }
}
