package net.kyriakos.whisper;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * Share → HPC Whisper, from any app: choose how the file travels (the
 * conversions, with the time each takes), then it goes to the handheld.
 */
public class ShareActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Uri> uris = new ArrayList<>();
    private final List<String> names = new ArrayList<>();
    private final List<String> mimes = new ArrayList<>();
    private Ui ui;
    private TextView state;
    private LinearLayout choicesBox;
    private List<Convert.Out> ready;
    private Button sendBtn;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        ui = new Ui(this);
        ui.page();
        Intent in = getIntent();
        if (Intent.ACTION_SEND.equals(in.getAction())) {
            Uri u = in.getParcelableExtra(Intent.EXTRA_STREAM);
            if (u != null) uris.add(u);
            else {
                CharSequence txt = in.getCharSequenceExtra(Intent.EXTRA_TEXT);
                if (txt != null) { sendText(txt.toString()); return; }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(in.getAction())) {
            ArrayList<Uri> l = in.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (l != null) uris.addAll(l);
        }
        if (uris.isEmpty()) { ui.text(ui.root, "Nothing to send.", 16, ui.t.ink, true); return; }
        for (Uri u : uris) { String n = Convert.nameOf(this, u); names.add(n); mimes.add(getContentResolver().getType(u)); }
        ui.text(ui.root, "Send to the handheld", 22, ui.t.ink, true);
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < names.size() && i < 6; i++) s.append(i > 0 ? "\n" : "").append(names.get(i));
        if (names.size() > 6) s.append("\n…and ").append(names.size() - 6).append(" more");
        ui.body(ui.root, s.toString()).setPadding(0, ui.dp(6), 0, 0);
        LinearLayout c = ui.card("How should it travel?");
        Convert.Type t = Convert.typeOf(mimes.get(0), names.get(0));
        choicesBox = c;
        for (Convert.Choice ch : Convert.choices(t)) {
            Button b = ui.button(c, ch.label, false, v -> prepare(ch.id));
            if (!ch.detail.isEmpty()) ui.body(c, ch.detail).setPadding(ui.dp(4), ui.dp(2), 0, ui.dp(4));
        }
        LinearLayout go = ui.card(null);
        state = ui.text(go, "Choose above.", 14, ui.t.ink, false);
        sendBtn = ui.button(go, "Send", true, v -> send());
        sendBtn.setEnabled(false);
        sendBtn.setAlpha(0.5f);
        ui.body(go, "The handheld must be running HPC Whisper with this phone close by. Files to the handheld travel on the fast "
                + "channel: a soft hiss from the phone's speaker while they go. Keep the phone's media volume at about half.").setPadding(0, ui.dp(10), 0, 0);
    }

    private void prepare(String choice) {
        state.setText("Preparing…");
        sendBtn.setEnabled(false); sendBtn.setAlpha(0.5f);
        new Thread(() -> {
            List<Convert.Out> all = new ArrayList<>();
            String err = null;
            for (int i = 0; i < uris.size(); i++) {
                try {
                    Convert.Type t = Convert.typeOf(mimes.get(i), names.get(i));
                    String ch = choice;
                    boolean fits = false;
                    for (Convert.Choice c : Convert.choices(t)) if (c.id.equals(choice)) fits = true;
                    if (!fits) ch = Convert.choices(t).get(0).id;
                    all.addAll(Convert.run(this, uris.get(i), names.get(i), t, ch));
                } catch (Exception e) { err = names.get(i) + ": " + e.getMessage(); }
            }
            String fe = err;
            main.post(() -> {
                ready = all;
                long bytes = 0;
                for (Convert.Out o : all) bytes += o.data.length;
                int secs = 0;
                for (Convert.Out o : all) secs += Transfers.estimateSeconds(o.data.length);
                String s = all.isEmpty() ? "Nothing could be prepared." :
                        (all.size() == 1 ? all.get(0).name : all.size() + " files") + ", " + Ui.size(bytes) + ": " + Ui.time(secs) + " to the handheld.";
                if (fe != null) s += "\n" + fe;
                state.setText(s);
                boolean ok = !all.isEmpty();
                sendBtn.setEnabled(ok); sendBtn.setAlpha(ok ? 1f : 0.5f);
            });
        }, "whisper-convert").start();
    }

    private void sendText(String text) {
        ui.text(ui.root, "Send to the handheld", 22, ui.t.ink, true);
        byte[] d = text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        ready = new ArrayList<>();
        ready.add(new Convert.Out("Shared text.txt", Transfers.KIND_TEXT, d));
        LinearLayout go = ui.card(null);
        state = ui.text(go, "Text, " + Ui.size(d.length) + ": " + Ui.time(Transfers.estimateSeconds(d.length)) + " to the handheld.", 14, ui.t.ink, false);
        sendBtn = ui.button(go, "Send", true, v -> send());
    }

    private void send() {
        if (ready == null || ready.isEmpty()) return;
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            state.setText("HPC Whisper needs the microphone to hear the handheld's answers. Open the app and allow it first.");
            startActivity(new Intent(this, MainActivity.class));
            return;
        }
        for (Convert.Out o : ready) Transfers.get().send(o.name, o.kind, o.data);
        LinkService.start(this);
        startActivity(new Intent(this, MainActivity.class).setAction(MainActivity.ACTION_FILES));
        finish();
    }
}
