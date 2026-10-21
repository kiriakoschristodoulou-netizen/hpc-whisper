package net.kyriakos.whisper;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.core.content.FileProvider;

import java.io.File;
import java.util.Locale;

/** Settings. The tip box is always on top. */
public class SettingsActivity extends BaseActivity {
    private static final String TIP = "https://www.paypal.com/paypalme/byinnovodesign";
    private TextView logState, histState;

    @Override protected String title() { return "Settings"; }

    @Override
    protected void build() {
        // a tip, always here
        LinearLayout tip = ui.card(null);
        ui.text(tip, "🍺  Buy me a beer", 18, t().ink, true);
        ui.body(tip, "A tip will be appreciated. The app is free and has no ads.").setPadding(0, ui.dp(4), 0, 0);
        ui.button(tip, "Tip with PayPal", true, v -> {
            try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(TIP))); } catch (Exception ignored) { }
        });

        LinearLayout h = ui.fold(ui.card(null), "Saved sessions", null);
        ui.toggle(h, "Keep what arrives", "Saved on this phone only", Prefs.keepHistory(this), v -> Prefs.keepHistory(this, v));
        int[] counts = {10, 25, 50, 100};
        int sel = 1;
        for (int i = 0; i < counts.length; i++) if (counts[i] == Prefs.sessions(this)) sel = i;
        String[] names = {"10", "25", "50", "100"};
        ui.choice(h, "Sessions to keep", "The newest are kept (at least 10)", names, sel, i -> Prefs.sessions(this, counts[i]));
        ui.toggle(h, "Show keys in saved text", "Like [Left] or [Ctrl+C]", Prefs.keyLabels(this), v -> Prefs.keyLabels(this, v));
        histState = ui.body(h, "");
        histState.setPadding(0, ui.dp(8), 0, 0);
        ui.button(h, "Delete all sessions", false, v -> { Sessions.clearAll(this); histState.setText("All sessions deleted."); });

        LinearLayout k = ui.fold(ui.card(null), "Keyboard", null);
        ui.toggle(k, "Edit keys on the keyboard", "Arrows, select, copy, paste, undo", Prefs.editKeys(this), v -> Prefs.editKeys(this, v));
        ui.toggle(k, "Keep the screen on", "While the keyboard is open", Prefs.screenOn(this), v -> Prefs.screenOn(this, v));
        ui.toggle(k, "Buzz when text arrives", "After a pause of a few seconds", Prefs.cue(this), v -> Prefs.cue(this, v));

        ui.toggle(k, "Confirm to the handheld", "A silent sound (above 19 kHz) tells it what arrived, so it stops repeating", Prefs.returnChannel(this), v -> Prefs.returnChannel(this, v));

        LinearLayout a = ui.fold(ui.card(null), "Look", null);
        String[] themes = {"As the phone", "Light", "Dark"};
        ui.choice(a, "Theme", null, themes, Prefs.theme(this), i -> { Prefs.theme(this, i); recreate(); });

        LinearLayout d = ui.fold(ui.card(null), "Troubleshooting", null);
        logState = ui.body(d, "A record of what the phone heard, with the last 30 seconds of sound. Share it if something does not work.");
        logState.setPadding(0, ui.dp(6), 0, 0);
        ui.button(d, "Share the log", true, v -> shareLog());
        ui.button(d, "Clear the log", false, v -> { DiagLog.clear(); logState.setText("The log is cleared: it starts again from here."); });

        LinearLayout v = ui.card(null);
        ui.text(v, "HPC Whisper " + version(), 15, t().ink, true);
        ui.body(v, "Created by Kyriakos Christodoulou");
    }

    private String version() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception e) { return ""; }
    }

    private void shareLog() {
        if (!DiagLog.on()) { logState.setText("Nothing logged yet: use the keyboard first."); return; }
        try {
            String name = "HPC-Whisper-log-" + new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new java.util.Date()) + ".zip";
            File f = new File(getCacheDir(), name);
            DiagLog.zip(f, "HPC Whisper log, " + Build.MODEL);
            Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", f);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("application/zip");
            i.putExtra(Intent.EXTRA_STREAM, uri);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "Share the log"));
        } catch (Exception e) { logState.setText("The log could not be shared: " + e.getMessage()); }
    }
}
