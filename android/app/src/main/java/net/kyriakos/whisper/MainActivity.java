package net.kyriakos.whisper;

import android.content.Intent;
import android.content.pm.PackageInfo;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Whisper Tools: the home screen. One button for each tool, each with a line
 * saying how it is; the connection to the handheld at the top. Created by
 * Kyriakos Christodoulou. No internet: nothing leaves the phone.
 */
public class MainActivity extends ToolActivity implements Transfers.Watcher {
    public static final String ACTION_FILES = "net.kyriakos.whisper.FILES", ACTION_REMOTE = "net.kyriakos.whisper.REMOTE";

    private TextView linkState, kbState, filesState, remoteState, recentState, linkTileState, setupNote;
    private Button connectBtn;
    private LinearLayout setupCard;

    @Override protected String title() { return null; }

    @Override
    protected void build() {
        LinearLayout root = ui.root;
        root.setPadding(ui.dp(16), ui.dp(16), ui.dp(16), ui.dp(28));
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.ic_launcher);
        head.addView(icon, new LinearLayout.LayoutParams(ui.dp(52), ui.dp(52)));
        LinearLayout ht = new LinearLayout(this);
        ht.setOrientation(LinearLayout.VERTICAL);
        ht.setPadding(ui.dp(14), 0, 0, 0);
        ui.text(ht, "Whisper Tools", 24, t().ink, true);
        ui.text(ht, "For your handheld PC · version " + version(), 13, t().muted, false);
        head.addView(ht);
        root.addView(head);

        // the connection, always in view
        LinearLayout conn = ui.card(null);
        linkState = ui.text(conn, "", 15, t().ink, true);
        ui.body(conn, "Typing works through the keyboard on its own. Connect for files and the remote: the phone then listens "
                + "for the handheld in the background, with a notification.");
        connectBtn = ui.button(conn, "Connect", true, v -> { if (LinkService.on()) disconnect(); else connect(); });

        // set-up reminder, only while something is missing
        setupCard = ui.card("Finish setting up");
        setupNote = ui.body(setupCard, "");
        ui.button(setupCard, "Set up the keyboard", false, v -> open(KeyboardActivity.class));

        ui.text(root, "Tools", 13, t().muted, true).setPadding(ui.dp(2), ui.dp(18), 0, ui.dp(4));
        LinearLayout r1 = ui.row();
        kbState = ui.tile(r1, "⌨️", "Keyboard", "Type on the handheld into any app", v -> open(KeyboardActivity.class));
        filesState = ui.tile(r1, "📁", "Files", "Send and receive, converted to fit", v -> open(FilesActivity.class));
        LinearLayout r2 = ui.row();
        remoteState = ui.tile(r2, "🖥️", "Remote", "This screen on the handheld", v -> open(RemoteActivity.class));
        linkTileState = ui.tile(r2, "📶", "Link", "Signal, speeds, link check", v -> open(LinkActivity.class));
        LinearLayout r3 = ui.row();
        recentState = ui.tile(r3, "📝", "Recent text", "A safety copy of what you typed", v -> open(RecentActivity.class));
        ui.tile(r3, "ℹ️", "About", "Help, iPhone, the handheld, privacy", v -> open(AboutActivity.class));
    }

    private void open(Class<?> c) { startActivity(new Intent(this, c)); }

    @Override
    protected void onResume() {
        super.onResume();
        Transfers.get().watch(this);
        refresh();
        Intent i = getIntent();
        if (i != null && ACTION_FILES.equals(i.getAction())) { setIntent(new Intent()); open(FilesActivity.class); }
        if (i != null && ACTION_REMOTE.equals(i.getAction())) { setIntent(new Intent()); startActivity(new Intent(this, RemoteActivity.class).setAction(ACTION_REMOTE)); }
    }

    @Override
    protected void onNewIntent(Intent i) { super.onNewIntent(i); setIntent(i); }

    @Override
    protected void onPause() { Transfers.get().unwatch(this); super.onPause(); }

    @Override public void onTransfers() { refresh(); }
    @Override public void onMessage(int ch, int type, byte[] p, float snr) { refresh(); }

    @Override
    protected void refresh() {
        if (linkState == null) return;
        boolean on = LinkService.on();
        linkState.setText(linkLine());
        linkState.setTextColor(on ? t().green : t().ink);
        connectBtn.setText(on ? "Disconnect" : "Connect");

        boolean mic = hasMic(), enabled = keyboardOn();
        StringBuilder miss = new StringBuilder();
        if (!mic) miss.append("Allow the microphone. ");
        if (!enabled) miss.append("Turn on the Whisper Tools keyboard. ");
        setupCard.setVisibility(miss.length() == 0 ? View.GONE : View.VISIBLE);
        setupNote.setText(miss.toString().trim());

        state(kbState, mic && enabled ? (Helper.on() ? "Ready, with the helper" : "Ready") : "Needs setting up", mic && enabled);
        int going = 0;
        for (Transfers.Item it : Transfers.get().items) if (!it.finished) going++;
        state(filesState, going > 0 ? going + (going == 1 ? " file" : " files") + " on the way" : "", true);
        state(remoteState, LinkService.remoteOn() ? "Showing on the handheld" : "", true);
        Link l = Link.get();
        state(linkTileState, !on ? "" : l.fastDownTrained() ? "Measured" : l.lastHeard > 0 ? "Hearing the handheld" : "Waiting", true);
        String rt = Recent.get(this);
        state(recentState, rt.isEmpty() ? "" : rt.length() + " characters kept", true);
    }

    private void state(TextView v, String s, boolean good) {
        v.setText(s);
        v.setTextColor(good ? t().green : t().warn);
        v.setVisibility(s.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private boolean keyboardOn() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList()) if (i.getPackageName().equals(getPackageName())) return true;
        return false;
    }

    static boolean keyboardChosen(android.content.Context c) {
        String current = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
        return current != null && current.startsWith(c.getPackageName());
    }

    private String version() {
        try { PackageInfo p = getPackageManager().getPackageInfo(getPackageName(), 0); return p.versionName; }
        catch (Exception e) { return ""; }
    }
}
