package net.kyriakos.whisper;

import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.pdf.PdfRenderer;
import android.media.ExifInterface;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;

import net.kyriakos.whisper.w3.Resampler;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.zip.CRC32;
import java.util.zip.Deflater;

/**
 * Shrinks a file to what the handheld can show or play (design report, File
 * transfer): pictures to JPEG at the handheld's screen size, PDF pages to
 * 16-grey pictures, sound to 4-bit ADPCM WAV, video to a few still pictures
 * or its sound, text and other files compressed.
 */
public final class Convert {
    private Convert() { }

    public static final int MAX_SOURCE = 64 << 20;      // a larger file is not read

    public static final class Out {
        public final String name; public final int kind; public final byte[] data;
        Out(String name, int kind, byte[] data) { this.name = name; this.kind = kind; this.data = data; }
    }

    public static final class Choice {
        public final String id, label, detail;
        Choice(String id, String label, String detail) { this.id = id; this.label = label; this.detail = detail; }
    }

    public enum Type { PICTURE, PDF, SOUND, VIDEO, EPUB, TEXT, OTHER }

    public static Type typeOf(String mime, String name) {
        String n = name.toLowerCase(Locale.ROOT);
        String m = mime == null ? "" : mime.toLowerCase(Locale.ROOT);
        if (m.startsWith("image/") || n.matches(".*\\.(jpe?g|png|gif|webp|heic|heif|bmp)$")) return Type.PICTURE;
        if (m.equals("application/pdf") || n.endsWith(".pdf")) return Type.PDF;
        if (m.startsWith("audio/") || n.matches(".*\\.(mp3|m4a|aac|ogg|opus|wav|flac|amr|3gp)$")) return Type.SOUND;
        if (m.startsWith("video/") || n.matches(".*\\.(mp4|mkv|webm|mov)$")) return Type.VIDEO;
        if (m.equals("application/epub+zip") || n.endsWith(".epub")) return Type.EPUB;
        if (m.startsWith("text/") || n.matches(".*\\.(txt|html?|csv|md|xml|json|log)$")) return Type.TEXT;
        return Type.OTHER;
    }

    public static List<Choice> choices(Type t) {
        List<Choice> c = new ArrayList<>();
        switch (t) {
            case PICTURE:
                c.add(new Choice("fit", "Fit the screen", "640 × 240 at most, shape kept"));
                c.add(new Choice("small", "Small", "320 wide: about half the time"));
                c.add(new Choice("wide", "Readable", "640 wide, full height: for screenshots and text"));
                c.add(new Choice("orig", "As it is", "the original file, unchanged"));
                break;
            case PDF:
                c.add(new Choice("pages", "Pages as pictures", "each page 640 wide in 16 greys"));
                c.add(new Choice("orig", "As it is", "the PDF itself (the handheld cannot show it)"));
                break;
            case SOUND:
                c.add(new Choice("voice", "Voice quality", "WAV, 4-bit ADPCM, 8 kHz mono"));
                c.add(new Choice("music", "Music quality", "WAV, 4-bit ADPCM, 22 kHz mono: about 3 times longer"));
                break;
            case VIDEO:
                c.add(new Choice("stills", "Five still pictures", "frames from through the video"));
                c.add(new Choice("voice", "Its sound, voice quality", "WAV, 8 kHz"));
                c.add(new Choice("music", "Its sound, music quality", "WAV, 22 kHz"));
                break;
            case EPUB:
                c.add(new Choice("orig", "As it is", "already compressed"));
                break;
            default:
                c.add(new Choice("zip", "Compressed", "smaller on the way, unchanged on arrival"));
                c.add(new Choice("orig", "As it is", ""));
                break;
        }
        return c;
    }

    public static String nameOf(Context c, Uri u) {
        String n = null;
        try (Cursor q = c.getContentResolver().query(u, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (q != null && q.moveToFirst()) n = q.getString(0);
        } catch (Exception ignored) { }
        if (n == null) { n = u.getLastPathSegment(); if (n == null) n = "file"; int s = n.lastIndexOf('/'); if (s >= 0) n = n.substring(s + 1); }
        return n;
    }

    public static String mimeOf(String name) {
        int d = name.lastIndexOf('.');
        String m = d < 0 ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(d + 1).toLowerCase(Locale.ROOT));
        return m == null ? "application/octet-stream" : m;
    }

