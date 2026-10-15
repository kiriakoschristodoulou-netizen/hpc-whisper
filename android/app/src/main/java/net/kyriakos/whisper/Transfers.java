package net.kyriakos.whisper;

import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.FileRecv;
import net.kyriakos.whisper.w3.FileSend;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.zip.Inflater;

/**
 * Files between the phone and the handheld (docs/FORMAT3.md, section 6).
 * To the handheld: on the fast channel down, one file after another. From
 * the handheld: on whichever channel it uses; answers go on the silent
 * channel down, and the file lands in Downloads/HPC Whisper.
 */
public final class Transfers implements Link.Client {
    public static final int KIND_OTHER = 0, KIND_PICTURE = 1, KIND_SOUND = 2, KIND_TEXT = 3, KIND_DOCUMENT = 4, ZLIB = 0x80;
    static final int MAX_IN = 8 << 20;

    public interface Watcher { void onTransfers(); }

    public static final class Item {
        public final String name; public final boolean out; public final int size;
        public String state = "Waiting"; public float progress; public boolean finished, ok; public Uri saved; public String savedName;
        public long started; FileSend send; FileRecv recv; long doneAt;
        Item(String name, boolean out, int size) { this.name = name; this.out = out; this.size = size; }
    }

    private static Transfers instance;
    public static synchronized Transfers get() { if (instance == null) instance = new Transfers(); return instance; }

    private final Handler main = new Handler(Looper.getMainLooper());
    public final List<Item> items = new CopyOnWriteArrayList<>();
    private final CopyOnWriteArrayList<Watcher> watchers = new CopyOnWriteArrayList<>();
    private Context app;
    private int nextId = (int) (System.currentTimeMillis() & 0x7FFF);
    private boolean ticking;
    private long trainAsked = 0;

    private Transfers() { }

    public void watch(Watcher w) { if (!watchers.contains(w)) watchers.add(w); }
    public void unwatch(Watcher w) { watchers.remove(w); }
    private void changed() { for (Watcher w : watchers) w.onTransfers(); }

    public void start(Context c) {
        app = c.getApplicationContext();
        if (!ticking) { ticking = true; main.post(tick); }
    }
    public void stop() { ticking = false; main.removeCallbacks(tick); }

    public boolean busy() {
        for (Item i : items) if (!i.finished) return true;
        return false;
    }

    /** Queues a file for the handheld (already converted). */
    public Item send(String name, int kind, byte[] data) {
        Item it = new Item(name, true, data.length);
        nextId = (nextId + 1) & 0xFFFF;
        it.send = new FileSend(nextId, name, kind, data);
        items.add(it);
        changed();
        return it;
    }

    public void cancel(Item it) {
        if (it.finished) return;
        if (it.send != null) Link.get().send(Channel.FD, Link.T_FILE_CANCEL, it.send.cancel());
        it.finished = true; it.ok = false; it.state = "Cancelled"; it.doneAt = System.currentTimeMillis();
        changed();
    }

    public void clearFinished() { items.removeIf(i -> i.finished); changed(); }

    /** Seconds a file of this many bytes takes to the handheld (about 7 kbit/s untrained, more once measured). */
    public static int estimateSeconds(int bytes) {
        int packets = Math.max(1, (bytes + FileSend.PACKET - 1) / FileSend.PACKET);
        return Math.round(packets * 1.25f + packets / 16f * 0.6f + 2);
    }

