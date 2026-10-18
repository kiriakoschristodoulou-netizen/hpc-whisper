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
 * The phone's diagnostics: every event of the link as one line with the time of day (to the millisecond), in
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

    private static File file() { return new File(dir, "whisper-tools-log.txt"); }
    private static File oldFile() { return new File(dir, "whisper-tools-log-old.txt"); }

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

    // ---------- messages in words ----------

    public static String chan(int ch) {
        switch (ch) {
            case net.kyriakos.whisper.w3.Channel.SU_NARROW: return "SU";
            case net.kyriakos.whisper.w3.Channel.SU_WIDE: return "SUW";
            case net.kyriakos.whisper.w3.Channel.SD: return "SD";
            case net.kyriakos.whisper.w3.Channel.FU: return "FU";
            case net.kyriakos.whisper.w3.Channel.FD: return "FD";
            default: return "ch" + ch;
        }
    }

    private static int w16(byte[] p, int i) { return ((p[i] & 255) << 8) | (p[i + 1] & 255); }

    /** A message of format 3, in words: its type, length and what matters in it. */
    public static String describe(int type, byte[] p) {
        int n = p == null ? 0 : p.length;
        StringBuilder s = new StringBuilder();
        switch (type) {
            case 0x01:
                s.append("TEXT");
                if (n >= 6) {
                    s.append(" doc ").append(p[0] & 255).append(" seq ").append(p[1] & 255).append(" length ").append(w16(p, 2))
                            .append(" from ").append(w16(p, 4)).append(" \"");
                    for (int i = 6; i < n; i++) {
                        int c = p[i] & 255;
                        if (c >= 32 && c < 127 && c != '"') s.append((char) c); else s.append('<').append(c).append('>');
                    }
                    s.append('"');
                }
                break;
            case 0x02: s.append("TEXT_ACK"); if (n >= 5) s.append(" doc ").append(p[0] & 255).append(" known ").append(w16(p, 1)).append(" of length ").append(w16(p, 3)); break;
            case 0x10:
                s.append("FILE_OFFER");
                if (n >= 9) s.append(" id ").append(w16(p, 0)).append(" size ").append(((p[2] & 255) << 24) | ((p[3] & 255) << 16) | ((p[4] & 255) << 8) | (p[5] & 255))
                        .append(" packets ").append(w16(p, 6)).append(" kind ").append(p[8] & 255);
                break;
            case 0x11: s.append("FILE_DATA"); if (n >= 4) s.append(" id ").append(w16(p, 0)).append(" packet ").append(w16(p, 2)).append(" bytes ").append(n - 4); break;
            case 0x12:
                s.append("FILE_NEED");
                if (n >= 5) {
                    s.append(" id ").append(w16(p, 0)).append(" flag ").append(p[2] & 255).append(" have ").append(w16(p, 3)).append(" missing ").append((n - 5) / 2);
                    for (int i = 5, k = 0; i + 1 < n && k < 8; i += 2, k++) s.append(k == 0 ? ": " : " ").append(w16(p, i));
                    if ((n - 5) / 2 > 8) s.append(" ...");
                }
                break;
            case 0x13: s.append("FILE_CANCEL"); if (n >= 2) s.append(" id ").append(w16(p, 0)); break;
            case 0x20: s.append("SCREEN"); break;
            case 0x21: s.append("INPUT"); if (n >= 1) s.append(" kind ").append(p[0] & 255); break;
            case 0x30: s.append("TRAIN"); break;
            case 0x31: s.append("MAP"); if (n >= 2) s.append(" ch ").append(p[0] & 255).append(" number ").append(p[1] & 255); break;
            case 0x32: s.append("HELLO"); if (n >= 4) s.append(" version ").append(p[0] & 255).append(" reply ").append(p[3] & 1); break;
            case 0x33: s.append("CHECK"); if (n >= 1) s.append(" ch ").append(chan(p[0] & 255)); break;
            case 0x34: s.append("PAIR_REPORT"); if (n >= 40) s.append(" scale ").append(w16(p, 34)).append(" ladder ").append((p[38] & 255) - 1).append(" quality ").append((p[39] & 255) - 20).append(" dB"); break;
            case 0x35: s.append("SELFTEST"); if (n >= 3) s.append(" stage ").append(p[1] & 255).append(" number ").append(p[2] & 255); break;
            default: s.append("type 0x").append(Integer.toHexString(type));
        }
        return s.append(" (").append(n).append(" bytes)").toString();
    }

    public static String typeName(int type) {
        String d = describe(type, new byte[0]);
        return d.substring(0, d.indexOf(" ("));
    }
}