    static String base(String name) {
        int d = name.lastIndexOf('.');
        String b = d > 0 ? name.substring(0, d) : name;
        // handheld names: short, plain
        b = b.replaceAll("[^A-Za-z0-9 _()-]", "_").trim();
        if (b.length() > 40) b = b.substring(0, 40);
        return b.isEmpty() ? "file" : b;
    }

    static byte[] read(Context c, Uri u) throws Exception {
        try (InputStream in = c.getContentResolver().openInputStream(u)) {
            if (in == null) throw new Exception("the file could not be opened");
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            byte[] b = new byte[65536]; int n;
            while ((n = in.read(b)) > 0) { o.write(b, 0, n); if (o.size() > MAX_SOURCE) throw new Exception("the file is too large (over 64 MB)"); }
            return o.toByteArray();
        }
    }

    /** Converts, off the main thread. */
    public static List<Out> run(Context c, Uri u, String name, Type t, String choice) throws Exception {
        List<Out> out = new ArrayList<>();
        String b = base(name);
        switch (choice) {
            case "fit": out.add(new Out(b + ".jpg", Transfers.KIND_PICTURE, jpeg(picture(c, u), 640, 240, 82))); break;
            case "small": out.add(new Out(b + ".jpg", Transfers.KIND_PICTURE, jpeg(picture(c, u), 320, 240, 80))); break;
            case "wide": out.add(new Out(b + ".jpg", Transfers.KIND_PICTURE, jpeg(picture(c, u), 640, 4000, 80))); break;
            case "pages": out.addAll(pdfPages(c, u, b)); break;
            case "voice": out.add(new Out(b + ".wav", Transfers.KIND_SOUND, sound(c, u, 8000))); break;
            case "music": out.add(new Out(b + ".wav", Transfers.KIND_SOUND, sound(c, u, 22050))); break;
            case "stills": out.addAll(stills(c, u, b)); break;
            case "zip": {
                byte[] d = read(c, u);
                byte[] z = deflate(d);
                if (z.length < d.length * 0.9) out.add(new Out(plain(name), kindFor(t) | Transfers.ZLIB, z));
                else out.add(new Out(plain(name), kindFor(t), d));
                break;
            }
            default: out.add(new Out(plain(name), kindFor(t), read(c, u))); break;
        }
        return out;
    }

    static int kindFor(Type t) {
        switch (t) {
            case PICTURE: return Transfers.KIND_PICTURE;
            case SOUND: return Transfers.KIND_SOUND;
            case TEXT: return Transfers.KIND_TEXT;
            case PDF: case EPUB: return Transfers.KIND_DOCUMENT;
            default: return Transfers.KIND_OTHER;
        }
    }

