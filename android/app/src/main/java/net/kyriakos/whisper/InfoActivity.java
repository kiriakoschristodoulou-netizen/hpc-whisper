package net.kyriakos.whisper;

import android.content.Intent;
import android.net.Uri;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Info and help: each part is a box that opens when tapped. */
public class InfoActivity extends BaseActivity {
    private static final String PAGE = "https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/";

    @Override protected String title() { return "Info and help"; }

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

    private LinearLayout box(String title) {
        return ui.fold(ui.card(null), title, null);
    }

    @Override
    protected void build() {
        LinearLayout h = box("How it works");
        ui.text(h, "Run HPCWhisper.exe on the handheld (an ARM Windows CE handheld such as the HP Jornada 720). Hold the phone "
                + "within a metre of the handheld, with the HPC Whisper keyboard open in any app, and type on the handheld. "
                + "The text travels as sound too high to hear.", 14, t().ink, false).setPadding(0, ui.dp(6), 0, 0);

        LinearLayout k = box("Keys on the handheld");
        row(k, "Letters, Enter", "Typed into the field");
        row(k, "Arrows", "Move the cursor; Shift selects, Ctrl jumps a word");
        row(k, "Home, End", "Start and end of the line; Ctrl for the whole text");
        row(k, "Backspace, Del", "Delete; Ctrl deletes a word");
        row(k, "Ctrl+A C X V", "Select all, Copy, Cut, Paste");
        row(k, "Ctrl+Z, Ctrl+Y", "Undo, Redo");
        row(k, "Tab, Esc", "Next field (Shift: previous), Esc");
        row(k, "Alt+S", "Press Send in the app*");
        row(k, "Alt+B, H, W", "Back, Home screen, Recent apps*");
        row(k, "Alt+R", "Send the last text again");
        row(k, "Alt+N", "Start a new page");
        ui.body(k, "* needs the Send button and phone keys helper (Set up, on the home screen). Send also works in search and "
                + "one-line fields without it.").setPadding(0, ui.dp(8), 0, 0);

        LinearLayout m = box("If text goes missing");
        ui.text(m, "Every piece of text is sent several times, a little later each time, on two different bands, so a piece "
                + "lost on the way fills in by itself. If the keyboard says \"Waiting for a missing piece\", wait a few seconds; "
                + "if it does not fill in, press Alt+R on the handheld. Move the phone closer if it says \"Weak signal\". "
                + "Text still missing after half a minute is given up so it cannot hold up what you type next. Everything that "
                + "did arrive is kept under Sessions.", 14, t().ink, false).setPadding(0, ui.dp(6), 0, 0);

        LinearLayout i = box("iPhone, or any other phone");
        ui.text(i, "Apple does not let keyboards use the microphone, so an iPhone keyboard is impossible. On an iPhone, or any "
                + "other phone, use the receiver page in the browser, with Copy and Share:", 14, t().ink, false).setPadding(0, ui.dp(6), 0, 0);
        TextView pg = ui.text(i, PAGE, 14, t().link, false);
        pg.setPadding(0, ui.dp(6), 0, 0);
        pg.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(PAGE))));

        LinearLayout p = box("Privacy");
        ui.text(p, "This app has no internet access. The microphone is used only while the HPC Whisper keyboard is open, and "
                + "what it hears is read on the phone and not kept, apart from the last 30 seconds in the troubleshooting log "
                + "(Settings), which stays on the phone until you share it. Saved sessions are on the phone only; you can turn "
                + "them off or delete them in Settings. If another app is using the microphone (a call), the handheld cannot "
                + "be heard until it is free.", 14, t().ink, false).setPadding(0, ui.dp(6), 0, 0);

        LinearLayout a = box("About");
        ui.text(a, "HPC Whisper joins a Windows CE handheld PC, such as the HP Jornada 720, to this phone: what you type on "
                + "the handheld appears in any app on the phone. Created by Kyriakos Christodoulou.", 14, t().ink, false).setPadding(0, ui.dp(6), 0, 0);
        TextView src = ui.text(a, "github.com/kiriakoschristodoulou-netizen/hpc-whisper", 14, t().link, false);
        src.setPadding(0, ui.dp(6), 0, 0);
        src.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/kiriakoschristodoulou-netizen/hpc-whisper"))));
    }
}
