package net.kyriakos.whisper;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/**
 * HPC Whisper: the app's home. A few boxes, each with little text: how ready
 * the phone is (green icons for what is on), the last text from the handheld,
 * the saved sessions, a box to try it in, and the Info and Settings pages.
 * The typing itself happens in the keyboard, in any app. No internet.
 */
public class MainActivity extends BaseActivity {
    private View heroDot;
    private TextView heroTitle, setupNote, micState, kbState, pickState, helperState;
    private TextView lampMic, lampKb, lampPick, lampHelper;
    private Button micBtn, kbBtn, pickBtn;
    private LinearLayout lastCard, lastBody, sessionsBody;
    private TextView lastText, lastNote, sessionsNote;
    private boolean builtDark;
    private int seenVersion = -1;

    @Override protected String title() { return null; }

    @Override
    protected void build() {
        builtDark = Theme.dark(this);
        LinearLayout root = ui.root;
        root.setPadding(ui.dp(16), ui.dp(16), ui.dp(16), ui.dp(28));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.ic_launcher);
        head.addView(icon, new LinearLayout.LayoutParams(ui.dp(52), ui.dp(52)));
        LinearLayout ht = new LinearLayout(this);
        ht.setOrientation(LinearLayout.VERTICAL);
        ht.setPadding(ui.dp(14), 0, 0, 0);
        ui.text(ht, "HPC Whisper", 24, t().ink, true);
        ui.text(ht, "Version " + version(), 13, t().muted, false);
        head.addView(ht);
        root.addView(head);

