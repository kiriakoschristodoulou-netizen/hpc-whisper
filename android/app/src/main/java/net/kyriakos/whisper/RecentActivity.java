package net.kyriakos.whisper;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.graphics.Typeface;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/** Recent text: the safety copy of what came from the handheld, to copy or clear. */
public class RecentActivity extends ToolActivity {
    private TextView text;

    @Override protected String title() { return "Recent text"; }

    @Override
    protected void build() {
        ui.body(ui.root, "A copy of the last text from the handheld, kept only on this phone, in case it went into a field "
                + "that closed.").setPadding(0, ui.dp(8), 0, 0);
        LinearLayout c = ui.card(null);
        text = ui.text(c, "", 14, t().ink, false);
        text.setTypeface(Typeface.MONOSPACE);
        text.setTextIsSelectable(true);
        ui.button(c, "Copy all", true, v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cm != null) { cm.setPrimaryClip(ClipData.newPlainText("Whisper Tools", Recent.get(this))); Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show(); }
        });
        ui.button(c, "Clear", false, v -> { Recent.clear(this); refresh(); });
        refresh();
    }

    private String shown = null;

    @Override
    protected void refresh() {
        String s = Recent.get(this);
        if (s.equals(shown)) return;              // leaves a selection alone
        shown = s;
        text.setText(s.isEmpty() ? "Nothing yet." : s);
    }
}
