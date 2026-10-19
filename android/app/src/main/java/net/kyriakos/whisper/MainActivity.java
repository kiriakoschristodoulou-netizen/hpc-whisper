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

/**
 * HPC Whisper: the app's one screen. It gets the phone ready (the microphone,
 * the keyboard), lets you try it, and keeps a copy of the last text that came
 * from the handheld. The typing itself happens in the keyboard, in any app.
 * Created by Kyriakos Christodoulou. No internet: nothing leaves the phone.
 */
public class MainActivity extends BaseActivity {
    private View heroDot;
    private TextView heroTitle, heroText, micState, kbState, pickState, helperState, recentText;
    private LinearLayout recentCard;
    private Button micBtn, kbBtn, pickBtn;
    private String shownRecent = null;

    @Override protected String title() { return null; }

    @Override
    protected void build() {
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
        ui.text(ht, "Type on your handheld PC, into any app · " + version(), 13, t().muted, false);
        head.addView(ht);
        root.addView(head);

        // how it is, in one glance
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
        heroText = ui.body(hero, "");
        heroText.setPadding(0, ui.dp(6), 0, 0);

        LinearLayout setup = ui.card("Set up, once");
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
        ui.body(setup, "Lets the handheld press Send in chat apps and go Back, Home or to Recent apps. It acts only on what you "
                + "ask from the handheld and reads nothing. Typing works without it.");
        ui.button(setup, "Open accessibility settings", false, v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));

        LinearLayout tryIt = ui.card("Try it");
        ui.body(tryIt, "Tap the box, switch to HPC Whisper, hold the phone near the handheld and type on it. New text is "
                + "underlined for a moment while it can still change.");
        EditText box = new EditText(this);
        box.setMinLines(3);
        box.setGravity(Gravity.TOP);
        box.setTextColor(t().ink);
        box.setHintTextColor(t().muted);
        box.setHint("Text from the handheld appears here");
        tryIt.addView(box);

        recentCard = ui.card("Last text from the handheld");
        ui.body(recentCard, "A copy kept only on this phone, in case it went into a field that closed.");
        recentText = ui.text(recentCard, "", 14, t().ink, false);
        recentText.setTypeface(Typeface.MONOSPACE);
        recentText.setTextIsSelectable(true);
        recentText.setPadding(0, ui.dp(8), 0, 0);
        ui.button(recentCard, "Copy", false, v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cm != null) { cm.setPrimaryClip(ClipData.newPlainText("HPC Whisper", Recent.get(this))); Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show(); }
        });

        ui.button(root, "Handheld keys, help and privacy", false, v -> startActivity(new Intent(this, HelpActivity.class)));
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) refresh();
    }

    @Override
    protected void refresh() {
        if (heroTitle == null) return;
        boolean mic = hasMic(), enabled = keyboardOn(), chosen = keyboardChosen(this);
        step(micState, micBtn, mic, "✓ Allowed", "Needed to hear the handheld");
        step(kbState, kbBtn, enabled, "✓ On", "Turn on \"HPC Whisper\" in the list");
        if (chosen) { pickState.setText("✓ HPC Whisper is the keyboard now"); pickState.setTextColor(t().green); }
        else { pickState.setText("Switch whenever you want to type on the handheld"); pickState.setTextColor(t().muted); }
        pickBtn.setVisibility(enabled ? View.VISIBLE : View.GONE);
        helperState.setText(Helper.on() ? "✓ On" : "Off: typing works without it");
        helperState.setTextColor(Helper.on() ? t().green : t().muted);

        int left = (mic ? 0 : 1) + (enabled ? 0 : 1);
        if (left == 0) {
            dot(t().green);
            heroTitle.setText("Ready");
            heroText.setText(chosen ? "Open any app, tap a text field and type on the handheld."
                    : "Open any app, tap a text field, switch to the HPC Whisper keyboard and type on the handheld.");
        } else {
            dot(t().warn);
            heroTitle.setText(left == 1 ? "One step left" : "Two steps left");
            heroText.setText("Follow the steps below; this takes a minute.");
        }
        String rt = Recent.get(this);
        recentCard.setVisibility(rt.isEmpty() ? View.GONE : View.VISIBLE);
        if (!rt.equals(shownRecent)) { shownRecent = rt; recentText.setText(rt.length() > 400 ? "…" + rt.substring(rt.length() - 400) : rt); }
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
