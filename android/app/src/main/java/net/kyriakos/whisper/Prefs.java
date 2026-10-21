package net.kyriakos.whisper;

import android.content.Context;
import android.content.SharedPreferences;

/** The app's few settings, kept on the phone. */
public final class Prefs {
    private Prefs() { }

    public static final int MIN_SESSIONS = 10, MAX_SESSIONS = 100;

    private static SharedPreferences p(Context c) { return c.getApplicationContext().getSharedPreferences("hpc", Context.MODE_PRIVATE); }

    public static boolean keepHistory(Context c) { return p(c).getBoolean("history", true); }
    public static void keepHistory(Context c, boolean v) { p(c).edit().putBoolean("history", v).apply(); }

    public static int sessions(Context c) { return Math.max(MIN_SESSIONS, Math.min(MAX_SESSIONS, p(c).getInt("sessions", 25))); }
    public static void sessions(Context c, int v) { p(c).edit().putInt("sessions", Math.max(MIN_SESSIONS, Math.min(MAX_SESSIONS, v))).apply(); }

    public static boolean keyLabels(Context c) { return p(c).getBoolean("keylabels", true); }
    public static void keyLabels(Context c, boolean v) { p(c).edit().putBoolean("keylabels", v).apply(); }

    public static boolean cue(Context c) { return p(c).getBoolean("cue", false); }
    public static void cue(Context c, boolean v) { p(c).edit().putBoolean("cue", v).apply(); }

    public static boolean screenOn(Context c) { return p(c).getBoolean("screenon", true); }
    public static void screenOn(Context c, boolean v) { p(c).edit().putBoolean("screenon", v).apply(); }

    public static boolean editKeys(Context c) { return p(c).getBoolean("editkeys", true); }
    public static void editKeys(Context c, boolean v) { p(c).edit().putBoolean("editkeys", v).apply(); }

    /** Tell the handheld, silently, what has arrived (the return channel). */
    public static boolean returnChannel(Context c) { return p(c).getBoolean("return", true); }
    public static void returnChannel(Context c, boolean v) { p(c).edit().putBoolean("return", v).apply(); }

    /** 0 = as the phone is set, 1 = light, 2 = dark. */
    public static int theme(Context c) { return p(c).getInt("theme", 0); }
    public static void theme(Context c, int v) { p(c).edit().putInt("theme", v).apply(); }
}
