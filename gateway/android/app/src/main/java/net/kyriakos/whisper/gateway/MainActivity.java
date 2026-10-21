package net.kyriakos.whisper.gateway;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;

import java.util.List;
import java.util.Locale;

/** One screen: an on/off switch, how loud, and what is happening. */
public final class MainActivity extends Activity {
    private final Handler h = new Handler(Looper.getMainLooper());
    private Switch sw;
    private TextView status, log;
    private boolean setting;
    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); h.postDelayed(this, 500); }
    };

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        ScrollView sv = new ScrollView(this);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(16), dp(24), dp(16), dp(24));
        sv.addView(col);

        TextView title = new TextView(this);
        title.setText("Whisper Gateway");
        title.setTextSize(24);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        col.addView(title);

        TextView intro = new TextView(this);
        intro.setText("Gives your handheld the internet. Turn it on, put the phone next to the handheld, and start Whisper Net there. "
                + "Only what the handheld needs goes through the sound; this phone makes the real connections.");
        intro.setPadding(0, dp(8), 0, dp(16));
        col.addView(intro);

        sw = new Switch(this);
        sw.setText("Gateway on");
        sw.setTextSize(20);
        sw.setPadding(0, dp(8), 0, dp(8));
        sw.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(CompoundButton v, boolean on) { if (!setting) toggle(on); }
        });
        col.addView(sw);

        TextView vl = new TextView(this);
        vl.setText("Sound level (set the phone's media volume up too)");
        vl.setPadding(0, dp(16), 0, 0);
        col.addView(vl);
        SeekBar sb = new SeekBar(this);
        sb.setMax(100);
        final SharedPreferences sp = getSharedPreferences("gateway", MODE_PRIVATE);
        sb.setProgress(sp.getInt("volume", 80));
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) { sp.edit().putInt("volume", Math.max(10, p)).apply(); }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) { }
        });
        col.addView(sb);

        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, dp(16), 0, dp(8));
        col.addView(status);

        log = new TextView(this);
        log.setTypeface(Typeface.MONOSPACE);
        log.setTextSize(12);
        col.addView(log);

        setContentView(sv);
    }

    @Override protected void onResume() { super.onResume(); h.post(tick); }
    @Override protected void onPause() { super.onPause(); h.removeCallbacks(tick); }

    private void toggle(boolean on) {
        if (!on) {
            Intent i = new Intent(this, GatewayService.class).setAction(GatewayService.ACTION_STOP);
            startService(i);
            return;
        }
        java.util.ArrayList<String> need = new java.util.ArrayList<>();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.RECORD_AUDIO);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!need.isEmpty()) { requestPermissions(need.toArray(new String[0]), 1); return; }
        startGateway();
    }

    private void startGateway() {
        Intent i = new Intent(this, GatewayService.class).setAction(GatewayService.ACTION_START);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
    }

    @Override public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startGateway();
        else { State.problem = "The microphone permission is needed to hear the handheld."; refresh(); }
    }

    private static String ago(long t) {
        if (t == 0) return "not yet";
        long s = (System.currentTimeMillis() - t) / 1000;
        return s < 2 ? "just now" : s + " s ago";
    }

    private void refresh() {
        setting = true;
        sw.setChecked(State.running);
        setting = false;
        StringBuilder s = new StringBuilder();
        if (!State.problem.isEmpty()) s.append(State.problem).append("\n\n");
        if (State.running) {
            s.append(String.format(Locale.US, "Listening (%s microphone, level %d%%)\n", State.source, State.level));
            s.append("Handheld last heard: ").append(ago(State.lastHeardAt)).append("\n");
            s.append(String.format(Locale.US, "Frames heard %d, turns answered %d\n", State.framesHeard, State.turns));
            s.append(String.format(Locale.US, "Connections open %d\n", State.connections));
            s.append(String.format(Locale.US, "Sent to the handheld %d bytes, received from it %d bytes", State.bytesDown, State.bytesUp));
        } else if (State.problem.isEmpty()) {
            s.append("Off.");
        }
        status.setText(s.toString());
        List<String> lines = State.lines();
        StringBuilder l = new StringBuilder();
        for (int i = lines.size() - 1; i >= 0; i--) l.append(lines.get(i)).append("\n");
        log.setText(l.toString());
    }
}
