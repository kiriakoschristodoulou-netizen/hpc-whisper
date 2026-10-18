package net.kyriakos.whisper;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Build;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Plays frames to the handheld through the phone's own speaker. Frames are made
 * at the modem rate (51,200) and converted to the speaker's own rate.
 *
 * - The link works through the air, so the sound always goes to the phone's own
 *   speaker, even when Bluetooth or a computer is set to play the phone's sound
 *   (the fifth device test: it went to Bluetooth, and only scraps came out).
 * - The sound keeps running between frames (silence, the buffer kept full): a
 *   phone's speaker that stops fades the next sound in, and loses its start.
 * - A sound is never cut short: what the sound output does not take is offered
 *   again, and an output that has died (its route changed) is opened again.
 * - The sound card's timestamps say when each frame really sounds; the listener
 *   ignores the microphone only then (and its echo, 60 ms), and the link times its
 *   answers by the same delay.
 */
final class Speaker {
    interface Mute { void muteBetween(long fromNanos, long untilNanos); }

    private static final class Item { final float[] f; final boolean mute; final int gapMs; Item(float[] f, boolean m, int g) { this.f = f; mute = m; gapMs = g; } }
    private final ArrayBlockingQueue<Item> queue = new ArrayBlockingQueue<>(64);
    private volatile boolean running;
    private Thread thread;
    private volatile AudioTrack track;
    private int rate;
    private final Mute mute;
    private Context ctx;
    volatile boolean playing;
    volatile long playingUntil;          // nanoTime when the last queued sound ends
    volatile int framesPlayed;
    /** How many times the sound output had to be opened again, and what it plays on. */
    volatile int reopened;
    volatile String route = "";
    private long written = 0;            // frames written to the current track
    private final AudioTimestamp ts = new AudioTimestamp();

    Speaker(Mute mute) { this.mute = mute; }

    synchronized boolean start(Context c) {
        if (running) return true;
        ctx = c.getApplicationContext();
        if (!open()) return false;
        running = true;
        thread = new Thread(this::loop, "whisper-speak");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
        return true;
    }