    private Item current() {
        for (Item i : items) if (i.out && !i.finished) return i;
        return null;
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!ticking) return;
            step();
            main.postDelayed(this, 40);
        }
    };

    private void step() {
        Link link = Link.get();
        long now = System.currentTimeMillis();
        // out: one file at a time, one frame queued ahead at most
        Item it = current();
        if (it != null && link.running() && link.queued() == 0) {
            if (it.started == 0) {
                it.started = now;
                // the fast channel down is measured first, once in a while
                if (!link.fastDownTrained() && now - trainAsked > 60000) { trainAsked = now; link.send(Channel.FD, Link.T_TRAIN, new byte[0]); }
            }
            long t = Math.max(now, link.playEndMs());
            FileSend.Msg m = it.send.next(t);
            if (m != null) {
                if (!link.send(Channel.FD, m.type, m.payload)) { it.state = "The phone's speaker is not available"; }
                else it.state = "Sending";
            }
            float p = it.send.progress();
            if (p != it.progress) { it.progress = p; changed(); }
            if (it.send.done || it.send.failed) {
                it.finished = true; it.doneAt = now;
                it.ok = it.send.done;
                it.state = it.send.failed ? "Stopped: the handheld does not answer"
                        : it.send.confirmedAll ? "On the handheld" : "Sent (the handheld could not confirm)";
                changed();
            }
        }
        // in: answers when the handheld goes quiet
        for (Item r : items) {
            if (r.out || r.recv == null) continue;
            if (r.recv.needDue(now) && now >= link.playEndMs()) {
                link.send(Channel.SD, Link.T_FILE_NEED, r.recv.need());
            }
            if (!r.finished && r.recv.complete()) finishIncoming(r, now);
        }
        // forget old finished incoming transfers' state (but keep them listed)
        for (Item r : items) if (r.finished && r.recv != null && now - r.doneAt > 120000) r.recv = null;
        if (unknownId >= 0 && now - unknownAt > FileRecv.QUIET_MS && now >= link.playEndMs()) {
            link.send(Channel.SD, Link.T_FILE_NEED, FileRecv.needOffer(unknownId));
            unknownId = -1;
        }
    }

    private int unknownId = -1;
    private long unknownAt;

    private Item incoming(int id) {
        for (Item r : items) if (!r.out && r.recv != null && r.recv.id == id) return r;
        return null;
    }

    @Override
    public void onMessage(int ch, int type, byte[] p, float snr) {
        long now = System.currentTimeMillis();
        switch (type) {
            case Link.T_FILE_NEED: {
                Item it = current();
                if (it != null) it.send.onNeed(p, now);
                break;
            }
            case Link.T_FILE_OFFER: {
                int id = FileRecv.idOf(p);
                Item r = incoming(id);
                if (r != null) { r.recv.onOffer(now); break; }
                FileRecv fr = FileRecv.fromOffer(p, now, MAX_IN);
                if (fr == null) break;
                String shown = fr.name;
                if ((fr.kind & ZLIB) != 0 && shown.endsWith(".z")) shown = shown.substring(0, shown.length() - 2);
                r = new Item(shown, false, fr.size);
                r.recv = fr; r.started = now; r.state = "Receiving";
                items.add(r);
                if (unknownId == id) unknownId = -1;
                changed();
                break;
            }
            case Link.T_FILE_DATA: {
                int id = FileRecv.idOf(p);
                Item r = incoming(id);
                if (r == null) { unknownId = id; unknownAt = now; break; }
                int before = r.recv.received();
                r.recv.onData(p, now);
                if (r.recv.received() != before) { r.progress = r.recv.received() / (float) r.recv.packets; changed(); }
                break;
            }
            case Link.T_FILE_CANCEL: {
                Item r = incoming(FileRecv.idOf(p));
                if (r != null && !r.finished) { r.finished = true; r.ok = false; r.state = "Cancelled on the handheld"; r.doneAt = now; changed(); }
                break;
            }
            default: break;
        }
    }

    private void finishIncoming(Item r, long now) {
        r.finished = true; r.doneAt = now; r.progress = 1;
        byte[] d = r.recv.data();
        if ((r.recv.kind & ZLIB) != 0) {
            d = inflate(d);
            if (d == null) { r.ok = false; r.state = "Arrived damaged"; changed(); return; }
        }
        try {
            r.saved = save(r.name, d);
            r.ok = true;
            r.state = "Saved in Downloads/HPC Whisper";
        } catch (Exception e) {
            r.ok = false; r.state = "Could not be saved: " + e.getMessage();
        }
        changed();
    }

    static byte[] inflate(byte[] z) {
        try {
            Inflater f = new Inflater();
            f.setInput(z);
            ByteArrayOutputStream o = new ByteArrayOutputStream(z.length * 3);
            byte[] b = new byte[65536];
            while (!f.finished()) {
                int n = f.inflate(b);
                if (n == 0 && (f.needsInput() || f.needsDictionary())) break;
                o.write(b, 0, n);
                if (o.size() > 64 << 20) return null;
            }
            f.end();
            return o.toByteArray();
        } catch (Exception e) { return null; }
    }

    private Uri save(String name, byte[] d) throws Exception {
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
            v.put(MediaStore.MediaColumns.MIME_TYPE, Convert.mimeOf(name));
            v.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/HPC Whisper");
            Uri uri = app.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri == null) throw new Exception("no place to save");
            try (OutputStream o = app.getContentResolver().openOutputStream(uri)) { o.write(d); }
            return uri;
        }
        File dir = new File(app.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "HPC Whisper");
        dir.mkdirs();
        File f = new File(dir, name);
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(d); }
        return Uri.fromFile(f);
    }
}
