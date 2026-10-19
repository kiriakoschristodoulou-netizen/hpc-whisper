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
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The HPC Whisper keyboard. While it is open it listens, and what you type on
 * the handheld goes into the field you are in, in any app: letters, and keys
 * such as Tab, the arrows (with Shift to select and Ctrl to jump a word),
 * Select all, Cut, Copy, Paste, Undo and Redo. The bar says how the handheld
 * is heard, and carries the same editing keys for touch.
 */
public class WhisperIme extends InputMethodService implements Hub.Client {
    private final Writer writer = new Writer(Hub.get().mirror);
    private final Handler handler = new Handler(Looper.getMainLooper());
    private View root, dot;
    private TextView status, detail;
    private MeterView meter;
    private View toolsRow;
    private EditorInfo editor;
    private boolean listening, haveMic;
    private long lastUnreadable = 0;

    private static final int NAVY = 0xFF1B2536, NAVY_DARK = 0xFF10151F, CHIP = 0xFF2B3750, CHIP_DARK = 0xFF222B3D,
            PAPER = 0xFFF4F2EE, MUTED = 0xFFB8C0CC, GREEN = 0xFF7FC75A, AMBER = 0xFFE8A04A, RED = 0xFFE5604F, ACCENT = 0xFF4C7DF0;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            writer.update(getCurrentInputConnection(), editor, System.currentTimeMillis());
            showState();
            handler.postDelayed(this, 400);
        }
    };

    private int dp(float v) { return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()); }

    // ---------- the bar ----------

    @Override
    public View onCreateInputView() {
        boolean dark = Theme.dark(this);
        LinearLayout col = new LinearLayout(this);
        root = col;
        col.setOrientation(LinearLayout.VERTICAL);
        col.setBackgroundColor(dark ? NAVY_DARK : NAVY);

        // status row
        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(dp(16), dp(10), dp(8), dp(4));

        dot = new View(this);
        setDot(AMBER);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(dp(10), dp(10));
        dlp.rightMargin = dp(12);
        top.addView(dot, dlp);

        LinearLayout text = new LinearLayout(this);
        text.setOrientation(LinearLayout.VERTICAL);
        status = new TextView(this);
        status.setTextColor(PAPER);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        status.setTypeface(Typeface.DEFAULT_BOLD);
        status.setSingleLine(true);
        status.setText("HPC Whisper");
        detail = new TextView(this);
        detail.setTextColor(MUTED);
        detail.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        detail.setSingleLine(true);
        detail.setEllipsize(android.text.TextUtils.TruncateAt.END);
        text.addView(status);
        text.addView(detail);
        top.addView(text, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));

        meter = new MeterView(this);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(dp(84), dp(20));
        mlp.rightMargin = dp(10);
        top.addView(meter, mlp);

        TextView sw = chip("Keyboard", false);
        sw.setTextColor(NAVY);
        sw.setTypeface(Typeface.DEFAULT_BOLD);
        GradientDrawable swbg = new GradientDrawable();
        swbg.setColor(PAPER);
        swbg.setCornerRadius(dp(10));
        sw.setBackground(swbg);
        sw.setContentDescription("Switch back to your usual keyboard");
        sw.setOnClickListener(v -> switchAway());
        top.addView(sw, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)));
        col.addView(top);

        // the editing keys, for touch
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        LinearLayout tools = new LinearLayout(this);
        tools.setOrientation(LinearLayout.HORIZONTAL);
        tools.setPadding(dp(10), dp(4), dp(10), dp(10));
        boolean d = dark;
        key(tools, "←", "Left", Keys.LEFT, true, d); key(tools, "→", "Right", Keys.RIGHT, true, d);
        key(tools, "↑", "Up", Keys.UP, true, d); key(tools, "↓", "Down", Keys.DOWN, true, d);
        gap(tools);
        key(tools, "Select ←", "Select to the left", Keys.LEFT | Keys.SHIFT, true, d); key(tools, "Select →", "Select to the right", Keys.RIGHT | Keys.SHIFT, true, d);
        key(tools, "Word ←", "Back one word", Keys.LEFT | Keys.CTRL, true, d); key(tools, "Word →", "Forward one word", Keys.RIGHT | Keys.CTRL, true, d);
        key(tools, "Home", "Start of the line", Keys.HOME, false, d); key(tools, "End", "End of the line", Keys.END, false, d);
        gap(tools);
        key(tools, "All", "Select all", Keys.SELECT_ALL, false, d); key(tools, "Cut", "Cut", Keys.CUT, false, d);
        key(tools, "Copy", "Copy", Keys.COPY, false, d); key(tools, "Paste", "Paste", Keys.PASTE, false, d);
        key(tools, "Undo", "Undo", Keys.UNDO, false, d); key(tools, "Redo", "Redo", Keys.REDO, false, d);
        gap(tools);
        key(tools, "Bksp", "Backspace", Keys.BACKSPACE, true, d); key(tools, "Del", "Delete", Keys.DELETE, true, d);
        key(tools, "Word Bksp", "Delete the last word", Keys.BACKSPACE | Keys.CTRL, true, d);
        key(tools, "Tab", "Tab", Keys.TAB, false, d);
        key(tools, "Enter", "Enter", -1, false, d);
        TextView send = key(tools, "Send", "Send", Keys.SEND, false, d);
        send.setBackground(round(ACCENT, 10));
        send.setTextColor(0xFFFFFFFF);
        scroll.addView(tools);
        toolsRow = scroll;
        col.addView(scroll);
        return col;
    }

    private GradientDrawable round(int color, float radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(radiusDp));
        return g;
    }

    private void setDot(int color) {
        if (dot == null) return;
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(color);
        dot.setBackground(g);
    }

    private TextView chip(String label, boolean small) {
        TextView t = new TextView(this);
        t.setText(label);
        t.setTextColor(PAPER);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, small ? 13 : 14);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(14), 0, dp(14), 0);
        t.setSingleLine(true);
        t.setClickable(true);
        t.setFocusable(false);
        return t;
    }

    private void gap(LinearLayout row) {
        View v = new View(this);
        row.addView(v, new LinearLayout.LayoutParams(dp(8), 1));
    }

    /** One editing key. code -1 is Enter. Held keys repeat. */
    private TextView key(LinearLayout row, String label, String description, final int code, final boolean repeat, boolean dark) {
        TextView t = chip(label, false);
        t.setBackground(round(dark ? CHIP_DARK : CHIP, 10));
        t.setContentDescription(description);
        t.setMinWidth(dp(48));
        t.setOnTouchListener(new View.OnTouchListener() {
            private Runnable again;
            @Override public boolean onTouch(final View v, MotionEvent e) {
                switch (e.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        v.setPressed(true);
                        v.setAlpha(0.65f);
                        press(code);
                        if (repeat) {
                            again = new Runnable() { @Override public void run() { press(code); handler.postDelayed(this, 70); } };
                            handler.postDelayed(again, 420);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL:
                        v.setPressed(false);
                        v.setAlpha(1f);
                        if (again != null) { handler.removeCallbacks(again); again = null; }
                        return true;
                    default:
                        return true;
                }
            }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(44));
        lp.rightMargin = dp(6);
        row.addView(t, lp);
        return t;
    }

    /** A key from the bar: what is underlined is written first, then the key is pressed. */
    private void press(int code) {
        InputConnection ic = getCurrentInputConnection();
        if (ic == null) return;
        writer.finish(ic);
        if (code == -1) Writer.key(ic, KeyEvent.KEYCODE_ENTER, 0);
        else writer.press(ic, editor, code);
    }

    private void switchAway() {
        if (Build.VERSION.SDK_INT >= 28 && switchToPreviousInputMethod()) return;
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.showInputMethodPicker();
    }

    // ---------- the field ----------

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        editor = info;
        if (!restarting) { writer.startField(info); Sessions.begin(this, info.packageName, Hub.get().mirror); }
        if (toolsRow != null) toolsRow.setVisibility(Prefs.editKeys(this) ? View.VISIBLE : View.GONE);
        haveMic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
        if (haveMic && !listening) {
            listening = Hub.get().attach(this, this);
            // you are typing on the handheld, not touching the phone: keep the screen on
            if (root != null) root.setKeepScreenOn(Prefs.screenOn(this));
        }
        showState();
        handler.removeCallbacks(tick);
        handler.postDelayed(tick, 400);
    }

    @Override
    public void onFinishInputView(boolean finishing) {
        writer.finish(getCurrentInputConnection());
        Sessions.end(this);
        handler.removeCallbacks(tick);
        stopListening();
        if (meter != null) meter.clear();
        super.onFinishInputView(finishing);
    }

    private void stopListening() {
        if (listening) Hub.get().detach(this);
        listening = false;
        if (root != null) root.setKeepScreenOn(false);
    }

    @Override
    public void onUpdateSelection(int oldSelStart, int oldSelEnd, int newSelStart, int newSelEnd, int candStart, int candEnd) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candStart, candEnd);
        // you moved the cursor yourself: what is underlined is written where it is, and new text follows the cursor
        if (candStart >= 0 && (newSelStart != candEnd || newSelEnd != candEnd)) writer.finish(getCurrentInputConnection());
    }

    @Override public boolean onEvaluateFullscreenMode() { return false; }

    // ---------- Hub.Client ----------

    @Override public void onFrame(Receiver.Frame f) {
        writer.frame(getCurrentInputConnection(), editor, System.currentTimeMillis());
        showState();
    }
    @Override public void onUnreadable() { lastUnreadable = System.currentTimeMillis(); showState(); }
    @Override public void onLevels(float[] l) { if (meter != null) meter.set(l); }
    @Override public void onProblem(String m) { showState(); }

    // ---------- what the bar says ----------

    private void showState() {
        if (status == null) return;
        long now = System.currentTimeMillis();
        Hub hub = Hub.get();
        if (!haveMic) { say(RED, "Allow the microphone", "Open the HPC Whisper app and follow the steps"); return; }
        if (!listening || !hub.problem.isEmpty()) { say(RED, "The microphone is not available", hub.problem.isEmpty() ? "Another app may be using it" : hub.problem); return; }
        int missing = writer.missing();
        long ago = hub.lastFrameAt == 0 ? Long.MAX_VALUE : now - hub.lastFrameAt;
        if (missing > 0 && ago < 60000)
            say(AMBER, "Waiting for a missing piece", "The handheld repeats its text. Alt+R on the handheld sends it again");
        else if (now - lastUnreadable < 3000 && ago > 3000)
            say(AMBER, "Weak signal", "Move the phone closer to the handheld's speaker");
        else if (ago < 4000)
            say(GREEN, "Receiving from the handheld", "Text goes into the field above");
        else if (ago < 60000)
            say(GREEN, "Connected to the handheld", "Last text " + (ago / 1000) + " s ago");
        else
            say(AMBER, "Listening for the handheld", "Type on the handheld");
    }

    private void say(int color, String s, String d) {
        setDot(color);
        status.setText(s);
        detail.setText(d);
    }

    @Override
    public void onDestroy() {
        stopListening();
        handler.removeCallbacks(tick);
        super.onDestroy();
    }
}
