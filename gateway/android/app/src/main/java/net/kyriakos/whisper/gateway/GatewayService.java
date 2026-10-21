package net.kyriakos.whisper.gateway;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.util.Random;

import net.kyriakos.whisper.gw.Gateway;
import net.kyriakos.whisper.gw.Session;

/**
 * Whisper Gateway: listens to the handheld through the microphone, answers
 * through the speaker, and does what it asks on the internet. Runs as a
 * foreground service so it keeps going with the screen off.
 */
public final class GatewayService extends Service {
    static final String ACTION_START = "net.kyriakos.whisper.gateway.START";
    static final String ACTION_STOP = "net.kyriakos.whisper.gateway.STOP";
    private static final int NOTE_ID = 1;
    private static final int RATE = 48000;

    private volatile boolean running;
    private Thread thread;
    private PowerManager.WakeLock wake;
    private volatile long dropSamples;        // our own sound, heard by our own microphone: not listened to

    static float volume(Context c) {
        return c.getSharedPreferences("gateway", MODE_PRIVATE).getInt("volume", 80) / 100f;
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) { stopAll(); return START_NOT_STICKY; }
        if (running) return START_STICKY;
        startForegroundNow();
        running = true;
        State.running = true; State.problem = ""; State.startedAt = System.currentTimeMillis();
        State.framesHeard = 0; State.turns = 0; State.bytesUp = 0; State.bytesDown = 0; State.connections = 0;
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null) {
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "whispergateway:listen");
            wake.acquire(12L * 60 * 60 * 1000);
        }
        thread = new Thread(this::run, "whisper-gateway");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
        return START_STICKY;
    }

    private void startForegroundNow() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm != null)
            nm.createNotificationChannel(new NotificationChannel("gateway", "Whisper Gateway", NotificationManager.IMPORTANCE_LOW));
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, "gateway") : new Notification.Builder(this);
        b.setContentTitle("Whisper Gateway is on")
                .setContentText("Listening for the handheld")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentIntent(pi)
                .setOngoing(true);
        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        else startForeground(NOTE_ID, n);
    }

    private void stopAll() {
        running = false;
        Thread t = thread;
        if (t != null) { try { t.join(2000); } catch (InterruptedException ignored) { } }
        State.running = false;
        if (wake != null && wake.isHeld()) wake.release();
        stopForeground(true);
        stopSelf();
    }

    @Override public void onDestroy() {
        running = false;
        State.running = false;
        if (wake != null && wake.isHeld()) wake.release();
        super.onDestroy();
    }

    // ---------- the microphone ----------

    private AudioRecord openRecord() {
        AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        boolean unprocessed = am != null && "true".equals(am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
        int[] sources = unprocessed
                ? new int[]{MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC}
                : new int[]{MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC};
        String[] names = unprocessed ? new String[]{"unprocessed", "speech recognition", "standard"}
                : new String[]{"speech recognition", "standard"};
        for (int s = 0; s < sources.length; s++) {
            try {
                int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                if (min <= 0) continue;
                AudioRecord ar = new AudioRecord(sources[s], RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min * 4, RATE));
                if (ar.getState() == AudioRecord.STATE_INITIALIZED) {
                    AudioDeviceInfo mic = builtInMic(am);
                    if (mic != null) { try { ar.setPreferredDevice(mic); } catch (Exception ignored) { } }
                    State.source = names[s];
                    return ar;
                }
                ar.release();
            } catch (SecurityException e) {
                return null;
            } catch (Exception ignored) { }
        }
        return null;
    }

    private static AudioDeviceInfo builtInMic(AudioManager am) {
        if (am == null) return null;
        try {
            for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_INPUTS))
                if (d.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC) return d;
        } catch (Exception ignored) { }
        return null;
    }

    // ---------- the loop ----------

    private void run() {
        AudioRecord rec = openRecord();
        if (rec == null) {
            State.problem = "The microphone could not be opened. Is the permission given, or is another app using it?";
            State.log(State.problem);
            running = false; State.running = false;
            stopForeground(true);
            stopSelf();
            return;
        }
        State.rate = RATE;
        Session.Settings st = new Session.Settings();
        st.rate = RATE;
        st.volume = volume(this);
        st.afterMs = 400;                                  // the speaker's delay, then the echo of the room
        final Gateway gw = new Gateway(State::log);
        final Session session = new Session(st, this::play, gw, new Random());
        session.log = State::log;
        State.log("listening: " + State.source + " microphone, " + RATE + " samples/s");
        short[] buf = new short[960];
        float[] f = new float[960];
        long lastStat = 0;
        int peak = 0;
        try {
            rec.startRecording();
            while (running) {
                int n = rec.read(buf, 0, buf.length);
                if (n < 0) { State.problem = "The microphone stopped."; State.log(State.problem); break; }
                if (n == 0) continue;
                if (dropSamples > 0) { dropSamples -= n; continue; }
                for (int i = 0; i < n; i++) { f[i] = buf[i] / 32768f; int v = Math.abs((int) buf[i]); if (v > peak) peak = v; }
                st.volume = volume(this);
                session.onAudio(f, n);
                long now = System.currentTimeMillis();
                if (now - lastStat > 500) {
                    lastStat = now;
                    State.level = peak * 100 / 32768; peak = 0;
                    State.framesHeard = session.framesHeard();
                    State.turns = session.turnsAnswered();
                    State.connections = gw.connections();
                    State.bytesUp = gw.bytesUp; State.bytesDown = gw.bytesDown;
                    if (session.lastHeardMs >= 0) State.lastHeardAt = now;
                }
            }
        } catch (Exception e) {
            State.problem = "Stopped: " + e;
            State.log(State.problem);
        } finally {
            try { rec.stop(); } catch (Exception ignored) { }
            rec.release();
            gw.close();
            State.log("stopped");
            running = false;
            State.running = false;
        }
    }

    /** Called by the session (on the listening thread) with the sound of its turn. */
    private void play(final short[] pcm, final int rate) {
        dropSamples = (long) pcm.length + 400L * rate / 1000;
        new Thread(() -> {
            AudioTrack t = null;
            try {
                t = new AudioTrack.Builder()
                        .setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                        .setAudioFormat(new AudioFormat.Builder()
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                        .setBufferSizeInBytes(pcm.length * 2)
                        .setTransferMode(AudioTrack.MODE_STATIC).build();
                t.write(pcm, 0, pcm.length);
                t.play();
                Thread.sleep(pcm.length * 1000L / rate + 150);
            } catch (Exception e) {
                State.log("sound could not be played: " + e);
            } finally {
                if (t != null) { try { t.stop(); } catch (Exception ignored) { } t.release(); }
            }
        }, "whisper-gateway-play").start();
    }
}
