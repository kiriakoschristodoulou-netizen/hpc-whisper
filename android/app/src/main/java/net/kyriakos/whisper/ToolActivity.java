package net.kyriakos.whisper;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.WindowManager;

import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;

import java.util.Locale;

/**
 * One screen of Whisper Tools: a bar with a back arrow and the tool's name,
 * then the tool. While the connection is on, the screen hears the handheld
 * too (it is a Link client while it is visible).
 */
public abstract class ToolActivity extends Activity implements Link.Client {
    static final int ASK_MIC = 1, ASK_NOTE = 9;
    protected final Handler handler = new Handler(Looper.getMainLooper());
    protected Ui ui;
    protected boolean attached;
    private Runnable afterMic;

    protected abstract String title();
    protected abstract void build();
    /** Called every second while visible, and when something changed. */
    protected void refresh() { }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        ui = new Ui(this);
        if (title() == null) ui.page(); else ui.page(title(), this::finish);
        build();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (LinkService.on() && !attached) attached = Link.get().attach(this, this);
        handler.post(ticker);
    }

    @Override
    protected void onPause() {
        if (attached) { Link.get().detach(this); attached = false; }
        handler.removeCallbacks(ticker);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        super.onPause();
    }

    private final Runnable ticker = new Runnable() {
        @Override public void run() { refresh(); handler.postDelayed(this, 1000); }
    };

    protected Theme t() { return ui.t; }

    protected boolean hasMic() { return checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED; }

    protected void askMic(Runnable then) {
        afterMic = then;
        requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, ASK_MIC);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (code != ASK_MIC) return;
        if (res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) {
            Runnable r = afterMic; afterMic = null;
            if (r != null) r.run();
        } else startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
        refresh();
    }

    /** Starts the connection (asking for the microphone first if needed). False when it must wait for an answer. */
    protected boolean connect() {
        if (!hasMic()) { askMic(this::connect); return false; }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, ASK_NOTE);
        LinkService.start(this);
        handler.postDelayed(() -> { if (!attached && LinkService.on()) attached = Link.get().attach(this, this); refresh(); }, 400);
        return true;
    }

    protected void disconnect() {
        if (attached) { Link.get().detach(this); attached = false; }
        LinkService.stop(this);
        handler.postDelayed(this::refresh, 300);
    }

    /** One line on the connection, for any screen. */
    static String linkLine() {
        if (!LinkService.on()) return "Not connected";
        Link l = Link.get();
        if (l.lastHeard <= 0) return "Connected: waiting for the handheld";
        long ago = (System.currentTimeMillis() - l.lastHeard) / 1000;
        return ago < 5 ? "Connected: hearing the handheld" : "Connected: heard the handheld " + ago + " s ago";
    }

    /** Bits a symbol to kbit/s after error protection (about 85 % of the raw rate). */
    static String kbps(BitMap m) {
        float k = m.bitsPerSymbol() / (Channel.SYM / (float) Channel.RATE) / 1000f * 0.85f;
        return String.format(Locale.US, "about %.1f kbit/s (%d bits a symbol)", k, m.bitsPerSymbol());
    }
}
