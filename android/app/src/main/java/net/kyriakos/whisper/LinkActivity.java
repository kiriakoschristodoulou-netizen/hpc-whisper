package net.kyriakos.whisper;

import android.content.Intent;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.core.content.FileProvider;

import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Locale;

/** The link: connect, what the phone hears, the link check with each channel's speed, and the diagnostics recording. */
public class LinkActivity extends ToolActivity implements PairCheck.Watcher {
    private static final int RECORD_SECONDS = 30;
    private TextView state, speeds, received, recState, pairText;
    private Button connectBtn, recBtn;
    private MeterView meter;
    private int unreadable;
    private Receiver.Frame lastFrame;
    private long lastClassic;
    private boolean recording;
    private String fastUp = "", fastDown = "";

    @Override protected String title() { return "Link"; }

    @Override
    protected void build() {
        LinearLayout c = ui.card("Connection");
        ui.body(c, "Run Whisper Tools on the handheld and keep the phone close to it, its media volume at about half.");
        meter = new MeterView(this);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, ui.dp(32));
        mlp.topMargin = ui.dp(12);
        c.addView(meter, mlp);
        state = ui.text(c, "", 14, t().ink, true);
        state.setPadding(0, ui.dp(8), 0, 0);
        received = ui.text(c, "", 15, t().ink, false);
        received.setTypeface(Typeface.MONOSPACE);
        received.setPadding(0, ui.dp(6), 0, 0);
        connectBtn = ui.button(c, "Connect", true, v -> { if (LinkService.on()) { if (recording) finishRecording(false); disconnect(); } else connect(); });

        LinearLayout pc = ui.card("Pair");
        ui.body(pc, "Run this once with each new phone or handheld, in a quiet room. Started here, the phone first finds how "
                + "loud it can play without a side-sound, then both devices play a 3-second test sound (beeps) in turn and "
                + "measure how well they hear each other; each side then adjusts itself. It can also be started on the handheld.");
        pairText = ui.text(pc, "", 14, t().ink, false);
        pairText.setPadding(0, ui.dp(6), 0, 0);
        ui.button(pc, "Pair", true, v -> pair());

        LinearLayout chk = ui.card("Link check");
        ui.body(chk, "Measures the fast channels, which carry files and the remote, in both directions: a soft hiss from "
                + "each side for a few seconds.");
        speeds = ui.text(chk, "", 14, t().ink, false);
        speeds.setPadding(0, ui.dp(6), 0, 0);
        ui.button(chk, "Check the link", false, v -> checkLink());

