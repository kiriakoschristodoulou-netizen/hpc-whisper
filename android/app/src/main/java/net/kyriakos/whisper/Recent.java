package net.kyriakos.whisper;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * A safety copy of the last text that arrived from the handheld, kept in the
 * app's private storage (nobody else can read it), so that text typed into a
 * field that then closed is not lost. Shown, and can be copied, in the app.
 * Written at most every two seconds.
 */
public final class Recent {
    private static final String FILE = "recent.txt";
    private static final int KEEP = 20000;          // characters
    private static long lastWrite = 0;
    private static String pending;

    private Recent() { }

    public static void add(Context c, Mirror m) {
        if (m == null || m.L == 0) return;
        pending = Keys.show(m.text(0, m.L, "·"));
        long now = System.currentTimeMillis();
        if (now - lastWrite < 2000) return;
        flush(c);
    }

    public static synchronized void flush(Context c) {
        String s = pending;
        if (s == null) return;
        pending = null;
        lastWrite = System.currentTimeMillis();
        if (s.length() > KEEP) s = s.substring(s.length() - KEEP);
        try (FileOutputStream o = new FileOutputStream(new File(c.getFilesDir(), FILE))) {
            o.write(s.getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
    }

    public static String get(Context c) {
        if (pending != null) return pending;
        File f = new File(c.getFilesDir(), FILE);
        if (!f.exists()) return "";
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[(int) Math.min(f.length(), 200000)];
            int n = 0, r;
            while (n < b.length && (r = in.read(b, n, b.length - n)) > 0) n += r;
            return new String(b, 0, n, StandardCharsets.UTF_8);
        } catch (Exception e) { return ""; }
    }

    public static void clear(Context c) {
        pending = null;
        new File(c.getFilesDir(), FILE).delete();
    }
}