    /** Opens the sound output, on the phone's own speaker. */
    private boolean open() {
        try {
            rate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC);
            if (rate < 44100) rate = 48000;
            int min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            AudioTrack t = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                    .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(Math.max(min * 2, rate / 10 * 2))          // about 100 ms: kept full, so answers come out soon
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            AudioDeviceInfo sp = builtIn(ctx, AudioManager.GET_DEVICES_OUTPUTS, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER);
            if (sp != null) t.setPreferredDevice(sp);
            t.play();
            track = t;
            written = 0;
            route = routeName();
            DiagLog.log("speaker open: " + rate + " samples/s, buffer " + Math.max(min * 2, rate / 10 * 2) + " bytes, playing on " + (route.isEmpty() ? "(not known yet)" : route));
            return true;
        } catch (Exception e) {
            track = null;
            DiagLog.log("speaker: could not open: " + e);
            return false;
        }
    }

    /** The phone's own device of this type (speaker or microphone), or null. */
    static AudioDeviceInfo builtIn(Context c, int which, int type) {
        try {
            AudioManager am = (AudioManager) c.getSystemService(Context.AUDIO_SERVICE);
            if (am == null) return null;
            for (AudioDeviceInfo d : am.getDevices(which)) if (d.getType() == type) return d;
        } catch (Exception ignored) { }
        return null;
    }

    private String routeName() {
        try {
            AudioDeviceInfo d = track != null && Build.VERSION.SDK_INT >= 24 ? track.getRoutedDevice() : null;
            if (d == null) return "";
            switch (d.getType()) {
                case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER: return "the phone's speaker";
                case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP: case AudioDeviceInfo.TYPE_BLUETOOTH_SCO: return "Bluetooth (" + d.getProductName() + ")";
                case AudioDeviceInfo.TYPE_WIRED_HEADPHONES: case AudioDeviceInfo.TYPE_WIRED_HEADSET: return "headphones";
                case AudioDeviceInfo.TYPE_USB_DEVICE: case AudioDeviceInfo.TYPE_USB_HEADSET: return "USB";
                default: return "another output (" + d.getProductName() + ")";
            }
        } catch (Exception e) { return ""; }
    }

    synchronized void stop() {
        running = false;
        if (thread != null) { try { thread.join(1500); } catch (InterruptedException ignored) { } thread = null; }
        close();
        queue.clear();
    }

    private void close() {
        AudioTrack t = track;
        track = null;
        if (t != null) { try { t.stop(); } catch (Exception ignored) { } try { t.release(); } catch (Exception ignored) { } }
    }

    /**
     * Queues a frame made at the modem rate. False when the queue is full.
     * mute: the frame shares its band with what the phone listens to (the
     * silent channel), so the microphone is ignored while it sounds. The fast
     * channel lies in another band: the phone keeps listening through it.
     */
    boolean play(float[] frame51, boolean mute) { return play(frame51, mute, 0); }

    /** gapMs: the quiet after the frame (0 = the usual 33 ms). The fast channel down leaves more: the handheld's receiver needs the time. */
    boolean play(float[] frame51, boolean mute, int gapMs) { return running && queue.offer(new Item(frame51, mute, gapMs)); }

    /** When what is queued now will have finished sounding (ms, currentTimeMillis). */
    long endMs() {
        long left = Math.max(0, playingUntil - System.nanoTime()) / 1_000_000L;
        return System.currentTimeMillis() + left;
    }

    int queued() { return queue.size(); }

    /** When the frame at this position of the stream will sound (nanoTime): from the sound card's timestamp, checked. */
    private long soundsAt(long pos) {
        AudioTrack t = track;
        long now = System.nanoTime();
        long guess = now + 250_000_000L;                              // a full buffer and the output's own delay, at most
        if (t == null) return guess;
        try {
            if (t.getTimestamp(ts) && ts.nanoTime > 0) {
                long at = ts.nanoTime + (pos - ts.framePosition) * 1_000_000_000L / rate;
                if (at > now - 50_000_000L && at < now + 1_000_000_000L) return at;   // believable
            }
        } catch (Exception ignored) { }
        return guess;
    }

    /** How long a sound queued now takes to be heard (ms). */
    long delayMs() { return running ? Math.max(0, (soundsAt(written) - System.nanoTime()) / 1_000_000L) : 250; }

    /** Writes all of pcm[0..n), whatever happens to the output. Returns false if it could not. */
    private boolean writeAll(short[] pcm, int n) {
        int off = 0, idle = 0;
        while (off < n && running) {
            AudioTrack t = track;
            int w = t == null ? AudioTrack.ERROR_DEAD_OBJECT : t.write(pcm, off, n - off);
            if (w > 0) { off += w; written += w; idle = 0; continue; }
            if (w == 0) {                                             // not taken just now: offer it again
                if (++idle > 200) { w = AudioTrack.ERROR_DEAD_OBJECT; } else { sleep(5); continue; }
            }
            // the output died (its route changed, or the system took it): open it again and go on
            DiagLog.log("speaker: the output " + (w == 0 ? "took nothing for a second" : "failed (" + w + ")") + ", opening it again");
            close();
            reopened++;
            if (!open()) { sleep(200); if (!open()) return false; }
            idle = 0;
        }
        return off >= n;
    }

    private static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException ignored) { } }

    private void loop() {
        short[] pcm = new short[0];
        short[] silence = new short[Math.max(1, rate / 50)];          // 20 ms
        // the lead-in: a quiet 21.7 kHz tone, faded in and out (inaudible; it lets the speaker wake up)
        int ln = rate * 150 / 1000, ramp = rate / 100;
        short[] lead = new short[ln];
        for (int i = 0; i < ln; i++) {
            double g = 1200;
            if (i < ramp) g = g * i / ramp;
            if (ln - 1 - i < ramp) g = g * (ln - 1 - i) / ramp;
            lead[i] = (short) Math.round(g * Math.sin(2 * Math.PI * 21700.0 * i / rate));
        }
        long quietSince = System.nanoTime();
        while (running) {
            Item it;
            try { it = queue.poll(10, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { break; }
            if (it == null) {
                if (playing && System.nanoTime() > playingUntil) { playing = false; quietSince = System.nanoTime(); }
                // keep the sound running between frames (blocks while the buffer is full)
                writeAll(silence, silence.length);
                continue;
            }
            float[] x = Resampler.convert(it.f, Channel.RATE, rate);
            // the converter can overshoot the peak a little: never let it clip
            float pk = 0;
            for (float v : x) pk = Math.max(pk, Math.abs(v));
            if (pk > 0.97f) { float g = 0.97f / pk; for (int i = 0; i < x.length; i++) x[i] *= g; }
            boolean wake = !playing && System.nanoTime() - quietSince > 300_000_000L;
            int pre = wake ? lead.length : 0;
            // a little silence after each frame (format 3 asks for 25 ms between frames; the fast channel down, more)
            int n = pre + x.length + (it.gapMs > 0 ? rate * it.gapMs / 1000 : rate / 30);
            if (pcm.length < n) pcm = new short[n];
            for (int i = 0; i < pre; i++) pcm[i] = lead[i];
            for (int i = pre; i < n; i++) {
                int j = i - pre;
                float v = j < x.length ? x[j] : 0;
                pcm[i] = (short) Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
            }
            long dur = (long) n * 1_000_000_000L / rate;
            long start = soundsAt(written);
            playingUntil = start + dur;
            // the microphone hears this phone from when it sounds until its echo has died away
            if (it.mute) mute.muteBetween(start - 20_000_000L, playingUntil + 60_000_000L);
            playing = true;
            DiagLog.log(String.format(java.util.Locale.US, "speaker: a sound of %d ms%s sounds in %d ms%s", dur / 1_000_000L, wake ? " (with a wake-up lead-in)" : "",
                    Math.max(0, (start - System.nanoTime()) / 1_000_000L), it.mute ? ", microphone ignored meanwhile" : ""));
            if (!writeAll(pcm, n)) DiagLog.log("speaker: the sound could not be written");
            framesPlayed++;
            String r = routeName();
            if (!r.isEmpty() && !r.equals(route)) DiagLog.log("speaker: now playing on " + r);
            if (!r.isEmpty()) route = r;
        }
    }
}