        // 1. how ready the phone is: green icons for what is on; the steps stay hidden until tapped
        LinearLayout hero = ui.card(null);
        LinearLayout hr = new LinearLayout(this);
        hr.setOrientation(LinearLayout.HORIZONTAL);
        hr.setGravity(Gravity.CENTER_VERTICAL);
        heroDot = new View(this);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(ui.dp(14), ui.dp(14));
        dlp.rightMargin = ui.dp(12);
        hr.addView(heroDot, dlp);
        heroTitle = ui.text(hr, "", 18, t().ink, true);
        hero.addView(hr);
        LinearLayout icons = new LinearLayout(this);
        icons.setOrientation(LinearLayout.HORIZONTAL);
        icons.setPadding(0, ui.dp(12), 0, ui.dp(2));
        lampMic = ui.statusIcon(icons, "🎤", "Microphone");
        lampKb = ui.statusIcon(icons, "⌨", "Keyboard on");
        lampPick = ui.statusIcon(icons, "✓", "In use");
        lampHelper = ui.statusIcon(icons, "➤", "Send keys");
        hero.addView(icons);
        LinearLayout setup = ui.fold(hero, "Set up", null);
        setupNote = ui.noteOf(setup);
        micState = ui.step(setup, "1", "Allow the microphone");
        micBtn = ui.button(setup, "Allow the microphone", false, v -> askMic(this::refresh));
        kbState = ui.step(setup, "2", "Turn on the HPC Whisper keyboard");
        kbBtn = ui.button(setup, "Open keyboard settings", false, v -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        pickState = ui.step(setup, "3", "Switch to it when you want to type");
        pickBtn = ui.button(setup, "Choose keyboard", false, v -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        });
        helperState = ui.step(setup, "+", "Send button and phone keys (optional)");
        ui.body(setup, "Android does not let a keyboard press buttons in other apps. If you turn this on, the handheld can press Send "
                + "in chat apps (Alt+S) and go Back (Alt+B), Home (Alt+H) or to Recent apps (Alt+W). Typing works without it.\n\n"
                + "1. Tap the button below.\n2. In the list, tap \"HPC Whisper\" (it may be under Installed apps).\n"
                + "3. Switch it on and confirm. Nothing else is read or changed.").setPadding(0, ui.dp(6), 0, 0);
        ui.button(setup, "Open accessibility settings", false, v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));

        // 2. the last text, hidden until you ask
        lastCard = ui.card(null);
        lastBody = ui.fold(lastCard, "Last text", "");
        lastNote = ui.noteOf(lastBody);
        lastText = ui.text(lastBody, "", 14, t().ink, false);
        lastText.setTypeface(Typeface.MONOSPACE);
        lastText.setTextIsSelectable(true);
        lastText.setPadding(0, ui.dp(8), 0, 0);
        ui.button(lastBody, "Copy", false, v -> copy(lastText.getText().toString()));
        ui.button(lastBody, "Share", false, v -> share(lastText.getText().toString()));

        // 3. every session, with its app and date
        LinearLayout sCard = ui.card(null);
        sessionsBody = ui.fold(sCard, "Sessions", "");
        sessionsNote = ui.noteOf(sessionsBody);

        // 4. a place to try it
        LinearLayout tryCard = ui.card(null);
        LinearLayout tryBody = ui.fold(tryCard, "Try it here", null);
        EditText box = new EditText(this);
        box.setMinLines(3);
        box.setGravity(Gravity.TOP);
        box.setTextColor(t().ink);
        box.setHintTextColor(t().muted);
        box.setHint("Tap, switch to HPC Whisper, and type on the handheld");
        tryBody.addView(box);

        // 5, 6. the other two pages
        pageLink("Info and help", "Keys, missing text, privacy", InfoActivity.class);
        pageLink("Settings", "History, keyboard, theme, tip", SettingsActivity.class);
    }

    private void pageLink(String title, String note, Class<?> to) {
        LinearLayout c = ui.card(null);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(ui.dp(36));
        TextView h = ui.text(row, title, 17, t().ink, true);
        h.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        ui.text(row, note, 13, t().muted, false).setPadding(0, 0, ui.dp(10), 0);
        ui.text(row, "›", 22, t().muted, false);
        c.addView(row);
        c.setOnClickListener(v -> startActivity(new Intent(this, to)));
        row.setOnClickListener(v -> startActivity(new Intent(this, to)));
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) refresh();
    }

    @Override
    protected void refresh() {
        if (heroTitle == null) return;
        if (Theme.dark(this) != builtDark) { recreate(); return; }
        boolean mic = hasMic(), enabled = keyboardOn(), chosen = keyboardChosen(this), helper = Helper.on();
        step(micState, micBtn, mic, "✓ Allowed", "Needed to hear the handheld");
        step(kbState, kbBtn, enabled, "✓ On", "Turn on \"HPC Whisper\" in the list");
        if (chosen) { pickState.setText("✓ HPC Whisper is the keyboard now"); pickState.setTextColor(t().green); }
        else { pickState.setText("Switch whenever you want to type on the handheld"); pickState.setTextColor(t().muted); }
        pickBtn.setVisibility(enabled ? View.VISIBLE : View.GONE);
        helperState.setText(helper ? "✓ On" : "Off: typing works without it");
        helperState.setTextColor(helper ? t().green : t().muted);
        ui.lamp(lampMic, mic); ui.lamp(lampKb, enabled); ui.lamp(lampPick, chosen); ui.lamp(lampHelper, helper);

        int left = (mic ? 0 : 1) + (enabled ? 0 : 1);
        dot(left == 0 ? t().green : t().warn);
        heroTitle.setText(left == 0 ? "Ready" : "Set up needed");
        setupNote.setText(left == 0 ? "" : "tap to open");
        setupNote.setTextColor(t().warn);

        int v = Sessions.version();
        if (v != seenVersion) { seenVersion = v; showSessions(); }
    }

    private void showSessions() {
        List<Sessions.Item> all = Sessions.list(this, true);
        lastCard.setVisibility(all.isEmpty() ? View.GONE : View.VISIBLE);
        if (!all.isEmpty()) {
            Sessions.Item it = all.get(0);
            lastText.setText(it.text.length() > 20000 ? "…" + it.text.substring(it.text.length() - 20000) : it.text);
            lastNote.setText(it.when() + " · " + it.text.length());
        }
        sessionsNote.setText(all.isEmpty() ? "none yet" : all.size() + " saved");
        sessionsBody.removeAllViews();
        if (all.isEmpty()) { ui.body(sessionsBody, "Text from the handheld is saved here, with the app and the date."); return; }
        for (Sessions.Item it : all) sessionRow(it);
    }

    private void sessionRow(Sessions.Item it) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(0, ui.dp(10), 0, ui.dp(6));
        TextView title = ui.text(row, it.title(), 15, t().ink, true);
        ui.text(row, it.text.length() + " characters", 13, t().muted, false);
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setVisibility(View.GONE);
        TextView tx = ui.text(body, it.text, 14, t().ink, false);
        tx.setTypeface(Typeface.MONOSPACE);
        tx.setTextIsSelectable(true);
        tx.setPadding(0, ui.dp(8), 0, 0);
        ui.button(body, "Copy", false, v -> copy(it.text));
        ui.button(body, "Share", false, v -> share(it.text));
        ui.button(body, "Delete", false, v -> { Sessions.delete(this, it.start); showSessions(); });
        row.addView(body);
        View.OnClickListener open = v -> body.setVisibility(body.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE);
        title.setOnClickListener(open);
        row.setOnClickListener(open);
        GradientDrawable line = new GradientDrawable();
        line.setColor(t().line);
        sessionsBody.addView(row);
        View div = new View(this);
        div.setBackground(line);
        sessionsBody.addView(div, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1));
    }

    private void copy(String s) {
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        if (cm != null) { cm.setPrimaryClip(ClipData.newPlainText("HPC Whisper", s)); Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show(); }
    }

    private void share(String s) {
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TEXT, s);
        startActivity(Intent.createChooser(i, "Share"));
    }

    private void step(TextView state, Button b, boolean done, String yes, String no) {
        state.setText(done ? yes : no);
        state.setTextColor(done ? t().green : t().warn);
        b.setVisibility(done ? View.GONE : View.VISIBLE);
    }

    private void dot(int color) {
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(color);
        heroDot.setBackground(g);
    }

    private boolean keyboardOn() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList()) if (i.getPackageName().equals(getPackageName())) return true;
        return false;
    }

    static boolean keyboardChosen(android.content.Context c) {
        String current = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
        return current != null && current.startsWith(c.getPackageName());
    }

    private String version() {
        try { PackageInfo p = getPackageManager().getPackageInfo(getPackageName(), 0); return p.versionName; }
        catch (Exception e) { return ""; }
    }
}
