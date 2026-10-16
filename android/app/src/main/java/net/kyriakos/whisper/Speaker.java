package net.kyriakos.whisper;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTimestamp;
import android.media.AudioTrack;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Plays frames to the handheld through the phone's speaker. Frames are made
 * at the modem rate (51,200) and converted to the speaker's own rate.
 *
 * The sound keeps running between frames (silence), but only about 40 ms of
 * it is ever queued, so a frame starts sounding promptly. The sound card's
 * timestamps say when each frame really sounds; while it does (and for a
 * moment after) the listener ignores the microphone, which would only hear
 * the phone itself. Before and after, it listens.
 */
final class Speaker {
    interface Mute { void muteBetween(long fromNanos, long untilNanos); }
    private static final long KEEP_NS = 40_000_000L;           // silence kept queued ahead

    private static final class Item { final float[] f; final boolean mute; Item(float[] f, boolean m) { this.f = f; mute = m; } }
    private final ArrayBlockingQueue<Item> queue = new ArrayBlockingQueue<>(64);
    private volatile boolean running;
    private Thread thread;
    private AudioTrack track;
    private int rate;
    private final Mute mute;
    volatile boolean playing;
    volatile long playingUntil;          // nanoTime when the last queued sound ends
    volatile int framesPlayed;

    Speaker(Mute mute) { this.mute = mute; }

    synchronized boolean start() {
        if (running) return true;
        try {
            rate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC);
            if (rate < 44100) rate = 48000;
            int min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                    .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(Math.max(min * 2, rate / 5 * 2))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            // start as soon as a little is written (Android 12 on); older ones start when the buffer is full
            if (android.os.Build.VERSION.SDK_INT >= 31) { try { track.setStartThresholdInFrames(Math.max(1, rate / 50)); } catch (Exception ignored) { } }
            track.play();
        } catch (Exception e) {
            track = null;
            return false;
        }
        running = true;
        written = 0; lastHead = -1; lastHeadAt = 0;
        thread = new Thread(this::loop, "whisper-speak");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
        return true;
    }

    synchronized void stop() {
        running = false;
        if (thread != null) { try { thread.join(1500); } catch (InterruptedException ignored) { } thread = null; }
        if (track != null) { try { track.stop(); } catch (Exception ignored) { } track.release(); track = null; }
        queue.clear();
    }

    /**
     * Queues a frame made at the modem rate. False when the queue is full.
     * mute: the frame shares its band with what the phone listens to (the
     * silent channel), so the microphone is ignored while it sounds. The fast
     * channel lies in another band: the phone keeps listening through it.
     */
    boolean play(float[] frame51, boolean mute) { return running && queue.offer(new Item(frame51, mute)); }

    /** When what is queued now will have finished sounding (ms, currentTimeMillis). */
    long endMs() {
        long left = Math.max(0, playingUntil - System.nanoTime()) / 1_000_000L;
        return System.currentTimeMillis() + left;
    }

    int queued() { return queue.size(); }

    private long written = 0;                                   // frames written to the track
    private long lastHead = -1, lastHeadAt = 0;                 // the play position, and when it last moved
    private final AudioTimestamp ts = new AudioTimestamp();

    /** Frames written but not yet played. */
    private long ahead() {
        long head = track.getPlaybackHeadPosition() & 0xFFFFFFFFL;
        long d = (written - head) & 0xFFFFFFFFL;
        return d > (1L << 31) ? 0 : d;
    }

    /** When the frame at this position of the stream will sound (nanoTime). */
    private long soundsAt(long pos) {
        try {
            if (track.getTimestamp(ts) && ts.nanoTime > 0) return ts.nanoTime + (pos - ts.framePosition) * 1_000_000_000L / rate;
        } catch (Exception ignored) { }
        return System.nanoTime() + ahead() * 1_000_000_000L / rate + 30_000_000L;
    }

    /** How long a sound queued now takes to be heard (ms). */
    long delayMs() { return running ? Math.max(0, (soundsAt(written) - System.nanoTime()) / 1_000_000L) : 0; }

    private void loop() {
        short[] pcm = new short[0];
        short[] silence = new short[Math.max(1, rate / 100)];         // 10 ms
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
            try { it = queue.poll(5, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { break; }
            if (it == null) {
                if (playing && System.nanoTime() > playingUntil) { playing = false; quietSince = System.nanoTime(); }
                // keep the sound running between frames (a phone's speaker that stops fades the next sound in, and the
                // first 20 ms of it, the frame's sync symbol, were lost), but never more than 40 ms of silence ahead
                // (a track that is not playing yet, or stopped after running dry, waits for its buffer to fill: then fill it)
                long head = track.getPlaybackHeadPosition() & 0xFFFFFFFFL, nowN = System.nanoTime();
                if (head != lastHead) { lastHead = head; lastHeadAt = nowN; }
                boolean stalled = nowN - lastHeadAt > 30_000_000L;
                if (stalled || ahead() * 1_000_000_000L / rate < KEEP_NS) { track.write(silence, 0, silence.length); written += silence.length; }
                continue;
            }
            float[] x = Resampler.convert(it.f, Channel.RATE, rate);
            // the converter can overshoot the peak a little: never let it clip
            float pk = 0;
            for (float v : x) pk = Math.max(pk, Math.abs(v));
            if (pk > 0.97f) { float g = 0.97f / pk; for (int i = 0; i < x.length; i++) x[i] *= g; }
            boolean wake = !playing && System.nanoTime() - quietSince > 300_000_000L;
            int pre = wake ? lead.length : 0;
            // a little silence after each frame (format 3 asks for 25 ms between frames)
            int n = pre + x.length + rate / 30;
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
            int off = 0;
            while (off < n && running) {
                int w = track.write(pcm, off, n - off);
                if (w <= 0) break;
                off += w;
            }
            written += off;
            framesPlayed++;
        }
    }
}
