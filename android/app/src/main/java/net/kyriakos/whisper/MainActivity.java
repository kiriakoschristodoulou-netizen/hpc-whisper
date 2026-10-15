package net.kyriakos.whisper;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.media.projection.MediaProjectionManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.FileProvider;

import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Locale;

/**
 * HPC Whisper: setting up the keyboard, the connection to the handheld (with
 * a link check), files, the picture remote, a safety copy of recent text and
 * diagnostics. Created by Kyriakos Christodoulou. No internet: nothing leaves
 * the phone.
 */
public class MainActivity extends Activity implements Link.Client, Transfers.Watcher {
    public static final String ACTION_FILES = "net.kyriakos.whisper.FILES", ACTION_REMOTE = "net.kyriakos.whisper.REMOTE";
    private static final int ASK_MIC = 1, ASK_SCREEN = 2, PICK_FILE = 3, RECORD_SECONDS = 30;
    private static final String PAGE = "https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Mirror mirror = new Mirror();
    private Ui ui;
    private TextView micState, kbState, pickState, helperState, linkState, received, speeds, recState, remoteState, recentText;
    private Button connectBtn, recBtn, remoteBtn;
    private MeterView meter;
    private LinearLayout filesList, filesCard;
    private int unreadable = 0;
    private Receiver.Frame lastFrame;
    private boolean recording, attached;
    private String fastUp = "", fastDown = "";

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        ui = new Ui(this);
        ui.page();
        build();
        handleAction(getIntent());
    }

    @Override
    protected void onNewIntent(Intent i) { super.onNewIntent(i); handleAction(i); }

    private void handleAction(Intent i) {
        if (i == null) return;
        if (ACTION_REMOTE.equals(i.getAction())) askScreen();
        if (ACTION_FILES.equals(i.getAction()) && filesCard != null)
            handler.postDelayed(() -> ((android.widget.ScrollView) ui.root.getParent()).smoothScrollTo(0, filesCard.getTop()), 300);
    }

    private Theme t() { return ui.t; }

    // ---------- the screen ----------
    private void build() {
        LinearLayout root = ui.root;
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.ic_launcher);
        head.addView(icon, new LinearLayout.LayoutParams(ui.dp(56), ui.dp(56)));
        LinearLayout ht = new LinearLayout(this);
        ht.setOrientation(LinearLayout.VERTICAL);
        ht.setPadding(ui.dp(14), 0, 0, 0);
        ui.text(ht, "HPC Whisper", 24, t().ink, true);
        ui.text(ht, "Version " + version() + " · by Kyriakos Christodoulou", 13, t().muted, false);
        head.addView(ht);
        root.addView(head);
        ui.text(root, "Type on a Windows CE handheld PC, such as the HP Jornada 720, and the text goes straight into any app "
                + "on this phone. Send files both ways, and see this phone's screen on the handheld. It all travels as sound: "
                + "no cable, no network.", 15, t().ink, false).setPadding(0, ui.dp(12), 0, 0);

        // connection
        LinearLayout link = ui.card("Connection");
        ui.body(link, "Run HPC Whisper 3 on the handheld and keep the phone close to it. While connected, this phone listens "
                + "for the handheld even in the background (files, the remote), and shows a notification.");
        meter = new MeterView(this);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, ui.dp(32));
        mlp.topMargin = ui.dp(12);
        link.addView(meter, mlp);
        linkState = ui.text(link, "Not connected", 14, t().ink, true);
        linkState.setPadding(0, ui.dp(8), 0, 0);
        speeds = ui.text(link, "", 13, t().muted, false);
        received = ui.text(link, "", 15, t().ink, false);
        received.setTypeface(Typeface.MONOSPACE);
        received.setPadding(0, ui.dp(6), 0, 0);
        connectBtn = ui.button(link, "Connect", true, v -> toggleConnect());
        ui.button(link, "Check the link", false, v -> checkLink());

        // keyboard
        LinearLayout setup = ui.card("Set up the keyboard");
        micState = ui.step(setup, "1", "Allow the microphone");
        ui.button(setup, "Allow the microphone", false, v -> requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, ASK_MIC));
        kbState = ui.step(setup, "2", "Turn on the HPC Whisper keyboard");
        ui.button(setup, "Open keyboard settings", false, v -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        pickState = ui.step(setup, "3", "Switch to it when you want to type");
        ui.button(setup, "Choose keyboard", false, v -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        });
        helperState = ui.step(setup, "4", "The helper (optional)");
        ui.body(setup, "Lets the handheld press Send (Alt+S on the handheld), go Back, Home or to Recent apps, and tap on this "
                + "screen through the remote. It acts only on what you ask from the handheld, and reads nothing. In the list, "
                + "find HPC Whisper (under Installed apps or Downloaded apps) and turn it on.");
        ui.button(setup, "Open accessibility settings", false, v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        ui.body(setup, "In any app, tap a text field, switch to HPC Whisper and type on the handheld. Tab moves between fields, "
                + "Ctrl+C, Ctrl+V and the arrows work as on a computer. New text is underlined for a moment while it may still "
                + "change. Tap \"Keyboard\" on the bar to go back to your usual keyboard.").setPadding(0, ui.dp(12), 0, 0);

        LinearLayout tryIt = ui.card("Try the keyboard");
        ui.body(tryIt, "Tap the box, switch to HPC Whisper, and type on the handheld.");
        EditText box = new EditText(this);
        box.setMinLines(3);
        box.setGravity(Gravity.TOP);
        box.setTextColor(t().ink);
        box.setHintTextColor(t().muted);
        box.setHint("Text from the handheld appears here");
        tryIt.addView(box);

        // files
        filesCard = ui.card("Files");
        ui.body(filesCard, "To the handheld: Share → HPC Whisper in any app, or pick a file here. Pictures are fitted to its "
                + "screen, PDF pages become pictures, sound becomes a WAV it can play. From the handheld: files arrive in "
                + "Downloads/HPC Whisper while connected.");
        filesList = new LinearLayout(this);
        filesList.setOrientation(LinearLayout.VERTICAL);
        filesCard.addView(filesList);
        ui.button(filesCard, "Send a file", false, v -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            startActivityForResult(i, PICK_FILE);
        });
        ui.button(filesCard, "Clear the list", false, v -> Transfers.get().clearFinished());

        // remote
        LinearLayout remote = ui.card("Remote");
        ui.body(remote, "Shows this phone's screen on the handheld, in grey: a small change arrives in about a second, a whole new "
                + "screen in 5 to 15 seconds. The phone hisses softly while its screen changes. Taps from the handheld need "
                + "the helper (step 4 above). Android asks each time before the screen is shared.");
        remoteState = ui.text(remote, "", 14, t().ink, true);
        remoteBtn = ui.button(remote, "Start the remote", true, v -> { if (LinkService.remoteOn()) stopRemote(); else askScreen(); });

        // recent text
        LinearLayout recent = ui.card("Recent text");
        ui.body(recent, "A copy of the last text from the handheld, kept only on this phone, in case it went into a field that "
                + "closed.");
        recentText = ui.text(recent, "", 14, t().ink, false);
        recentText.setTypeface(Typeface.MONOSPACE);
        recentText.setPadding(0, ui.dp(8), 0, 0);
        recentText.setTextIsSelectable(true);
        ui.button(recent, "Copy", false, v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cm != null) { cm.setPrimaryClip(ClipData.newPlainText("HPC Whisper", Recent.get(this))); Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show(); }
        });
        ui.button(recent, "Clear", false, v -> { Recent.clear(this); showRecent(); });

        // diagnostics
        LinearLayout diag = ui.card("Diagnostics");
        ui.body(diag, "If letters go missing, connect, record what this phone hears while you type on the handheld, and send "
                + "the recording to whoever is helping you. It is sound only, kept on this phone until you share it.");
        recState = ui.text(diag, "", 14, t().ink, true);
        recBtn = ui.button(diag, "Record " + RECORD_SECONDS + " seconds", false, v -> record());

        LinearLayout notes = ui.card("Notes");
        ui.text(notes, "iPhone", 15, t().ink, true);
        ui.text(notes, "Apple does not let keyboards use the microphone, so an iPhone keyboard is impossible. On an iPhone (or "
                + "any other phone) use the receiver page in the browser instead, with Copy and Share:", 14, t().ink, false);
        TextView pg = ui.text(notes, PAGE, 14, t().link, false);
        pg.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(PAGE))));
        ui.text(notes, "On the handheld", 15, t().ink, true).setPadding(0, ui.dp(12), 0, 0);
        ui.text(notes, "Run whisper.exe from the HPC-Whisper-3 download. It needs an ARM processor and Windows CE 3.0 or later. "
                + "Older handheld programs (version 1) still work with the keyboard; files and the remote need version 3.", 14, t().ink, false);
        ui.text(notes, "Privacy", 15, t().ink, true).setPadding(0, ui.dp(12), 0, 0);
        ui.text(notes, "This app has no internet access. The microphone is used only while the keyboard is open, while connected "
                + "(a notification shows it), or while you record here. The screen is shared only while the remote runs.", 14, t().ink, false);
    }

    private String version() {
        try { PackageInfo p = getPackageManager().getPackageInfo(getPackageName(), 0); return p.versionName; }
        catch (Exception e) { return ""; }
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshSetup();
        Transfers.get().watch(this);
        if (LinkService.on() && !attached) attached = Link.get().attach(this, this);
        showFiles();
        showRecent();
        showLink();
        handler.post(ticker);
    }

    @Override
    protected void onPause() {
        if (recording) finishRecording(false);
        Transfers.get().unwatch(this);
        if (attached) { Link.get().detach(this); attached = false; }
        handler.removeCallbacks(ticker);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) refreshSetup();
    }

    private final Runnable ticker = new Runnable() {
        @Override public void run() { showLink(); handler.postDelayed(this, 1000); }
    };

    private void refreshSetup() {
        boolean mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
        micState.setText(mic ? "✓ Allowed" : "Needed to hear the handheld");
        micState.setTextColor(mic ? t().green : t().warn);
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        boolean enabled = false;
        if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList())
            if (i.getPackageName().equals(getPackageName())) enabled = true;
        kbState.setText(enabled ? "✓ On" : "Turn on \"HPC Whisper\" in the list");
        kbState.setTextColor(enabled ? t().green : t().warn);
        String current = Settings.Secure.getString(getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
        boolean chosen = current != null && current.startsWith(getPackageName());
        pickState.setText(chosen ? "✓ HPC Whisper is the keyboard now" : "Switch whenever you want to type on the handheld");
        pickState.setTextColor(chosen ? t().green : t().muted);
        helperState.setText(Helper.on() ? "✓ On" : "Off: typing works without it");
        helperState.setTextColor(Helper.on() ? t().green : t().muted);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        refreshSetup();
        if (code == ASK_MIC && res.length > 0 && res[0] != PackageManager.PERMISSION_GRANTED)
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
        if (code == ASK_MIC && res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED && pendingConnect) { pendingConnect = false; connect(); }
    }

    // ---------- connection ----------
    private boolean pendingConnect;

    private void toggleConnect() { if (LinkService.on()) disconnect(); else connect(); }

    private boolean connect() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pendingConnect = true;
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, ASK_MIC);
            return false;
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 9);
        LinkService.start(this);
        handler.postDelayed(() -> { if (!attached) attached = Link.get().attach(this, this); showLink(); }, 300);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        return true;
    }

    private void disconnect() {
        if (recording) finishRecording(false);
        if (attached) { Link.get().detach(this); attached = false; }
        LinkService.stop(this);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        meter.clear();
        handler.postDelayed(this::showLink, 300);
    }

    private void showLink() {
        boolean on = LinkService.on();
        Link l = Link.get();
        connectBtn.setText(on ? "Disconnect" : "Connect");
        StringBuilder s = new StringBuilder();
        if (!on) s.append("Not connected");
        else if (l.lastHeard > 0 || lastFrame != null) {
            long ago = (System.currentTimeMillis() - Math.max(l.lastHeard, lastHeardClassic)) / 1000;
            s.append(ago < 5 ? "Hearing the handheld" : "Connected: heard the handheld " + ago + " s ago");
            if (l.handheldAnswers) s.append(l.speakerWorks() ? ", and it hears this phone" : "; this phone's speaker could not be opened");
            else if (lastFrame != null && lastFrame.ms > 0) s.append(" (an older handheld program: typing only)");
        } else s.append("Connected: waiting for the handheld (").append(l.listener.sourceName).append(" microphone)");
        if (unreadable > 0) s.append(". ").append(unreadable).append(" pieces too weak to read");
        linkState.setText(s.toString());
        StringBuilder sp = new StringBuilder();
        if (!fastUp.isEmpty()) sp.append("Fast, handheld → phone: ").append(fastUp).append("\n");
        if (l.fastDownTrained()) sp.append("Fast, phone → handheld: ").append(kbps(l.sendMap(Channel.FD))).append("\n");
        else if (!fastDown.isEmpty()) sp.append(fastDown).append("\n");
        if (on && l.listener.measuredRate > 0) sp.append(String.format(Locale.US, "Microphone runs at %.0f samples/s", l.listener.measuredRate));
        speeds.setText(sp.toString().trim());
        speeds.setVisibility(sp.length() == 0 ? View.GONE : View.VISIBLE);
        remoteBtn.setText(LinkService.remoteOn() ? "Stop the remote" : "Start the remote");
        String rs = LinkService.remoteState();
        remoteState.setText(rs);
        remoteState.setVisibility(rs.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private long lastHeardClassic = 0;

    /** Bits a symbol to kbit/s after error protection (about 85 % of the raw rate). */
    private static String kbps(BitMap m) {
        float k = m.bitsPerSymbol() / (Channel.SYM / (float) Channel.RATE) / 1000f * 0.85f;
        return String.format(Locale.US, "about %.1f kbit/s (%d bits a symbol)", k, m.bitsPerSymbol());
    }

    private void checkLink() {
        if (!LinkService.on()) { if (!connect()) return; handler.postDelayed(this::checkLink, 1200); return; }
        Link l = Link.get();
        // the handheld trains the fast channel up when asked; the phone trains the fast channel down itself
        l.send(Channel.SD, Link.T_CHECK, new byte[]{(byte) Channel.FU});
        handler.postDelayed(() -> l.send(Channel.FD, Link.T_TRAIN, new byte[0]), 2500);
        fastUp = "measuring…";
        fastDown = "Fast, phone → handheld: measuring…";
        showLink();
        handler.postDelayed(() -> {
            if (fastUp.equals("measuring…")) fastUp = "no answer (is HPC Whisper 3 running on the handheld?)";
            if (!Link.get().fastDownTrained()) fastDown = "Fast, phone → handheld: no answer yet";
            showLink();
        }, 9000);
    }

    // Link.Client
    @Override public void onFrame(Receiver.Frame f) {
        lastFrame = f;
        if (f.ms > 0) lastHeardClassic = System.currentTimeMillis();
        mirror.apply(f, System.currentTimeMillis());
        String s = Keys.show(mirror.text(0, mirror.L, "·"));
        if (s.length() > 300) s = "…" + s.substring(s.length() - 300);
        received.setText(s);
        Recent.add(this, mirror);
        showLink();
    }
    @Override public void onUnreadable() { unreadable++; }
    @Override public void onLevels(float[] l) { meter.set(l); }
    @Override public void onProblem(String m) { linkState.setText(m); linkState.setTextColor(t().warn); }
    @Override public void onTrain(int ch, float[] snr) {
        if (ch == Channel.FU) { fastUp = kbps(BitMap.fromSnr(Channel.get(ch), 1, snr)); showLink(); }
    }
    @Override public void onMessage(int ch, int type, byte[] p, float snr) {
        if (type == Link.T_MAP) showLink();
        if (type == Link.T_INPUT) showLink();
    }

    // ---------- files ----------
    @Override public void onTransfers() { showFiles(); }

    private void showFiles() {
        if (filesList == null) return;
        filesList.removeAllViews();
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
            filesList.addView(row);
        }
        if (Transfers.get().items.isEmpty()) ui.text(filesList, "No files yet.", 13, t().muted, false).setPadding(0, ui.dp(8), 0, 0);
        else ui.text(filesList, "Hold a file that is on its way to cancel it.", 12, t().muted, false).setPadding(0, ui.dp(6), 0, 0);
    }

    private void open(Transfers.Item it) {
        try {
            Uri u = it.saved;
            if ("file".equals(u.getScheme())) u = FileProvider.getUriForFile(this, getPackageName() + ".files", new File(u.getPath()));
            Intent i = new Intent(Intent.ACTION_VIEW).setDataAndType(u, Convert.mimeOf(it.name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, it.name));
        } catch (Exception e) { Toast.makeText(this, "It cannot be opened here: find it in Downloads/HPC Whisper", Toast.LENGTH_LONG).show(); }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == PICK_FILE && result == RESULT_OK && data != null && data.getData() != null) {
            Intent i = new Intent(this, ShareActivity.class).setAction(Intent.ACTION_SEND)
                    .putExtra(Intent.EXTRA_STREAM, data.getData()).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(i);
        } else if (code == ASK_SCREEN) {
            if (result == RESULT_OK && data != null) {
                Intent s = new Intent(this, LinkService.class).setAction(LinkService.REMOTE)
                        .putExtra(LinkService.EXTRA_CODE, result).putExtra(LinkService.EXTRA_DATA, data);
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(s); else startService(s);
                handler.postDelayed(() -> { if (!attached) attached = Link.get().attach(this, this); showLink(); }, 500);
            } else Toast.makeText(this, "The screen was not shared", Toast.LENGTH_SHORT).show();
        }
    }

    // ---------- remote ----------
    private void askScreen() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { connect(); return; }
        MediaProjectionManager mpm = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        if (mpm != null) startActivityForResult(mpm.createScreenCaptureIntent(), ASK_SCREEN);
    }

    private void stopRemote() {
        LinkService s = LinkService.running;
        if (s != null) s.stopRemote();
        handler.postDelayed(this::showLink, 200);
    }

    // ---------- recent text ----------
    private void showRecent() {
        String s = Recent.get(this);
        if (s.length() > 600) s = "…" + s.substring(s.length() - 600);
        recentText.setText(s.isEmpty() ? "Nothing yet." : s);
    }

    // ---------- diagnostics ----------
    private void record() {
        if (recording) return;
        if (!LinkService.on()) { if (connect()) handler.postDelayed(this::record, 1200); return; }
        Listener listener = Link.get().listener;
        if (!listener.isRunning()) { recState.setText("The microphone is not open"); return; }
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
        Listener listener = Link.get().listener;
        short[] pcm = listener.takeTape();
        if (!share || pcm == null || pcm.length == 0) { recState.setText(""); return; }
        try {
            File f = new File(getCacheDir(), "hpc-whisper-recording.wav");
            writeWav(f, pcm, listener.rate);
            String saved = saveToDownloads(f);
            recState.setText("Recorded " + (pcm.length / Math.max(1, listener.rate)) + " s (" + listener.sourceName
                    + " microphone)." + (saved != null ? " Saved in Downloads as " + saved + "." : "")
                    + " Send it as a file or document: apps that send voice messages squeeze the sound and cut away the high tones that matter.");
            Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", f);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("application/octet-stream");
            i.putExtra(Intent.EXTRA_STREAM, uri);
            i.putExtra(Intent.EXTRA_SUBJECT, "HPC Whisper recording");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "Send the recording"));
        } catch (Exception e) {
            recState.setText("The recording could not be saved: " + e.getMessage());
        }
    }

    private String saveToDownloads(File f) {
        if (Build.VERSION.SDK_INT < 29) return null;
        try {
            String name = "HPC-Whisper-recording-" + new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new java.util.Date()) + ".wav";
            android.content.ContentValues v = new android.content.ContentValues();
            v.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name);
            v.put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "audio/wav");
            v.put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS);
            Uri uri = getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri == null) return null;
            try (java.io.OutputStream o = getContentResolver().openOutputStream(uri);
                 java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                byte[] b = new byte[65536]; int n;
                while ((n = in.read(b)) > 0) o.write(b, 0, n);
            }
            return name;
        } catch (Exception e) { return null; }
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
