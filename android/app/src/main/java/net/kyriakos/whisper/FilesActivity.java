package net.kyriakos.whisper;

import android.content.Intent;
import android.net.Uri;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.FileProvider;

import java.io.File;

/** Files: send one to the handheld (converted to fit), and the list of files on their way both ways. */
public class FilesActivity extends ToolActivity implements Transfers.Watcher {
    private static final int PICK_FILE = 3;
    private LinearLayout list;
    private TextView conn;

    @Override protected String title() { return "Files"; }

    @Override
    protected void build() {
        LinearLayout send = ui.card("To the handheld");
        ui.body(send, "Pick a file here, or use Share → Whisper Tools in any app. Pictures are fitted to the handheld's "
                + "screen, PDF pages become pictures, sound becomes a WAV it can play. A photo takes 20 to 40 seconds, with "
                + "a soft hiss from the phone while it goes.");
        ui.button(send, "Send a file", true, v -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            startActivityForResult(i, PICK_FILE);
        });
        LinearLayout from = ui.card("From the handheld");
        ui.body(from, "Select a file on the handheld's Files screen and press S. It arrives in Downloads/Whisper Tools "
                + "while this phone is connected.");
        conn = ui.text(from, "", 14, t().ink, true);
        conn.setPadding(0, ui.dp(6), 0, 0);
        ui.button(from, "Connect", false, v -> { if (!LinkService.on()) connect(); });

        LinearLayout c = ui.card("On the way and done");
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        c.addView(list);
        ui.button(c, "Clear the list", false, v -> Transfers.get().clearFinished());
    }

    @Override
    protected void onResume() { super.onResume(); Transfers.get().watch(this); refresh(); }

    @Override
    protected void onPause() { Transfers.get().unwatch(this); super.onPause(); }

    @Override public void onTransfers() { refresh(); }

    @Override
    protected void refresh() {
        conn.setText(linkLine());
        list.removeAllViews();
        for (Transfers.Item it : Transfers.get().items) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.VERTICAL);
            row.setPadding(0, ui.dp(10), 0, 0);
            ui.text(row, (it.out ? "→ " : "← ") + it.name + "  (" + Ui.size(it.size) + ")", 14, t().ink, true);
            String st = it.state;
            if (!it.finished && it.out) st += ", " + Ui.time(Transfers.estimateSeconds((int) (it.size * (1 - it.progress)))) + " left";
            TextView s = ui.text(row, st, 13, it.finished ? (it.ok ? t().green : t().warn) : t().muted, false);
            if (!it.finished) {
                ProgressBar pb = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
                pb.setMax(1000);
                pb.setProgress(Math.round(it.progress * 1000));
                row.addView(pb);
                row.setOnLongClickListener(v -> { Transfers.get().cancel(it); return true; });
            } else if (it.saved != null) {
                s.setText(it.state + " · tap to open");
                row.setOnClickListener(v -> open(it));
            }
            list.addView(row);
        }
        if (Transfers.get().items.isEmpty()) ui.text(list, "No files yet.", 13, t().muted, false);
        else ui.text(list, "Hold a file that is on its way to cancel it.", 12, t().muted, false).setPadding(0, ui.dp(6), 0, 0);
    }

    private void open(Transfers.Item it) {
        try {
            Uri u = it.saved;
            if ("file".equals(u.getScheme())) u = FileProvider.getUriForFile(this, getPackageName() + ".files", new File(u.getPath()));
            Intent i = new Intent(Intent.ACTION_VIEW).setDataAndType(u, Convert.mimeOf(it.name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, it.name));
        } catch (Exception e) { Toast.makeText(this, "It cannot be opened here: find it in Downloads/Whisper Tools", Toast.LENGTH_LONG).show(); }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == PICK_FILE && result == RESULT_OK && data != null && data.getData() != null)
            startActivity(new Intent(this, ShareActivity.class).setAction(Intent.ACTION_SEND)
                    .putExtra(Intent.EXTRA_STREAM, data.getData()).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
    }
}
