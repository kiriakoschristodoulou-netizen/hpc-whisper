package net.kyriakos.whisper;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * HPC Whisper: the setup and check screen for the keyboard. Created by
 * Kyriakos Christodoulou. No internet: nothing leaves the phone.
 */
public class MainActivity extends Activity {
    private static final int NAVY = 0xFF1B2536, PAPER = 0xFFF4F2EE, INK = 0xFF1D2430, MUTED = 0xFF6B6F78,
            CARD = 0xFFFFFFFF, GREEN = 0xFF3D8A1F, LINE = 0xFFDCD8D0, WARN = 0xFFB4531A;
    private static final int ASK_MIC = 1, RECORD_SECONDS = 30;
    private static final String PAGE = "https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Listener listener = new Listener();
    private final Mirror mirror = new Mirror();
    private LinearLayout root;
    private TextView micState, kbState, pickState, signalState, received, recState;
    private Button listenBtn, recBtn;
    private MeterView meter;
    private int unreadable = 0;
    private Receiver.Frame lastFrame;
    private boolean recording;

    private int dp(float v) { return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()); }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(PAPER);
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(16), dp(16), dp(28));
        scroll.addView(root);
        setContentView(scroll);
        build();
    }

    // ---------- layout helpers ----------
    private TextView text(LinearLayout into, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setLineSpacing(0, 1.15f);
        into.addView(t);
        return t;
    }

    private LinearLayout card(String title) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(16), dp(14), dp(16), dp(16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD); bg.setCornerRadius(dp(12)); bg.setStroke(dp(1), LINE);
        c.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(14);
        root.addView(c, lp);
        TextView t = text(c, title, 17, INK, true);
        t.setPadding(0, 0, 0, dp(6));
        return c;
    }

    private Button button(LinearLayout into, String label, boolean primary, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setTextColor(primary ? 0xFFFFFFFF : INK);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(primary ? NAVY : 0xFFEDEAE4);
        bg.setCornerRadius(dp(10));
        b.setBackground(bg);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48));
        lp.topMargin = dp(8);
        into.addView(b, lp);
        return b;
    }

    private TextView step(LinearLayout c, String n, String what) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(10), 0, 0);
        TextView num = new TextView(this);
        num.setText(n);
        num.setTextColor(0xFFFFFFFF);
        num.setTypeface(Typeface.DEFAULT_BOLD);
        num.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL); bg.setColor(NAVY);
        num.setBackground(bg);
        row.addView(num, new LinearLayout.LayoutParams(dp(26), dp(26)));
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(12), 0, 0, 0);
        text(col, what, 15, INK, true);
        TextView state = text(col, "", 13.5f, MUTED, false);
        row.addView(col, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        c.addView(row);
        return state;
    }

    // ---------- the screen ----------
    private void build() {
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.ic_launcher);
        head.addView(icon, new LinearLayout.LayoutParams(dp(56), dp(56)));
        LinearLayout ht = new LinearLayout(this);
        ht.setOrientation(LinearLayout.VERTICAL);
        ht.setPadding(dp(14), 0, 0, 0);
        text(ht, "HPC Whisper", 24, INK, true);
        text(ht, "Version " + version() + " · by Kyriakos Christodoulou", 13, MUTED, false);
        head.addView(ht);
        root.addView(head);
        TextView intro = text(root, "Type on a Windows CE handheld PC, such as the HP Jornada 720, and the text goes "
                + "straight into any app on this phone: an email in Gmail, a message, a note. It travels as tones "
                + "too high to hear. No cable, no network.", 15, INK, false);
        intro.setPadding(0, dp(12), 0, 0);

        LinearLayout setup = card("Set up the keyboard");
        micState = step(setup, "1", "Allow the microphone");
        button(setup, "Allow the microphone", false, v -> requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, ASK_MIC));
        kbState = step(setup, "2", "Turn on the HPC Whisper keyboard");
        button(setup, "Open keyboard settings", false, v -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        pickState = step(setup, "3", "Switch to it when you want to type");
        button(setup, "Choose keyboard", false, v -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        });
        text(setup, "In any app, tap a text field, switch to HPC Whisper (the keyboard icon at the bottom of the "
                + "screen, or a long press on the space bar in most keyboards) and type on the handheld. New text "
                + "appears underlined for a moment while it may still change, then it is written for good. Tap "
                + "\"Keyboard\" on the bar to go back to your usual keyboard.", 13.5f, MUTED, false).setPadding(0, dp(12), 0, 0);

        LinearLayout check = card("Check the signal");
        text(check, "Run HPC Whisper on the handheld, then listen here and type a few words on it.", 14, MUTED, false);
        meter = new MeterView(this);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40));
        mlp.topMargin = dp(12);
        check.addView(meter, mlp);
        LinearLayout scale = new LinearLayout(this);
        TextView a = text(scale, "18.0 kHz", 11, MUTED, false);
        a.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        text(scale, "21.5 kHz", 11, MUTED, false);
        check.addView(scale);
        signalState = text(check, "Not listening", 14, INK, true);
        signalState.setPadding(0, dp(8), 0, 0);
        received = text(check, "", 15, INK, false);
        received.setTypeface(Typeface.MONOSPACE);
        received.setPadding(0, dp(6), 0, 0);
        listenBtn = button(check, "Listen", true, v -> toggleListen());

        LinearLayout tryIt = card("Try the keyboard");
        text(tryIt, "Tap the box, switch to HPC Whisper, and type on the handheld.", 14, MUTED, false);
        EditText box = new EditText(this);
        box.setMinLines(3);
        box.setGravity(Gravity.TOP);
        box.setHint("Text from the handheld appears here");
        // the keyboard needs the microphone for itself
        box.setOnFocusChangeListener((v, has) -> { if (has) stopListen(); });
        tryIt.addView(box);

        LinearLayout diag = card("Diagnostics");
        text(diag, "If letters go missing, record what this phone hears while you type on the handheld, and send "
                + "the recording to whoever is helping you. It is sound only, kept on this phone until you share it.", 14, MUTED, false);
        recState = text(diag, "", 14, INK, true);
        recBtn = button(diag, "Record " + RECORD_SECONDS + " seconds", false, v -> record());

        LinearLayout notes = card("Notes");
        text(notes, "iPhone", 15, INK, true);
        text(notes, "Apple does not let keyboards use the microphone at all, so an iPhone keyboard is impossible. "
                + "On an iPhone (or any other phone) use the receiver page in the browser instead, with Copy and Share:", 14, INK, false);
        TextView link = text(notes, PAGE, 14, 0xFF2A5DB0, false);
        link.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(PAGE))));
        text(notes, "On the handheld", 15, INK, true).setPadding(0, dp(12), 0, 0);
        text(notes, "Run whisper.exe from the HPC-Whisper download (version 1.1 or later). It needs an ARM processor "
                + "and Windows CE 3.0 or later. Band, speed and volume are set on the handheld; this phone finds them "
                + "by itself.", 14, INK, false);
        text(notes, "Privacy", 15, INK, true).setPadding(0, dp(12), 0, 0);
        text(notes, "This app has no internet access. The microphone is used only while the HPC Whisper keyboard is "
                + "open, or while you listen or record on this screen.", 14, INK, false);
        text(notes, "When it cannot listen", 15, INK, true).setPadding(0, dp(12), 0, 0);
        text(notes, "If another app is using the microphone (a call, a voice recording), the keyboard cannot hear "
                + "the handheld until it is free.", 14, INK, false);
    }

    private String version() {
        try { PackageInfo p = getPackageManager().getPackageInfo(getPackageName(), 0); return p.versionName; }
        catch (Exception e) { return ""; }
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshSetup();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) refreshSetup();
    }

    @Override
    protected void onPause() {
        stopListen();
        super.onPause();
    }

    private void refreshSetup() {
        boolean mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
        micState.setText(mic ? "✓ Allowed" : "Needed to hear the handheld");
        micState.setTextColor(mic ? GREEN : WARN);
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        boolean enabled = false;
        if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList())
            if (i.getPackageName().equals(getPackageName())) enabled = true;
        kbState.setText(enabled ? "✓ On" : "Turn on \"HPC Whisper\" in the list");
        kbState.setTextColor(enabled ? GREEN : WARN);
        String current = Settings.Secure.getString(getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
        boolean chosen = current != null && current.startsWith(getPackageName());
        pickState.setText(chosen ? "✓ HPC Whisper is the keyboard now" : "Switch whenever you want to type on the handheld");
        pickState.setTextColor(chosen ? GREEN : MUTED);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        refreshSetup();
        if (code == ASK_MIC && res.length > 0 && res[0] != PackageManager.PERMISSION_GRANTED)
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
    }

    // ---------- listening ----------
    private final Listener.Callback cb = new Listener.Callback() {
        @Override public void onFrame(Receiver.Frame f) {
            lastFrame = f;
            mirror.apply(f, System.currentTimeMillis());
            String t = mirror.text(0, mirror.L, "·");
            if (t.length() > 400) t = "…" + t.substring(t.length() - 400);
            received.setText(t);
            showSignal();
        }
        @Override public void onUnreadable() { unreadable++; showSignal(); }
        @Override public void onLevels(float[] l) { meter.set(l); }
        @Override public void onProblem(String m) { signalState.setText(m); signalState.setTextColor(WARN); }
    };

    private void showSignal() {
        StringBuilder s = new StringBuilder();
        if (lastFrame != null) {
            s.append("Hearing the handheld: ").append(String.format("%.1f", lastFrame.bandHz / 1000.0)).append("–")
             .append(String.format("%.1f", (lastFrame.bandHz + 1500) / 1000.0)).append(" kHz, ")
             .append(lastFrame.ms == 48 ? "Slow" : lastFrame.ms == 32 ? "Normal" : "Fast");
            s.append("\n").append(listener.framesRead()).append(" pieces received");
        } else s.append("Listening (").append(listener.sourceName).append(" microphone, ").append(listener.channelsName).append(")");
        if (unreadable > 0) s.append(", ").append(unreadable).append(" too weak to read");
        signalState.setText(s.toString());
        signalState.setTextColor(INK);
    }

    private boolean startListen() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, ASK_MIC);
            return false;
        }
        if (!listener.start(this, cb)) return false;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        listenBtn.setText("Stop");
        showSignal();
        return true;
    }

    private void stopListen() {
        if (recording) finishRecording(false);
        listener.stop();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (listenBtn != null) listenBtn.setText("Listen");
        if (meter != null) meter.clear();
    }

    private void toggleListen() { if (listener.isRunning()) stopListen(); else startListen(); }

    // ---------- diagnostics ----------
    private void record() {
        if (recording) return;
        if (!listener.isRunning() && !startListen()) return;
        listener.startTape(RECORD_SECONDS);
        recording = true;
        recBtn.setEnabled(false);
        final long t0 = System.currentTimeMillis();
        handler.post(new Runnable() {
            @Override public void run() {
                if (!recording) return;
                long left = RECORD_SECONDS - (System.currentTimeMillis() - t0) / 1000;
                recState.setText("Recording… type on the handheld (" + Math.max(0, left) + " s)");
                if (listener.tapeFull()) finishRecording(true);
                else handler.postDelayed(this, 250);
            }
        });
    }

    private void finishRecording(boolean share) {
        recording = false;
        recBtn.setEnabled(true);
        short[] pcm = listener.takeTape();
        if (!share || pcm == null || pcm.length == 0) { recState.setText(""); return; }
        try {
            File f = new File(getCacheDir(), "hpc-whisper-recording.wav");
            writeWav(f, pcm, listener.rate);
            recState.setText("Recorded " + (pcm.length / Math.max(1, listener.rate)) + " s (" + listener.sourceName + " microphone).");
            Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", f);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("audio/wav");
            i.putExtra(Intent.EXTRA_STREAM, uri);
            i.putExtra(Intent.EXTRA_SUBJECT, "HPC Whisper recording");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "Send the recording"));
        } catch (Exception e) {
            recState.setText("The recording could not be saved: " + e.getMessage());
        }
    }

    private static void writeWav(File f, short[] pcm, int rate) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(44 + pcm.length * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + pcm.length * 2).put("WAVE".getBytes()).put("fmt ".getBytes())
         .putInt(16).putShort((short) 1).putShort((short) 1).putInt(rate).putInt(rate * 2)
         .putShort((short) 2).putShort((short) 16).put("data".getBytes()).putInt(pcm.length * 2);
        for (short s : pcm) b.putShort(s);
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(b.array()); }
    }
}
