package net.kyriakos.whisper;

import android.Manifest;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The Whisper Tools keyboard: no keys of its own. While it is open it listens,
 * and what you type on the handheld goes into the field you are in: letters,
 * and keys such as Tab, the arrows, Esc and Ctrl+C.
 */
public class WhisperIme extends InputMethodService implements Link.Client {
    private final Writer writer = new Writer(Link.get().text.mirror);
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView status, detail;
    private MeterView meter;
    private View bar;
    private EditorInfo editor;
    private String heard = "";
    private boolean listening;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            writer.update(getCurrentInputConnection(), editor, System.currentTimeMillis());
            handler.postDelayed(this, 300);
        }
    };

    private int dp(float v) { return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()); }

    @Override
    public View onCreateInputView() {
        boolean dark = Theme.dark(this);
        LinearLayout bar = new LinearLayout(this);
        this.bar = bar;
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(dark ? 0xFF10151F : 0xFF1B2536);
        bar.setPadding(dp(14), dp(8), dp(8), dp(8));

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        status = new TextView(this);
        status.setTextColor(0xFFF4F2EE);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        status.setTypeface(Typeface.DEFAULT_BOLD);
        status.setText("Whisper Tools");
        detail = new TextView(this);
        detail.setTextColor(0xFFB8C0CC);
        detail.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        meter = new MeterView(this);
        left.addView(status);
        left.addView(detail);
        left.addView(meter, new LinearLayout.LayoutParams(dp(150), dp(14)));
        bar.addView(left, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));

        Button sw = new Button(this);
        sw.setText("Keyboard");
        sw.setAllCaps(false);
        sw.setTextColor(0xFF1B2536);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xFFF4F2EE);
        bg.setCornerRadius(dp(8));
        sw.setBackground(bg);
        sw.setPadding(dp(14), 0, dp(14), 0);
        sw.setContentDescription("Switch back to your usual keyboard");
        sw.setOnClickListener(v -> switchAway());
        bar.addView(sw, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(44)));
        return bar;
    }

    private void switchAway() {
        if (Build.VERSION.SDK_INT >= 28 && switchToPreviousInputMethod()) return;
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.showInputMethodPicker();
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        editor = info;
        if (!restarting) writer.startField(info);
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            setStatus("Allow the microphone: open the Whisper Tools app", "");
            return;
        }
        listening = Link.get().attach(this, this);
        if (listening) {
            setStatus(heard.isEmpty() ? "Listening: type on the handheld" : heard, Link.get().handheldAnswers ? "The handheld hears this phone too" : "");
            if (bar != null) bar.setKeepScreenOn(true);   // you are typing on the handheld, not touching the phone
        }
        handler.removeCallbacks(tick);
        handler.postDelayed(tick, 300);
    }

    @Override
    public void onFinishInputView(boolean finishing) {
        writer.finish(getCurrentInputConnection());
        handler.removeCallbacks(tick);
        if (listening) Link.get().detach(this);
        listening = false;
        if (bar != null) bar.setKeepScreenOn(false);
        if (meter != null) meter.clear();
        super.onFinishInputView(finishing);
    }

    // ---------- Link.Client ----------

    @Override public void onFrame(Receiver.Frame f) {
        writer.frame(getCurrentInputConnection(), editor, System.currentTimeMillis());
        Recent.add(this, writer.mirror);
        heard = "Hearing the handheld";
        setStatus(heard, Link.get().handheldAnswers ? "It hears this phone too: what arrived is confirmed" : "");
    }
    @Override public void onUnreadable() { setStatus("Weak signal: move closer", ""); }
    @Override public void onLevels(float[] l) { if (meter != null) meter.set(l); }
    @Override public void onProblem(String m) { setStatus(m, ""); }

    @Override
    public void onUpdateSelection(int oldSelStart, int oldSelEnd, int newSelStart, int newSelEnd, int candStart, int candEnd) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candStart, candEnd);
        // you moved the cursor yourself: what is underlined is written where it is, and new text follows the cursor
        if (candStart >= 0 && (newSelStart != candEnd || newSelEnd != candEnd)) writer.finish(getCurrentInputConnection());
    }

    @Override
    public boolean onEvaluateFullscreenMode() { return false; }

    private void setStatus(String s, String d) {
        if (status != null) status.setText(s);
        if (detail != null) { detail.setText(d); detail.setVisibility(d.isEmpty() ? View.GONE : View.VISIBLE); }
    }

    @Override
    public void onDestroy() {
        if (listening) Link.get().detach(this);
        handler.removeCallbacks(tick);
        super.onDestroy();
    }
}