    /** A name the handheld's file system takes: plain letters, the extension kept. */
    static String plain(String name) {
        int d = name.lastIndexOf('.');
        String ext = d > 0 ? name.substring(d).toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9.]", "") : "";
        if (ext.length() > 6) ext = ext.substring(0, 6);
        return base(name) + ext;
    }

    // ---------- pictures ----------

    static Bitmap picture(Context c, Uri u) throws Exception {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        try (InputStream in = c.getContentResolver().openInputStream(u)) { BitmapFactory.decodeStream(in, null, o); }
        if (o.outWidth <= 0) throw new Exception("this picture cannot be read");
        int s = 1;
        while (o.outWidth / (s * 2) >= 1280 && o.outHeight / (s * 2) >= 480) s *= 2;
        BitmapFactory.Options o2 = new BitmapFactory.Options();
        o2.inSampleSize = s;
        Bitmap bm;
        try (InputStream in = c.getContentResolver().openInputStream(u)) { bm = BitmapFactory.decodeStream(in, null, o2); }
        if (bm == null) throw new Exception("this picture cannot be read");
        int rot = 0;
        try (InputStream in = c.getContentResolver().openInputStream(u)) {
            if (in != null) {
                int or = new ExifInterface(in).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
                rot = or == ExifInterface.ORIENTATION_ROTATE_90 ? 90 : or == ExifInterface.ORIENTATION_ROTATE_180 ? 180 : or == ExifInterface.ORIENTATION_ROTATE_270 ? 270 : 0;
            }
        } catch (Exception ignored) { }
        if (rot != 0) {
            Matrix m = new Matrix(); m.postRotate(rot);
            bm = Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
        }
        return bm;
    }

    static Bitmap fit(Bitmap bm, int maxW, int maxH) {
        float s = Math.min(1f, Math.min(maxW / (float) bm.getWidth(), maxH / (float) bm.getHeight()));
        int w = Math.max(1, Math.round(bm.getWidth() * s)), h = Math.max(1, Math.round(bm.getHeight() * s));
        Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas cv = new Canvas(out);
        cv.drawColor(Color.WHITE);                       // transparent parts on white
        android.graphics.Paint p = new android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG);
        cv.drawBitmap(bm, new android.graphics.Rect(0, 0, bm.getWidth(), bm.getHeight()), new android.graphics.Rect(0, 0, w, h), p);
        return out;
    }

    static byte[] jpeg(Bitmap bm, int maxW, int maxH, int quality) {
        Bitmap f = fit(bm, maxW, maxH);
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        f.compress(Bitmap.CompressFormat.JPEG, quality, o);   // baseline JPEG: the handheld decodes it in full
        return o.toByteArray();
    }

    // ---------- PDF ----------

    static List<Out> pdfPages(Context c, Uri u, String b) throws Exception {
        File tmp = new File(c.getCacheDir(), "send.pdf");
        try (FileOutputStream o = new FileOutputStream(tmp)) { o.write(read(c, u)); }
        List<Out> out = new ArrayList<>();
        try (ParcelFileDescriptor fd = ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY);
             PdfRenderer r = new PdfRenderer(fd)) {
            int n = Math.min(r.getPageCount(), 99);
            for (int i = 0; i < n; i++) {
                try (PdfRenderer.Page p = r.openPage(i)) {
                    int w = 640, h = Math.max(1, Math.round(640f * p.getHeight() / p.getWidth()));
                    Bitmap bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    bm.eraseColor(Color.WHITE);
                    p.render(bm, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                    out.add(new Out(String.format(Locale.ROOT, "%s p%02d.png", b.length() > 30 ? b.substring(0, 30) : b, i + 1), Transfers.KIND_PICTURE, png16(bm)));
                }
            }
        } finally { tmp.delete(); }
        return out;
    }

    /** A PNG in 16 greys (4 bits a pixel): pages of text come out small. */
    static byte[] png16(Bitmap bm) throws Exception {
        int w = bm.getWidth(), h = bm.getHeight();
        int[] px = new int[w];
        int rowBytes = (w + 1) / 2;
        byte[] raw = new byte[(rowBytes + 1) * h];
        int o = 0;
        for (int y = 0; y < h; y++) {
            bm.getPixels(px, 0, w, 0, y, w, 1);
            raw[o++] = 0;
            for (int x = 0; x < w; x += 2) {
                int a = grey4(px[x]), b2 = x + 1 < w ? grey4(px[x + 1]) : 15;
                raw[o++] = (byte) (a << 4 | b2);
            }
        }
        ByteArrayOutputStream f = new ByteArrayOutputStream();
        f.write(new byte[]{(byte) 0x89, 'P', 'N', 'G', 13, 10, 26, 10});
        ByteBuffer ih = ByteBuffer.allocate(13);
        ih.putInt(w).putInt(h).put((byte) 4).put((byte) 0).put((byte) 0).put((byte) 0).put((byte) 0);
        chunk(f, "IHDR", ih.array());
        chunk(f, "IDAT", deflate(raw));
        chunk(f, "IEND", new byte[0]);
        return f.toByteArray();
    }

    private static int grey4(int c) {
        int g = (Color.red(c) * 77 + Color.green(c) * 150 + Color.blue(c) * 29) >> 8;
        return (g * 15 + 127) / 255;
    }

    private static void chunk(ByteArrayOutputStream f, String type, byte[] d) {
        ByteBuffer b = ByteBuffer.allocate(12 + d.length);
        b.putInt(d.length).put(type.getBytes()).put(d);
        CRC32 crc = new CRC32();
        crc.update(type.getBytes()); crc.update(d);
        b.putInt((int) crc.getValue());
        f.write(b.array(), 0, b.capacity());
    }

    static byte[] deflate(byte[] d) {
        Deflater z = new Deflater(9);
        z.setInput(d); z.finish();
        ByteArrayOutputStream o = new ByteArrayOutputStream(d.length / 2 + 64);
        byte[] b = new byte[65536];
        while (!z.finished()) { int n = z.deflate(b); o.write(b, 0, n); }
        z.end();
        return o.toByteArray();
    }

    // ---------- video ----------

    static List<Out> stills(Context c, Uri u, String b) throws Exception {
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        List<Out> out = new ArrayList<>();
        try {
            r.setDataSource(c, u);
            String d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            long ms = d == null ? 0 : Long.parseLong(d);
            for (int i = 1; i <= 5; i++) {
                Bitmap f = r.getFrameAtTime(ms * 1000L * i / 6, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                if (f != null) out.add(new Out(String.format(Locale.ROOT, "%s %d.jpg", b.length() > 30 ? b.substring(0, 30) : b, i), Transfers.KIND_PICTURE, jpeg(f, 640, 240, 80)));
            }
        } finally { try { r.release(); } catch (Exception ignored) { } }
        if (out.isEmpty()) throw new Exception("no pictures could be taken from this video");
        return out;
    }

    // ---------- sound ----------

    static final int MAX_SOUND_S = 600;

    /** Decodes any sound the phone can play (or a video's sound) to mono, then to ADPCM WAV at this rate. */
    static byte[] sound(Context c, Uri u, int rate) throws Exception {
        MediaExtractor ex = new MediaExtractor();
        ex.setDataSource(c, u, null);
        int track = -1;
        MediaFormat fmt = null;
        for (int i = 0; i < ex.getTrackCount(); i++) {
            MediaFormat f = ex.getTrackFormat(i);
            String m = f.getString(MediaFormat.KEY_MIME);
            if (m != null && m.startsWith("audio/")) { track = i; fmt = f; break; }
        }
        if (track < 0) { ex.release(); throw new Exception("there is no sound in this file"); }
        ex.selectTrack(track);
        MediaCodec dec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME));
        dec.configure(fmt, null, null, 0);
        dec.start();
        int srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE), chans = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
        float[] mono = new float[1 << 16];
        int n = 0;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        boolean inDone = false, outDone = false;
        long limit = (long) srcRate * MAX_SOUND_S;
        while (!outDone) {
            if (!inDone) {
                int i = dec.dequeueInputBuffer(10000);
                if (i >= 0) {
                    ByteBuffer b = dec.getInputBuffer(i);
                    int sz = b == null ? -1 : ex.readSampleData(b, 0);
                    if (sz < 0) { dec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inDone = true; }
                    else { dec.queueInputBuffer(i, 0, sz, ex.getSampleTime(), 0); ex.advance(); }
                }
            }
            int o = dec.dequeueOutputBuffer(info, 10000);
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat f = dec.getOutputFormat();
                srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE); chans = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
            } else if (o >= 0) {
                ByteBuffer b = dec.getOutputBuffer(o);
                if (b != null && info.size > 0) {
                    b.position(info.offset); b.limit(info.offset + info.size);
                    java.nio.ShortBuffer s = b.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
                    int frames = s.remaining() / Math.max(1, chans);
                    if (n + frames > mono.length) mono = java.util.Arrays.copyOf(mono, Math.max(mono.length * 2, n + frames));
                    for (int k = 0; k < frames; k++) {
                        int sum = 0;
                        for (int ch = 0; ch < chans; ch++) sum += s.get(k * chans + ch);
                        mono[n++] = sum / (32768f * chans);
                    }
                }
                dec.releaseOutputBuffer(o, false);
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0 || n > limit) outDone = true;
            }
        }
        dec.stop(); dec.release(); ex.release();
        if (n == 0) throw new Exception("the sound could not be decoded");
        float[] x = Resampler.convert(java.util.Arrays.copyOf(mono, n), srcRate, rate);
        // the level: loud, without clipping
        float peak = 1e-6f;
        for (float v : x) peak = Math.max(peak, Math.abs(v));
        float g = Math.min(8f, 0.95f / peak);
        short[] pcm = new short[x.length];
        for (int i = 0; i < x.length; i++) pcm[i] = (short) Math.max(-32767, Math.min(32767, Math.round(x[i] * g * 32767)));
        return Adpcm.wav(pcm, rate);
    }
}
