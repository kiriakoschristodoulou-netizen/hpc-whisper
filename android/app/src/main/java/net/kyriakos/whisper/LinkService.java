package net.kyriakos.whisper;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.WindowManager;

import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.RemoteView;
import net.kyriakos.whisper.w3.Screen;

import java.nio.ByteBuffer;

/**
 * Keeps the connection to the handheld open while the app is in the
 * background: files both ways, and the picture remote. Shows a notification
 * the whole time (Android requires it, and you can stop it from there).
 */
public class LinkService extends Service implements Link.Client {
    public static final String STOP = "stop", REMOTE = "remote", EXTRA_CODE = "code", EXTRA_DATA = "data";
    static final String CHANNEL = "link";
    static final int NOTE = 1;

    static volatile LinkService running;
    public static boolean on() { return running != null; }
    public static boolean remoteOn() { LinkService s = running; return s != null && s.projection != null; }
    public static String remoteState() { LinkService s = running; return s == null ? "" : s.remoteState; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean attached;

    // remote
    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private HandlerThread capThread;
    private final RemoteView view = new RemoteView();
    private final Screen screen = new Screen();
    private volatile byte[] grey; private volatile int gw, gh;
    private volatile boolean fresh;
    private long lastCapture;
    String remoteState = "";
    private int screenFrames = 0;

    public static void start(Context c) {
        Intent i = new Intent(c, LinkService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
    }

    public static void stop(Context c) {
        c.startService(new Intent(c, LinkService.class).setAction(STOP));
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String a = intent == null ? null : intent.getAction();
        if (STOP.equals(a)) { stopAll(); return START_NOT_STICKY; }
        boolean remote = REMOTE.equals(a);
        foreground(remote);
        running = this;
        if (!attached) {
            attached = Link.get().attach(this, this);
            if (attached) {
                Link.get().attach(this, Transfers.get());
                Transfers.get().start(this);
                main.postDelayed(() -> Link.get().sayHello(false), 600);
            }
        }
        if (remote && intent != null) startRemote(intent.getIntExtra(EXTRA_CODE, 0), intent.getParcelableExtra(EXTRA_DATA));
        main.removeCallbacks(tick);
        main.post(tick);
        return START_NOT_STICKY;
    }

    private void foreground(boolean remote) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm != null && nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Connection to the handheld", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, LinkService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        b.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
         .setContentTitle("Whisper Tools is connected")
         .setContentText(remote ? "Showing this screen on the handheld" : "Listening for the handheld: files and the remote")
         .setContentIntent(open)
         .setOngoing(true)
         .addAction(new Notification.Action.Builder(null, "Stop", stop).build());
        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 29) {
            int type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE;
            if (remote) type |= ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION;
            startForeground(NOTE, n, type);
        } else startForeground(NOTE, n);
    }

    private void stopAll() {
        stopRemote();
        main.removeCallbacks(tick);
        Transfers.get().stop();
        if (attached) { Link.get().detach(Transfers.get()); Link.get().detach(this); attached = false; }
        running = null;
        stopForeground(true);
        stopSelf();
    }

    @Override public void onDestroy() { if (running == this) stopAll(); super.onDestroy(); }

    // ---------- the remote ----------

