package net.kyriakos.whisper;

import android.content.Intent;
import android.provider.Settings;
import android.view.Gravity;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** The keyboard: setting it up (microphone, turning it on, choosing it, the optional helper) and trying it. */
public class KeyboardActivity extends ToolActivity {
    private TextView micState, kbState, pickState, helperState;

    @Override protected String title() { return "Keyboard"; }

    @Override
    protected void build() {
        ui.body(ui.root, "Type on the handheld and the text goes into whatever field is open on this phone: an email, a "
                + "message, a search. Tab moves between fields; the arrows, Ctrl+C, Ctrl+V and the other keys work as on a "
                + "computer.").setPadding(0, ui.dp(8), 0, 0);
        LinearLayout setup = ui.card("Set it up");
        micState = ui.step(setup, "1", "Allow the microphone");
        ui.button(setup, "Allow the microphone", false, v -> askMic(this::refresh));
        kbState = ui.step(setup, "2", "Turn on the Whisper Tools keyboard");
        ui.button(setup, "Open keyboard settings", false, v -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        pickState = ui.step(setup, "3", "Switch to it when you want to type");
        ui.button(setup, "Choose keyboard", false, v -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        });
        helperState = ui.step(setup, "4", "The helper (optional)");
        ui.body(setup, "Lets the handheld press Send (Alt+S on the handheld), go Back, Home or to Recent apps, and tap on "
                + "this screen through the remote. It acts only on what you ask from the handheld, and reads nothing. In the "
                + "list, find Whisper Tools helper (under Installed apps or Downloaded apps) and turn it on.");
        ui.button(setup, "Open accessibility settings", false, v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));

        LinearLayout tryIt = ui.card("Try it");
        ui.body(tryIt, "Tap the box, switch to Whisper Tools, and type on the handheld. New text is underlined for a moment "
                + "while it may still change. Tap \"Keyboard\" on the bar to go back to your usual keyboard.");
        EditText box = new EditText(this);
        box.setMinLines(3);
        box.setGravity(Gravity.TOP);
        box.setTextColor(t().ink);
        box.setHintTextColor(t().muted);
        box.setHint("Text from the handheld appears here");
        tryIt.addView(box);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) refresh();
    }

    @Override
    protected void refresh() {
        boolean mic = hasMic();
        micState.setText(mic ? "✓ Allowed" : "Needed to hear the handheld");
        micState.setTextColor(mic ? t().green : t().warn);
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        boolean enabled = false;
        if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList()) if (i.getPackageName().equals(getPackageName())) enabled = true;
        kbState.setText(enabled ? "✓ On" : "Turn on \"Whisper Tools\" in the list");
        kbState.setTextColor(enabled ? t().green : t().warn);
        boolean chosen = MainActivity.keyboardChosen(this);
        pickState.setText(chosen ? "✓ Whisper Tools is the keyboard now" : "Switch whenever you want to type on the handheld");
        pickState.setTextColor(chosen ? t().green : t().muted);
        helperState.setText(Helper.on() ? "✓ On" : "Off: typing works without it");
        helperState.setTextColor(Helper.on() ? t().green : t().muted);
    }
}