        LinearLayout diag = ui.card("Diagnostics");
        ui.body(diag, "If letters go missing, record what this phone hears while you type on the handheld, and send the "
                + "recording to whoever is helping you. It is sound only, kept on this phone until you share it.");
        recState = ui.text(diag, "", 14, t().ink, true);
        recBtn = ui.button(diag, "Record " + RECORD_SECONDS + " seconds", false, v -> record());
    }

    @Override
    protected void refresh() {
        boolean on = LinkService.on();
        Link l = Link.get();
        connectBtn.setText(on ? "Disconnect" : "Connect");
        StringBuilder s = new StringBuilder(linkLine());
        if (on && (l.lastHeard > 0 || lastFrame != null)) {
            if (l.handheldAnswers) s.append(l.speakerWorks() ? ", and it hears this phone" : "; this phone's speaker could not be opened");
            else if (lastFrame != null && lastFrame.ms > 0) s.append(" (the handheld types in Classic: text only, nothing is confirmed)");
        } else if (on) s.append(" (").append(l.listener.sourceName).append(" microphone)");
        if (unreadable > 0) s.append(". ").append(unreadable).append(" pieces too weak to read");
        state.setText(s.toString());
        state.setTextColor(t().ink);
        StringBuilder sp = new StringBuilder();
        sp.append("Typing (silent): about 0.8 kbit/s, or 2 kbit/s on the wide channel\n");
        sp.append("Fast, handheld → phone: ").append(fastUp.isEmpty() ? "not measured" : fastUp).append("\n");
        sp.append("Fast, phone → handheld: ").append(l.fastDownTrained() ? kbps(l.sendMap(Channel.FD)) : fastDown.isEmpty() ? "not measured" : fastDown);
        if (on && l.listener.measuredRate > 0) sp.append(String.format(Locale.US, "\nMicrophone runs at %.0f samples/s", l.listener.measuredRate));
        if (on) sp.append("\nFrames from the handheld: ").append(l.listener.framesW3).append(" read, ").append(l.listener.failsW3).append(" not readable");
        speeds.setText(sp.toString());
        if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    private void pair() {
        if (!LinkService.on()) { if (connect()) handler.postDelayed(this::pair, 1200); return; }
        PairCheck.get().start();
    }

    @Override public void onPair() { runOnUiThread(this::showPair); }

    private void showPair() {
        PairCheck p = PairCheck.get();
        StringBuilder s = new StringBuilder(p.note);
        if (p.mine != null) s.append("\n\nThis phone hears the handheld: ").append(bands(p.mine));
        if (p.mine != null) s.append(String.format(Locale.US, "\nThe handheld's sound runs at %.1f%% of its stated rate", p.mine.scale10k / 100.0));
        if (p.theirs != null) s.append("\nThe handheld hears this phone: ").append(bands(p.theirs));
        if (p.theirs != null) s.append(Link.get().answersOnFast
                ? "\nDecided: the silent band does not reach the handheld, so this phone answers on the fast channel (audible hiss)."
                : "\nDecided: this phone answers on the silent channel.");
        s.append(String.format(Locale.US, "\nThis phone's silent sound: %d %% of full loudness", Math.round(Link.get().silentLevel * 100)));
        if (!p.steps.isEmpty()) {
            s.append("\n\nSteps:");
            for (String st : p.steps) s.append("\n").append(st);
        }
        pairText.setText(s.toString().trim());
    }

    private static String bands(net.kyriakos.whisper.w3.Pair.Result r) {
        return db(r.band10(500, 4000)) + " (speech band), " + db(r.band10(5000, 12000)) + " (middle), "
                + db(r.band10(13000, 18000)) + " (high), " + db(r.band10(20000, 21200)) + " (silent band)"
                + (r.clipped ? "; too loud: lower the volume" : "");
    }
    private static String db(int tenths) { return tenths < 60 ? "not heard" : (tenths / 10) + " dB"; }

    @Override protected void onResume() { super.onResume(); PairCheck.get().watch(this); showPair(); }
    @Override protected void onDestroy() { PairCheck.get().unwatch(this); super.onDestroy(); }

    private void checkLink() {
        if (!LinkService.on()) { if (connect()) handler.postDelayed(this::checkLink, 1200); return; }
        Link l = Link.get();
        // the handheld trains the fast channel up when asked; the phone trains the fast channel down itself
        l.send(Channel.SD, Link.T_CHECK, new byte[]{(byte) Channel.FU});
        handler.postDelayed(() -> l.send(Channel.FD, Link.T_TRAIN, new byte[0]), 2500);
        fastUp = "measuring...";
        fastDown = "measuring...";
        refresh();
        handler.postDelayed(() -> {
            if (fastUp.equals("measuring...")) fastUp = "no answer (is Whisper Tools 3 running on the handheld?)";
            if (!Link.get().fastDownTrained()) fastDown = "no answer yet";
            refresh();
        }, 9000);
    }

    @Override public void onFrame(Receiver.Frame f) {
        lastFrame = f;
        if (f.ms > 0) lastClassic = System.currentTimeMillis();
        Mirror mirror = Link.get().text.mirror;
        String s = Keys.show(mirror.text(0, mirror.L, "·"));
        if (s.length() > 300) s = "…" + s.substring(s.length() - 300);
        received.setText(s);
        Recent.add(this, mirror);
        refresh();
    }
    @Override public void onUnreadable() { unreadable++; }
    @Override public void onLevels(float[] lv) { meter.set(lv); }
    @Override public void onProblem(String m) { state.setText(m); state.setTextColor(t().warn); }
    @Override public void onTrain(int ch, float[] snr) {
        if (ch == Channel.FU) { fastUp = kbps(BitMap.fromSnr(Channel.get(ch), 1, snr)); refresh(); }
    }
    @Override public void onMessage(int ch, int type, byte[] p, float snr) { if (type == Link.T_MAP) refresh(); }

    @Override
    protected void onPause() { if (recording) finishRecording(false); meter.clear(); super.onPause(); }

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
                recState.setText("Recording... type on the handheld (" + Math.max(0, left) + " s)");
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
            File f = new File(getCacheDir(), "whisper-tools-recording.wav");
            writeWav(f, pcm, listener.rate);
            String saved = saveToDownloads(f);
            recState.setText("Recorded " + (pcm.length / Math.max(1, listener.rate)) + " s (" + listener.sourceName
                    + " microphone)." + (saved != null ? " Saved in Downloads as " + saved + "." : "")
                    + " Send it as a file or document: apps that send voice messages squeeze the sound and cut away the high tones that matter.");
            Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", f);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("application/octet-stream");
            i.putExtra(Intent.EXTRA_STREAM, uri);
            i.putExtra(Intent.EXTRA_SUBJECT, "Whisper Tools recording");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "Send the recording"));
        } catch (Exception e) {
            recState.setText("The recording could not be saved: " + e.getMessage());
        }
    }

    private String saveToDownloads(File f) {
        if (Build.VERSION.SDK_INT < 29) return null;
        try {
            String name = "Whisper-Tools-recording-" + new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new java.util.Date()) + ".wav";
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
