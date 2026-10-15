package net.kyriakos.whisper;

import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/** The picture remote: this phone's screen on the handheld, and taps back through the helper. */
public class RemoteActivity extends ToolActivity {
    private static final int ASK_SCREEN = 2;
    private TextView state, helper;
    private Button btn;

    @Override protected String title() { return "Remote"; }

    @Override
    protected void build() {
        LinearLayout c = ui.card(null);
        ui.body(c, "Shows this phone's screen on the handheld, in grey: a small change arrives in about a second, a whole new "
                + "screen in 5 to 15 seconds. The phone hisses softly while its screen changes. Android asks each time "
                + "before the screen is shared.");
        state = ui.text(c, "", 15, t().ink, true);
        state.setPadding(0, ui.dp(8), 0, 0);
        btn = ui.button(c, "Start the remote", true, v -> { if (LinkService.remoteOn()) stop(); else ask(); });

        LinearLayout h = ui.card("Taps from the handheld");
        ui.body(h, "Tapping the picture on the handheld taps this phone, and Alt+B, Alt+H and Alt+S press Back, Home and "
                + "Send. That needs the helper, turned on once in the accessibility settings.");
        helper = ui.text(h, "", 14, t().ink, true);
        ui.button(h, "Keyboard and helper setup", false, v -> startActivity(new Intent(this, KeyboardActivity.class)));

        LinearLayout k = ui.card("On the handheld");
        ui.body(k, "Open Remote on the handheld's home screen. Arrows and Page Up/Down move the view, Alt+Z switches between "
                + "zoom and the whole screen, Alt+U refreshes. What you type goes to this phone as on the Type screen.");
        if (MainActivity.ACTION_REMOTE.equals(getIntent().getAction())) handler.post(this::ask);
    }

    @Override
    protected void refresh() {
        boolean on = LinkService.remoteOn();
        btn.setText(on ? "Stop the remote" : "Start the remote");
        state.setText(on ? "Showing this screen on the handheld" : linkLine());
        state.setTextColor(on ? t().green : t().ink);
        helper.setText(Helper.on() ? "✓ The helper is on" : "The helper is off: the handheld can watch but not tap");
        helper.setTextColor(Helper.on() ? t().green : t().warn);
    }

    private void ask() {
        if (!hasMic()) { askMic(this::ask); return; }
        MediaProjectionManager mpm = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        if (mpm != null) startActivityForResult(mpm.createScreenCaptureIntent(), ASK_SCREEN);
    }

    private void stop() {
        LinkService s = LinkService.running;
        if (s != null) s.stopRemote();
        handler.postDelayed(this::refresh, 200);
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code != ASK_SCREEN) return;
        if (result == RESULT_OK && data != null) {
            Intent s = new Intent(this, LinkService.class).setAction(LinkService.REMOTE)
                    .putExtra(LinkService.EXTRA_CODE, result).putExtra(LinkService.EXTRA_DATA, data);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(s); else startService(s);
            handler.postDelayed(this::refresh, 600);
        } else Toast.makeText(this, "The screen was not shared", Toast.LENGTH_SHORT).show();
    }
}
