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
 * - Keeps the last 30 seconds of sound and a log of every frame (DiagLog).
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
        /** The first marker of a pairing test sound was heard; ring position where it starts. */
        default void onPairMarker(long pos) { }
    }

    /** The channels the phone listens on (from the handheld). */
    static final int[] LISTEN = {Channel.SU_NARROW, Channel.SU_WIDE, Channel.FU};
    /** When the phone itself sounds (nanoTime windows, from the speaker): the microphone is ignored then. */
    private final java.util.ArrayDeque<long[]> mutes = new java.util.ArrayDeque<>();
    private static final long IN_LATENCY_NS = 20_000_000L;      // a sample is read about this long after it was heard
    private final ConcurrentLinkedQueue<BitMap> newMaps = new ConcurrentLinkedQueue<>();
    private Rx[][] rx3;
    private Resampler[] rs3;
    public volatile double measuredRate = 0;
    private volatile double inRate = 0;
    private double jScale = 1.0;       // the conversion is the microphone's measured rate, times what Pair measured of the handheld's sound
    private volatile double scaleWanted = 1.0;      // set from outside, taken up by the listening thread
    private Context appCtx;
    /** The handheld's correction is its own (its chip's): kept for the next session, forgotten when Pair is pressed again. */
    public static void forgetCorrection(Context c) {
        try { c.getApplicationContext().getSharedPreferences("pair", Context.MODE_PRIVATE).edit().remove("jScale").apply(); } catch (Exception ignored) { }
    }

    /**
     * The handheld's sound runs at its own rate (its chip's): Pair measured it from the pitch of the test sound's markers
     * (accurate to about 0.01 %). 1 = as it says; a value under 1 means its sound is faster than it says. Nothing else moves
     * this (3.9.1): a rate taken from the start of a frame had been driven to its limits by steady tones.
     */
    public void setScale(double js) {
        if (js < 0.98 || js > 1.02) return;
        if (Math.abs(js - 1) < 0.00015) js = 1.0;
        scaleWanted = js;                                    // the listening thread takes it up before its next block
        DiagLog.log(String.format(java.util.Locale.US, "the handheld's sound is %+.3f%% off its stated rate (from the pitch of its test sound); reading it at %.4f of the microphone's rate", (1 / js - 1) * 100, js));
        try { if (appCtx != null) appCtx.getSharedPreferences("pair", Context.MODE_PRIVATE).edit().putFloat("jScale", (float) jScale).apply(); } catch (Exception ignored) { }
    }
    public volatile int framesW3 = 0, failsW3 = 0;
    private volatile int noiseStarts = 0;                             // fast receivers that started on noise (diagnostics)
    private final ArrayList<long[]> recent = new ArrayList<>();      // {hash, time} of messages already passed on

    // the last 6 seconds of the first microphone, for the pairing check (zero while the phone itself plays)
    private float[] ring = new float[1];
    private long ringPos = 0;
    private double mkS1, mkS2, mkCoef, mkBg; private int mkN, mkRun; private long mkRunPos;
    private double mkL1, mkL2, mkH1, mkH2, mkCoefL, mkCoefH;           // 1.6 and 2.4 kHz: the marker must stand out from them

    /** The ring position of the newest sample. */
    public synchronized long ringNow() { return ringPos; }

    /** Copies n samples from ring position pos; returns how many were still there. */
    public synchronized int ringCopy(long pos, float[] x, int n) {
        if (pos < ringPos - ring.length) pos = ringPos - ring.length;
        if (pos < 0) pos = 0;
        int k = 0;
        for (; k < n && pos + k < ringPos; k++) x[k] = ring[(int) ((pos + k) % ring.length)];
        return k;
    }

    private synchronized void ringAdd(float[] f, int frames, int ch, Callback cb) {
        int blk = Math.max(1, rate / 100);
        for (int i = 0; i < frames; i++) {
            float v = f[i * ch];
            ring[(int) (ringPos % ring.length)] = v;
            // the pairing marker: 2 kHz, at least 150 ms clearly above the background, in 10 ms blocks
            double s0 = v + mkCoef * mkS1 - mkS2; mkS2 = mkS1; mkS1 = s0;
            s0 = v + mkCoefL * mkL1 - mkL2; mkL2 = mkL1; mkL1 = s0;
            s0 = v + mkCoefH * mkH1 - mkH2; mkH2 = mkH1; mkH1 = s0;
            if (++mkN >= blk) {
                double p = (mkS1 * mkS1 + mkS2 * mkS2 - mkCoef * mkS1 * mkS2) / mkN + 1e-18;
                double pl = (mkL1 * mkL1 + mkL2 * mkL2 - mkCoefL * mkL1 * mkL2) / mkN;
                double ph = (mkH1 * mkH1 + mkH2 * mkH2 - mkCoefH * mkH1 * mkH2) / mkN;
                mkS1 = mkS2 = mkL1 = mkL2 = mkH1 = mkH2 = 0; mkN = 0;
                if (mkBg == 0) mkBg = p;
                // loud, and a pure tone (a key click or a voice fills 1.6 and 2.4 kHz too, and set it off: 3.7 logs)
                if (p > mkBg * 10 && p > 4 * (pl + ph)) {
                    if (mkRun == 0) mkRunPos = ringPos - blk;
                    if (++mkRun == 15) { long at = mkRunPos; DiagLog.log("pair: a 2 kHz marker heard"); main.post(() -> cb.onPairMarker(at)); }
                } else { mkRun = 0; mkBg += (p - mkBg) / 16; }
            }
            ringPos++;
        }
    }

    /** The phone plays until then: format 3 ignores the microphone (nanoTime). */
    public void muteBetween(long from, long until) { synchronized (mutes) { mutes.add(new long[]{from, until}); } }

    /** Zeroes the samples of f (frames of ch channels, read just now) that were heard while the phone sounded. */
    private void applyMutes(float[] f, int frames, int ch, long nowN) {
        long t0 = nowN - IN_LATENCY_NS - (long) frames * 1_000_000_000L / rate;   // when f's first sample was heard
        synchronized (mutes) {
            while (!mutes.isEmpty() && mutes.peekFirst()[1] < t0) mutes.pollFirst();
            for (long[] w : mutes) {
                long a = (w[0] - t0) * rate / 1_000_000_000L, b = (w[1] - t0) * rate / 1_000_000_000L;
                int i0 = (int) Math.max(0, a), i1 = (int) Math.min(frames, b);
                if (i1 > i0) Arrays.fill(f, i0 * ch, i1 * ch, 0f);
            }
        }
    }

    /** A frame from the handheld is coming in right now, on a silent channel. */
    public boolean hearingFrame() {
        Rx[][] r = rx3;
        if (r == null) return false;
        for (Rx[] row : r) for (Rx x : row) if (x.ch.silent && x.busy()) return true;
        return false;
    }

    /** True when the phone sounds now, or is about to (it should not start an answer then). */
    public boolean phoneSounding(long nowN) {
        synchronized (mutes) { for (long[] w : mutes) if (nowN < w[1] && nowN > w[0] - 200_000_000L) return true; }
        return false;
    }
    /** A bit map for what the handheld sends (from a link check). */
    public void addMap(BitMap m) { newMaps.add(m); }

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
        appCtx = ctx.getApplicationContext();
        try {
            float js = appCtx.getSharedPreferences("pair", Context.MODE_PRIVATE).getFloat("jScale", 1f);
            jScale = (js >= 0.98f && js <= 1.02f) ? js : 1.0;
        } catch (Exception e) { jScale = 1.0; }
        scaleWanted = jScale;
        final int ch = rec.getChannelCount();
        rx = new Receiver[ch];
        for (int c = 0; c < ch; c++) {
            rx[c] = new Receiver(rate, new Receiver.Listener() {
                @Override public void onFrame(Receiver.Frame f) { main.post(() -> cb.onFrame(f)); }
                @Override public void onUnreadable(int bandHz, int ms) { main.post(cb::onUnreadable); }
            });
        }
        // format 3 on the first microphone only: both always read the same frames (3.7 logs), at twice the
        // processor's time, and a phone that falls behind loses everything
        rx3 = new Rx[1][LISTEN.length];
        rs3 = new Resampler[1];
        for (int c = 0; c < 1; c++) {
            rs3[c] = new Resampler(rate, Channel.RATE);
            for (int k = 0; k < LISTEN.length; k++) {
                final int mic = c + 1;
                rx3[c][k] = new Rx(Channel.get(LISTEN[k]), new Rx.Sink() {
                    @Override public void onMessage(Rx r, int type, byte[] msg, float snr, int fixed) {
                        framesW3++;
                        boolean f = fresh(type, msg);
                        DiagLog.log("heard " + DiagLog.chan(r.ch.id) + " (mic " + mic + ") " + DiagLog.describe(type, msg)
                                + String.format(java.util.Locale.US, ", quality %.1f dB, %d bytes corrected", snr, fixed) + (f ? "" : ", already passed on"));
                        if (f) main.post(() -> cb.onMessage(r.ch.id, type, msg, snr));
                    }
                    @Override public void onTrain(Rx r, float[] snr) {
                        double a = 0; for (float v : snr) a += v;
                        DiagLog.log(String.format(java.util.Locale.US, "heard %s (mic %d) TRAIN, average quality %.1f dB", DiagLog.chan(r.ch.id), mic, a / Math.max(1, snr.length)));
                        main.post(() -> cb.onTrain(r.ch.id, snr));
                    }
                    // the fast receivers start on noise all the time: only the silent channels count
                    @Override public void onFail(Rx r, String why) {
                        if (r.ch.silent && !why.equals("header")) failsW3++;      // a frame that began (its header read) and was lost
                        if (r.ch.silent || !why.equals("header")) DiagLog.log(DiagLog.chan(r.ch.id) + " (mic " + mic + ") frame lost: " + why);
                        else noiseStarts++;
                    }
                    @Override public void onHeader(Rx r, int type, int len, int symbols) {
                        DiagLog.log(DiagLog.chan(r.ch.id) + " (mic " + mic + ") frame coming: " + DiagLog.typeName(type) + ", " + len
                                + " bytes, " + symbols + " symbols (" + (symbols * Channel.SYM * 1000L / Channel.RATE) + " ms)");
                    }
                });
            }
        }
        ring = new float[rate * 9];                 // 9 s: the handheld's test sound and its loudness ladder
        ringPos = 0; mkS1 = mkS2 = mkBg = 0; mkN = mkRun = 0;
        mkCoef = 2 * Math.cos(2 * Math.PI * 2000 / rate);
        mkCoefL = 2 * Math.cos(2 * Math.PI * 1600 / rate); mkCoefH = 2 * Math.cos(2 * Math.PI * 2400 / rate);
        mkL1 = mkL2 = mkH1 = mkH2 = 0;
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
                            // the phone's own microphone, even when a Bluetooth headset is connected
                            android.media.AudioDeviceInfo mic = Speaker.builtIn(ctx, AudioManager.GET_DEVICES_INPUTS, android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC);
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

    private void loop(AudioRecord rec, int ch, Callback cb) {
        short[] buf = new short[2048 * ch];
        float[] f = new float[2048 * ch];
        float[] levels = new float[Receiver.GRID_N];
        long lastLevel = 0;
        float[] mono = new float[2048], conv = new float[4096];
        long t0 = 0, counted = 0;
        inRate = rate;
        long lastRead = 0, stAt = 0, stBusy = 0, stFrames = 0; int stPeak = 0;
        DiagLog.log("microphone open: " + sourceName + ", " + channelsName + ", " + rate + " samples/s");
        try {
            rec.startRecording();
            while (running) {
                int got = rec.read(buf, 0, buf.length);
                if (got <= 0) { if (got < 0) { DiagLog.log("microphone: read error " + got); main.post(() -> cb.onProblem("The microphone stopped.")); break; } continue; }
                for (int i = 0; i < got; i++) f[i] = buf[i] / 32768f;
                int frames = got / ch;
                long nowN = System.nanoTime();
                DiagLog.mic(buf, frames, ch, rate);
                for (int i = 0; i < got; i++) { int v = Math.abs(buf[i]); if (v > stPeak) stPeak = v; }
                if (lastRead != 0 && nowN - lastRead > 300_000_000L) {
                    DiagLog.log("microphone: nothing came for " + (nowN - lastRead) / 1_000_000 + " ms");
                    // the phone was held up: sound may have been lost, which would make the microphone look slow
                    // (37,000 for 48,000: 3.7 logs). The rate is measured again from here.
                    t0 = 0; counted = 0;
                }
                lastRead = nowN;
                stFrames += frames;
                applyMutes(f, frames, ch, nowN);
                for (int c = 0; c < ch; c++) rx[c].push(f, c, frames, ch);
                ringAdd(f, frames, ch, cb);
                // the microphone's real rate, against the clock (from 2 s after the start)
                if (t0 == 0) { counted += frames; if (counted >= rate * 2L) { t0 = nowN; counted = 0; } }
                else {
                    counted += frames;
                    double el = (nowN - t0) / 1e9;
                    if (el >= 10) {
                        double r = counted / el;
                        // a phone's microphone runs within a fraction of a percent of its stated rate: a reading further
                        // off is a measurement spoilt by a held-up phone, not the microphone
                        if (Math.abs(r - rate) / rate < 0.005) {
                            if (Math.abs(r - inRate) / inRate > 0.0005) { inRate = r; for (Resampler q : rs3) q.setRates(inRate * jScale, Channel.RATE); }
                            measuredRate = r;
                        } else { DiagLog.log(String.format(java.util.Locale.US, "microphone rate: a reading of %.0f not used", r)); t0 = 0; counted = 0; }
                        if (el > 60) { t0 = nowN; counted = 0; }
                    }
                }
                BitMap nm;
                while ((nm = newMaps.poll()) != null) for (Rx[] row : rx3) for (Rx r : row) r.addMap(nm);
                if (scaleWanted != jScale) { jScale = scaleWanted; for (Resampler q : rs3) q.setRates(inRate * jScale, Channel.RATE); }
                for (int c = 0; c < rs3.length; c++) {
                    if (mono.length < frames) mono = new float[frames];
                    for (int i = 0; i < frames; i++) mono[i] = f[i * ch + c];
                    if (conv.length < rs3[c].maxOut(frames)) conv = new float[rs3[c].maxOut(frames)];
                    int n = rs3[c].process(mono, 0, frames, conv, 0);
                    for (Rx r : rx3[c]) r.push(conv, 0, n);
                }
                stBusy += System.nanoTime() - nowN;
                if (nowN - stAt > 5_000_000_000L) {
                    if (stAt != 0 && stFrames > 0) {
                        int muted;
                        synchronized (mutes) { muted = mutes.size(); }
                        DiagLog.log(String.format(java.util.Locale.US, "listening %.1f s: %d samples/s (measured %.0f), processor %.0f%% busy, loudest %d%%, frames read %d, lost %d, fast starts on noise %d, mute windows %d",
                                (nowN - stAt) / 1e9, rate, measuredRate, 100.0 * stBusy / Math.max(1, nowN - stAt), stPeak * 100 / 32768, framesW3, failsW3, noiseStarts, muted));
                    }
                    stAt = nowN; stBusy = 0; stPeak = 0; stFrames = 0;
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
                    System.arraycopy(lv, 0, levels, 0, lv.length);
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