    private void startRemote(int code, Intent data) {
        if (data == null || projection != null) return;
        MediaProjectionManager mpm = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        try { projection = mpm.getMediaProjection(code, data); } catch (Exception e) { projection = null; }
        if (projection == null) { remoteState = "The screen could not be shared"; return; }
        projection.registerCallback(new MediaProjection.Callback() {
            @Override public void onStop() { main.post(LinkService.this::stopRemote); }
        }, main);
        DisplayMetrics dm = new DisplayMetrics();
        ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(dm);
        view.setScreen(dm.widthPixels, dm.heightPixels);
        int w = Math.max(2, dm.widthPixels / 2), h = Math.max(2, dm.heightPixels / 2);
        capThread = new HandlerThread("whisper-capture");
        capThread.start();
        Handler cap = new Handler(capThread.getLooper());
        reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2);
        reader.setOnImageAvailableListener(r -> capture(r), cap);
        display = projection.createVirtualDisplay("Whisper Tools remote", w, h, dm.densityDpi / 2,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader.getSurface(), null, cap);
        screen.resendAll();
        remoteState = "Showing this screen on the handheld";
        Link.get().send(Channel.SD, Link.T_INPUT, new byte[]{6});        // tells the handheld the remote is on
    }

    private void capture(ImageReader r) {
        Image img = null;
        try {
            img = r.acquireLatestImage();
            if (img == null) return;
            long now = System.currentTimeMillis();
            if (now - lastCapture < 350) return;              // a few pictures a second is plenty
            lastCapture = now;
            Image.Plane p = img.getPlanes()[0];
            ByteBuffer b = p.getBuffer();
            int w = img.getWidth(), h = img.getHeight(), ps = p.getPixelStride(), rs = p.getRowStride();
            byte[] g = grey != null && gw == w && gh == h ? new byte[w * h] : new byte[w * h];
            for (int y = 0; y < h; y++) {
                int o = y * rs;
                for (int x = 0; x < w; x++) {
                    int i = o + x * ps;
                    int rr = b.get(i) & 255, gg = b.get(i + 1) & 255, bb = b.get(i + 2) & 255;
                    g[y * w + x] = (byte) ((rr * 77 + gg * 150 + bb * 29) >> 8);
                }
            }
            byte[] pic;
            int pw, ph;
            synchronized (view) { pic = view.render(g, w, h); pw = view.picW(); ph = view.picH(); }
            synchronized (screen) { screen.set(pic, pw, ph, now); }
            grey = g; gw = w; gh = h;
            fresh = true;
        } catch (Exception ignored) {
        } finally { if (img != null) img.close(); }
    }

    /** The view changed: render the last capture again at once. */
    private void rerender() {
        byte[] g = grey;
        if (g == null) return;
        byte[] pic; int pw, ph;
        synchronized (view) { pic = view.render(g, gw, gh); pw = view.picW(); ph = view.picH(); }
        synchronized (screen) { screen.set(pic, pw, ph, System.currentTimeMillis()); }
    }

    void stopRemote() {
        if (projection == null) return;
        try { if (display != null) display.release(); } catch (Exception ignored) { }
        try { if (reader != null) reader.close(); } catch (Exception ignored) { }
        try { projection.stop(); } catch (Exception ignored) { }
        if (capThread != null) capThread.quitSafely();
        projection = null; display = null; reader = null; capThread = null;
        remoteState = "";
        Link.get().send(Channel.SD, Link.T_INPUT, new byte[]{7});
        if (running == this) foreground(false);
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (running != LinkService.this) return;
            Link link = Link.get();
            // the screen goes out when files are not using the channel
            if (projection != null && link.queued() == 0 && !Transfers.get().busy()) {
                long now = System.currentTimeMillis();
                byte[] m;
                synchronized (screen) { m = screen.next(now, now >= link.playEndMs() + 2000); }
                if (m != null) { link.send(Channel.FD, Link.T_SCREEN, m); screenFrames++; }
            }
            main.postDelayed(this, 50);
        }
    };

    @Override
    public void onMessage(int ch, int type, byte[] p, float snr) {
        if (type != Link.T_INPUT || p.length < 1) return;
        int kind = p[0] & 255;
        switch (kind) {
            case 1: case 2: case 3: {
                if (projection == null || p.length < (kind == 3 ? 9 : 5)) break;
                float[] a, b;
                synchronized (view) {
                    a = view.toPhone(u16(p, 1), u16(p, 3));
                    b = kind == 3 ? view.toPhone(u16(p, 5), u16(p, 7)) : a;
                }
                Helper.gesture(a[0], a[1], b[0], b[1], kind == 1 ? 60 : kind == 2 ? 700 : 300);
                break;
            }
            case 4:
                if (p.length >= 6) { synchronized (view) { view.setView(p[1], u16(p, 2), u16(p, 4)); } synchronized (screen) { screen.resendAll(); } rerender(); }
                break;
            case 5: synchronized (screen) { screen.resendAll(); } rerender(); break;
            case 6: if (projection == null) askForRemote(); break;
            case 7: stopRemote(); break;
            case 8:
                if (p.length >= 5) { synchronized (view) { view.scroll((short) u16(p, 1), (short) u16(p, 3)); } rerender(); }
                break;
            case 9:
                if (p.length >= 2) {
                    int k = p[1] & 255;
                    if (k == Keys.SEND) Helper.pressSend();
                    else if (k == Keys.BACK) Helper.global(Helper.BACK);
                    else if (k == Keys.HOME_SCREEN) Helper.global(Helper.HOME);
                    else if (k == Keys.RECENTS) Helper.global(Helper.RECENTS);
                }
                break;
            default: break;
        }
    }

    /** The handheld asks for the remote: sharing the screen needs a tap on the phone (Android asks each time). */
    private void askForRemote() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) return;
        Intent i = new Intent(this, MainActivity.class).setAction(MainActivity.ACTION_REMOTE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(this, 2, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        b.setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("The handheld asks for the remote")
         .setContentText("Tap to show this screen on the handheld").setContentIntent(pi).setAutoCancel(true);
        nm.notify(2, b.build());
    }

    private static int u16(byte[] p, int i) { return (p[i] & 255) << 8 | (p[i + 1] & 255); }
}
