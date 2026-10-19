package net.kyriakos.whisper;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

/** One screen of the app: a page built with Ui, refreshed every second while visible. */
public abstract class BaseActivity extends Activity {
    static final int ASK_MIC = 1;
    protected final Handler handler = new Handler(Looper.getMainLooper());
    protected Ui ui;
    private Runnable afterMic;

    /** The title in the bar, or null for none. */
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

    @Override protected void onResume() { super.onResume(); handler.post(ticker); }
    @Override protected void onPause() { handler.removeCallbacks(ticker); super.onPause(); }

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
}
