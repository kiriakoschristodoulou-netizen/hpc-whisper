package net.kyriakos.whisper;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Everything that came from the handheld, kept on the phone only (the app's
 * private storage) so that text typed into a field that then closed is not
 * lost. One session is one time the keyboard was open in an app; the app and
 * the date are kept with it. The newest sessions are kept (the number is a
 * setting, never fewer than 10).
 */
public final class Sessions {
    private Sessions() { }

    public static final class Item {
        public long start;
        public String app = "";
        public String text = "";
        public String when() { return new SimpleDateFormat("EEE d MMM, HH:mm", Locale.getDefault()).format(new Date(start)); }
        public String title() { return (app.isEmpty() ? "Unknown app" : app) + " · " + when(); }
    }

    private static long curStart = 0, lastWrite = 0;
    private static String curApp = "";
    private static int curDoc = -2, off = 0;
    private static final StringBuilder base = new StringBuilder();
    private static String page = "";
    private static boolean dirty = false;
    private static int version = 0;

    /** Changes whenever something was saved or deleted. */
    public static synchronized int version() { return version; }

    private static File dir(Context c) {
        File d = new File(c.getFilesDir(), "sessions");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private static String label(Context c, String pkg) {
        if (pkg == null || pkg.isEmpty()) return "";
        try {
            PackageManager pm = c.getPackageManager();
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            return String.valueOf(pm.getApplicationLabel(ai));
        } catch (Exception e) { return pkg; }
    }

    /** The keyboard opened in a field of this app: the text that comes now is a new session. */
    public static synchronized void begin(Context c, String pkg, Mirror m) {
        flush(c);
        curStart = 0;
        curApp = label(c, pkg);
        base.setLength(0);
        page = "";
        dirty = false;
        if (m.doc >= 0) { curDoc = m.doc; off = m.L; } else { curDoc = -2; off = 0; }
    }

    /** Text arrived (the shared copy has changed). */
    public static synchronized void update(Context c, Mirror m) {
        if (!Prefs.keepHistory(c) || m.L == 0 && m.doc == curDoc) return;
        long now = System.currentTimeMillis();
        if (m.doc != curDoc) {
            if (curDoc != -2 && !page.isEmpty()) base.append(page).append('\n');
            curDoc = m.doc; off = 0;
        }
        String raw = m.text(Math.min(off, m.L), m.L, "·");
        page = Prefs.keyLabels(c) ? Keys.show(raw) : strip(raw);
        if (curStart == 0) {
            if (page.isEmpty() && base.length() == 0) return;
            curStart = now;
        }
        dirty = true;
        if (now - lastWrite >= 2000) flush(c);
    }

    private static String strip(String s) {
        StringBuilder o = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) { char ch = s.charAt(i); if (Keys.keyOf(ch) < 0) o.append(ch); }
        return o.toString();
    }

    public static synchronized void end(Context c) { flush(c); }

    private static void flush(Context c) {
        if (!dirty || curStart == 0) return;
        dirty = false;
        lastWrite = System.currentTimeMillis();
        version++;
        String all = base.toString() + page;
        if (all.length() > 200000) all = all.substring(all.length() - 200000);
        try (FileOutputStream o = new FileOutputStream(new File(dir(c), curStart + ".txt"))) {
            o.write((curApp + "\n" + all).getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
        trim(c);
    }

    private static void trim(Context c) {
        File[] fs = dir(c).listFiles();
        if (fs == null) return;
        int keep = Prefs.sessions(c);
        if (fs.length <= keep) return;
        Arrays.sort(fs, (a, b) -> a.getName().compareTo(b.getName()));        // same length digits: oldest first
        for (int i = 0; i < fs.length - keep; i++) fs[i].delete();
    }

    /** The saved sessions, newest first. Text is read only when asked for it (full = true). */
    public static synchronized List<Item> list(Context c, boolean full) {
        flush(c);
        List<Item> out = new ArrayList<>();
        File[] fs = dir(c).listFiles();
        if (fs == null) return out;
        for (File f : fs) {
            try {
                Item it = new Item();
                it.start = Long.parseLong(f.getName().replace(".txt", ""));
                byte[] b = new byte[(int) Math.min(f.length(), 400000)];
                try (FileInputStream in = new FileInputStream(f)) {
                    int n = 0, r;
                    while (n < b.length && (r = in.read(b, n, b.length - n)) > 0) n += r;
                }
                String s = new String(b, StandardCharsets.UTF_8);
                int nl = s.indexOf('\n');
                it.app = nl < 0 ? s : s.substring(0, nl);
                it.text = nl < 0 ? "" : s.substring(nl + 1);
                out.add(it);
            } catch (Exception ignored) { }
        }
        Collections.sort(out, (a, b) -> Long.compare(b.start, a.start));
        return out;
    }

    public static synchronized void delete(Context c, long start) {
        if (start == curStart) { curStart = 0; base.setLength(0); page = ""; dirty = false; }
        new File(dir(c), start + ".txt").delete();
        version++;
    }

    public static synchronized void clearAll(Context c) {
        curStart = 0; base.setLength(0); page = ""; dirty = false;
        File[] fs = dir(c).listFiles();
        if (fs != null) for (File f : fs) f.delete();
        version++;
    }

    public static int count(Context c) {
        String[] n = dir(c).list();
        return n == null ? 0 : n.length;
    }
}
