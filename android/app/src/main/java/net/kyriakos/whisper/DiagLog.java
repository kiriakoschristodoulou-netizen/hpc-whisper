package net.kyriakos.whisper;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * The phone's diagnostics: every event of the keyboard as one line with the time of day (to the millisecond), in
 * a log file kept on the phone, and the last 30 seconds of what the microphone heard (the first microphone,
 * before anything is muted). Lines collect in memory and go to the file once a second from a thread of
 * their own. Past 2 MB the log moves to an old file and starts again (the two together are shared).
 * Plain Java (no Android), so the tests compile with it; until start() it does nothing.
 */
public final class DiagLog {
    private DiagLog() { }

    private static final Object lock = new Object();
    private static StringBuilder pending = new StringBuilder();
    private static File dir;
    private static volatile boolean on;
    private static final long MAX = 2L << 20;
    private static final SimpleDateFormat TIME = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);
    private static String lastLine = "";
    private static int repeats = 0;

    // the last 30 s of sound
    private static final int SOUND_S = 30;
    private static final Object tapeLock = new Object();
    private static short[] tape = new short[0];
    private static long tapePos = 0;
    private static int tapeRate = 0;
    private static long tapeEndMs = 0;

    /** Starts writing into this folder (once; later calls only log the start). */
    public static void start(File folder, String what) {
        synchronized (lock) {
            if (!on) {
                dir = folder;
                dir.mkdirs();
                on = true;
                Thread t = new Thread(DiagLog::writer, "whisper-log");
                t.setDaemon(true);
                t.setPriority(Thread.MIN_PRIORITY);
                t.start();
            }
        }
        log("=== " + what);
    }

    public static boolean on() { return on; }

    public static void log(String s) {
        if (!on) return;
        String t;
        synchronized (TIME) { t = TIME.format(new Date()); }
        synchronized (lock) {
            if (s.equals(lastLine)) { repeats++; return; }
            if (repeats > 0) { pending.append("  (the line before came ").append(repeats).append(" more times)\n"); repeats = 0; }
            lastLine = s;
            if (pending.length() > 1 << 20) return;               // the writer is stuck: drop rather than fill memory
            pending.append(t).append(' ').append(s).append('\n');
        }
    }

    private static File file() { return new File(dir, "hpc-whisper-log.txt"); }
    private static File oldFile() { return new File(dir, "hpc-whisper-log-old.txt"); }

    private static void writer() {
        while (true) {
            try { Thread.sleep(1000); } catch (InterruptedException e) { return; }
            flush();
        }
    }

    public static void flush() {
        String s;
        synchronized (lock) {
            if (pending.length() == 0) return;
            s = pending.toString();
            pending = new StringBuilder();
        }
        synchronized (DiagLog.class) {
            try {
                File f = file();
                if (f.length() > MAX) { File o = oldFile(); o.delete(); f.renameTo(o); }
                try (OutputStream o = new FileOutputStream(f, true)) { o.write(s.getBytes(StandardCharsets.UTF_8)); }
            } catch (IOException ignored) { }
        }
    }

    // ---------- the sound ----------

    /** The microphone's samples as read (frames of ch interleaved channels); keeps the first channel. */
    public static void mic(short[] buf, int frames, int ch, int rate) {
        if (!on || rate <= 0) return;
        synchronized (tapeLock) {
            if (tapeRate != rate) { tape = new short[rate * SOUND_S]; tapePos = 0; tapeRate = rate; }
            short[] t = tape;
            for (int i = 0; i < frames; i++) { t[(int) (tapePos % t.length)] = buf[i * ch]; tapePos++; }
            tapeEndMs = System.currentTimeMillis();
        }
    }

    /** The last 30 s as a WAV file's bytes, and when it ends (in the name of the entry). */
    private static byte[] wav(long[] endMs) {
        short[] pcm;
        int rate;
        synchronized (tapeLock) {
            short[] t = tape;
            int n = (int) Math.min(tapePos, t.length);
            pcm = new short[n];
            for (int i = 0; i < n; i++) pcm[i] = t[(int) ((tapePos - n + i) % t.length)];
            rate = tapeRate;
            endMs[0] = tapeEndMs;
        }
        ByteArrayOutputStream b = new ByteArrayOutputStream(44 + pcm.length * 2);
        int bytes = pcm.length * 2;
        writeStr(b, "RIFF"); writeInt(b, 36 + bytes); writeStr(b, "WAVE"); writeStr(b, "fmt ");
        writeInt(b, 16); writeShort(b, 1); writeShort(b, 1); writeInt(b, rate); writeInt(b, rate * 2); writeShort(b, 2); writeShort(b, 16);
        writeStr(b, "data"); writeInt(b, bytes);
        for (short v : pcm) writeShort(b, v);
        return b.toByteArray();
    }

    private static void writeStr(ByteArrayOutputStream b, String s) { for (int i = 0; i < s.length(); i++) b.write(s.charAt(i)); }
    private static void writeInt(ByteArrayOutputStream b, int v) { b.write(v); b.write(v >> 8); b.write(v >> 16); b.write(v >> 24); }
    private static void writeShort(ByteArrayOutputStream b, int v) { b.write(v); b.write(v >> 8); }

    /** Everything in one zip: the log (old part first), the last 30 s of sound, and what is written in about. */
    public static void zip(File out, String about) throws IOException {
        log("diagnostics shared");
        flush();
        long[] end = new long[1];
        byte[] w = wav(end);
        try (ZipOutputStream z = new ZipOutputStream(new FileOutputStream(out))) {
            z.putNextEntry(new ZipEntry("about.txt"));
            z.write(about.getBytes(StandardCharsets.UTF_8));
            z.closeEntry();
            synchronized (DiagLog.class) {
                for (File f : new File[]{oldFile(), file()}) {
                    if (!f.exists()) continue;
                    z.putNextEntry(new ZipEntry(f.getName()));
                    java.nio.file.Files.copy(f.toPath(), z);
                    z.closeEntry();
                }
            }
            String endName = new SimpleDateFormat("HH-mm-ss.SSS", Locale.US).format(new Date(end[0]));
            z.putNextEntry(new ZipEntry("last-30-seconds-ending-" + endName + ".wav"));
            z.write(w);
            z.closeEntry();
        }
    }

    /** Clears the log and the sound. */
    public static void clear() {
        synchronized (lock) { pending = new StringBuilder(); lastLine = ""; repeats = 0; }
        synchronized (DiagLog.class) { file().delete(); oldFile().delete(); }
        synchronized (tapeLock) { tapePos = 0; }
        log("log cleared");
    }
}
