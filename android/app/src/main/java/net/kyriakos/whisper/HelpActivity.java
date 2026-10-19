package net.kyriakos.whisper;

import android.content.Intent;
import android.net.Uri;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.core.content.FileProvider;

import java.io.File;
import android.os.Build;

import java.util.Locale;

/** Help: the handheld's keys, what to do when text goes missing, the iPhone page, privacy, and the log. */
public class HelpActivity extends BaseActivity {
    private static final String PAGE = "https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/";
    private TextView logState;

    @Override protected String title() { return "Help"; }

    private void row(LinearLayout c, String keys, String does) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setPadding(0, ui.dp(5), 0, 0);
        TextView k = ui.text(r, keys, 14, t().ink, true);
        k.setLayoutParams(new LinearLayout.LayoutParams(ui.dp(112), LinearLayout.LayoutParams.WRAP_CONTENT));
        TextView d = ui.text(r, does, 14, t().muted, false);
        d.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        c.addView(r);
    }

    @Override
    protected void build() {
        LinearLayout h = ui.card("On the handheld");
        ui.text(h, "Run whisper.exe from the HPC-Whisper download (an ARM Windows CE handheld such as the HP Jornada 720). "
                + "Hold the phone within a metre of the handheld, with the HPC Whisper keyboard open on the phone, and type. "
                + "The sound is too high to hear. Keep both programs at the same version.", 14, t().ink, false);

        LinearLayout k = ui.card("Keys on the handheld");
        row(k, "Letters, Enter", "Typed into the field");
        row(k, "Arrows", "Move the cursor; Shift selects, Ctrl jumps a word");
        row(k, "Home, End", "Start and end of the line; Ctrl for the whole text");
        row(k, "Backspace, Del", "Delete; Ctrl deletes a word");
        row(k, "Ctrl+A C X V", "Select all, Copy, Cut, Paste");
        row(k, "Ctrl+Z, Ctrl+Y", "Undo, Redo");
        row(k, "Tab, Shift+Tab", "Next field, previous field");
        row(k, "Esc", "Esc");
        row(k, "Alt+S", "Press Send in the app*");
        row(k, "Alt+B, H, W", "Back, Home screen, Recent apps*");
        row(k, "Alt+R", "Send the last text again");
        row(k, "Alt+N", "Start a new page");
        ui.body(k, "* needs the optional helper (turn it on in the phone's accessibility settings). Send also works in "
                + "search and one-line fields without it.").setPadding(0, ui.dp(8), 0, 0);

        LinearLayout m = ui.card("If text goes missing");
        ui.text(m, "Every piece of text is sent several times, a little later each time, on two different bands, so a piece "
                + "lost on the way fills in by itself. If the bar says \"Waiting for a missing piece\", wait a few seconds; if "
                + "it does not fill in, press Alt+R on the handheld to send the last text again. Move the phone closer if the "
                + "bar says \"Weak signal\". Text that is still missing after half a minute is given up, so it cannot hold up "
                + "what you type next; Last text on the main screen keeps a copy of everything that did arrive.", 14, t().ink, false);

        LinearLayout i = ui.card("iPhone, or any other phone");
        ui.text(i, "Apple does not let keyboards use the microphone, so an iPhone keyboard is impossible. On an iPhone (or "
                + "any other phone) use the receiver page in the browser, with Copy and Share:", 14, t().ink, false);
        TextView pg = ui.text(i, PAGE, 14, t().link, false);
        pg.setPadding(0, ui.dp(6), 0, 0);
        pg.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(PAGE))));

        LinearLayout p = ui.card("Privacy");
        ui.text(p, "This app has no internet access. The microphone is used only while the HPC Whisper keyboard is open, and "
                + "what it hears is read on the phone and not kept, apart from the last 30 seconds that go into the log "
                + "below, which stays on the phone until you share it. If another app is using the microphone (a call), "
                + "the handheld cannot be heard until it is free.", 14, t().ink, false);

        LinearLayout d = ui.card("Log for troubleshooting");
        logState = ui.body(d, "A record of what the phone heard, with the last 30 seconds of sound. Share it if something "
                + "does not work.");
        ui.button(d, "Share the log", true, v -> shareLog());
        ui.button(d, "Clear the log", false, v -> { DiagLog.clear(); logState.setText("The log is cleared: it starts again from here."); });

        LinearLayout a = ui.card("About");
        ui.text(a, "HPC Whisper joins a Windows CE handheld PC, such as the HP Jornada 720, to this phone: what you type on "
                + "the handheld appears in any app on the phone. Created by Kyriakos Christodoulou.", 14, t().ink, false);
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
