import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import net.kyriakos.whisper.Keys;
import net.kyriakos.whisper.Mirror;
import net.kyriakos.whisper.Receiver;
import net.kyriakos.whisper.Writer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * The keyboard's writing (Writer) against a pretend text field, fed the way the
 * link feeds it: each TEXT payload goes into the shared copy (TextLink), then the
 * keyboard is told. Run with the Android stand-ins in stubs/ on the class path.
 *   java -cp cls WriterTest writer-frames.txt
 */
public class WriterTest {
    /** A text field: its text, the underlined part, the cursor, and the keys pressed in it. */
    static final class Field implements InputConnection {
        final StringBuilder text = new StringBuilder();
        int cs = -1, ce = -1, cur = 0;
        final List<Integer> keys = new ArrayList<>(), metas = new ArrayList<>();
        private void put(CharSequence t) { if (cs < 0) cs = ce = cur; text.replace(cs, ce, t.toString()); ce = cs + t.length(); cur = ce; }
        public boolean beginBatchEdit() { return true; }
        public boolean endBatchEdit() { return true; }
        public boolean commitText(CharSequence t, int p) { put(t); cs = ce = -1; return true; }
        public boolean setComposingText(CharSequence t, int p) { put(t); if (t.length() == 0) cs = ce = -1; return true; }
        public boolean finishComposingText() { cs = ce = -1; return true; }
        public boolean deleteSurroundingText(int a, int b) { int s = Math.max(0, cur - a); text.delete(s, cur); cur = s; return true; }
        public boolean performContextMenuAction(int id) { return true; }
        public boolean performEditorAction(int a) { return true; }
        public boolean sendKeyEvent(android.view.KeyEvent e) { if (e.action == 0) { keys.add(e.code); metas.add(e.meta); } return true; }
        boolean composing() { return cs >= 0 && ce > cs; }
    }

    static int fails = 0;
    static void check(String name, boolean ok, String detail) {
        System.out.println((ok ? "ok    " : "FAIL  ") + name + (ok ? "" : ": " + detail));
        if (!ok) fails++;
    }

    /** A piece of text from the handheld goes into the shared copy (as the app's Hub does). */
    static void onText(Mirror mirror, byte[] p, long nowMs) {
        Receiver.Frame f = new Receiver.Frame();
        f.doc = p[0] & 255; f.seq = p[1] & 255;
        f.L = ((p[2] & 255) << 8) | (p[3] & 255);
        f.o = ((p[4] & 255) << 8) | (p[5] & 255);
        f.bytes = new byte[p.length - 6];
        System.arraycopy(p, 6, f.bytes, 0, f.bytes.length);
        mirror.apply(f, nowMs);
    }

    static byte[] text(int doc, int seq, int L, int o, String s) {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        byte[] p = new byte[6 + b.length];
        p[0] = (byte) doc; p[1] = (byte) seq; p[2] = (byte) (L >> 8); p[3] = (byte) L; p[4] = (byte) (o >> 8); p[5] = (byte) o;
        System.arraycopy(b, 0, p, 6, b.length);
        return p;
    }

    /** One run: frames at times (ms); the field opens at openAt; the keyboard ticks every 300 ms as on the phone. */
    static Field run(List<long[]> times, List<byte[]> frames, long openAt, EditorInfo info) {
        Mirror mirror = new Mirror();
        Writer w = new Writer(mirror);
        Field f = new Field();
        boolean open = false;
        long end = times.get(times.size() - 1)[0] + 5000;
        int k = 0;
        for (long t = 0; t <= end; t += 50) {
            if (!open && t >= openAt) { w.startField(info); open = true; }
            while (k < frames.size() && times.get(k)[0] <= t) {
                onText(mirror, frames.get(k), t);
                if (open) w.frame(f, info, t);
                k++;
            }
            if (open && t % 300 == 0) w.update(f, info, t);
        }
        return f;
    }

    static EditorInfo multiLine() { EditorInfo i = new EditorInfo(); i.inputType = EditorInfo.TYPE_CLASS_TEXT | EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE; return i; }

    public static void main(String[] a) throws Exception {
        EditorInfo info = multiLine();

        // 1. the field opens after part of the page has arrived: only the later text goes in, and is written for good
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(5, 1, 6, 0, "Hello "));
            t.add(new long[]{1000}); fr.add(text(5, 2, 11, 6, "world"));
            t.add(new long[]{2000}); fr.add(text(5, 3, 17, 11, ", you."));
            Field f = run(t, fr, 500, info);
            check("opened mid-page: only the new text", f.text.toString().equals("world, you.") && !f.composing(), "[" + f.text + "] composing " + f.composing());
        }
        // 2. a lost piece fills in when the handheld repeats it
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(6, 1, 4, 0, "abcd"));
            t.add(new long[]{900}); fr.add(text(6, 3, 12, 8, "ijkl"));   // "efgh" lost
            t.add(new long[]{1800}); fr.add(text(6, 4, 12, 4, "efgh"));  // repeated
            Field f = run(t, fr, 0, info);
            check("lost piece filled by the repeat", f.text.toString().equals("abcdefghijkl") && !f.composing(), "[" + f.text + "]");
        }
        // 3. Backspace on the handheld takes back text already written
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(7, 1, 9, 0, "good dogs"));
            t.add(new long[]{4000}); fr.add(text(7, 2, 8, 8, ""));       // one Backspace, after it was written
            t.add(new long[]{4500}); fr.add(text(7, 3, 6, 6, ""));       // two more
            Field f = run(t, fr, 0, info);
            check("Backspace takes back written text", f.text.toString().equals("good d"), "[" + f.text + "]");
        }
        // 4. keys inside the text: the text before is written, then the key is pressed
        {
            String tab = new String(Character.toChars(Keys.BASE + Keys.TAB));
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            String s = "name" + tab + "pass";
            int L = s.getBytes(StandardCharsets.UTF_8).length;
            t.add(new long[]{0}); fr.add(text(8, 1, L, 0, s));
            Field f = run(t, fr, 0, info);
            check("Tab pressed between the words", f.keys.size() == 1 && f.keys.get(0) == 61 && f.text.toString().equals("namepass"), "keys " + f.keys + " [" + f.text + "]");
        }
        // 5. a new page on the handheld: the old one stays, the new one goes in whole
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(9, 1, 3, 0, "one"));
            t.add(new long[]{3000}); fr.add(text(10, 1, 4, 0, " two"));
            Field f = run(t, fr, 0, info);
            check("new page", f.text.toString().equals("one two") && !f.composing(), "[" + f.text + "]");
        }
        // 6a. Shift and Ctrl travel with the movement keys; Redo is Ctrl+Shift+Z
        {
            String sr = new String(Character.toChars(Keys.BASE + (Keys.RIGHT | Keys.SHIFT)));
            String cb = new String(Character.toChars(Keys.BASE + (Keys.BACKSPACE | Keys.CTRL)));
            String redo = new String(Character.toChars(Keys.BASE + Keys.REDO));
            String s = "ab" + sr + "cd" + cb + redo;
            int L = s.getBytes(StandardCharsets.UTF_8).length;
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(11, 1, L, 0, s));
            Field f = run(t, fr, 0, info);
            int shift = android.view.KeyEvent.META_SHIFT_ON, ctrl = android.view.KeyEvent.META_CTRL_ON;
            boolean ok = f.keys.size() == 3 && f.keys.get(0) == 22 && (f.metas.get(0) & shift) != 0 && (f.metas.get(0) & ctrl) == 0
                    && f.keys.get(1) == 67 && (f.metas.get(1) & ctrl) != 0
                    && f.keys.get(2) == 54 && (f.metas.get(2) & ctrl) != 0 && (f.metas.get(2) & shift) != 0
                    && f.text.toString().equals("abcd");
            check("Shift+Right, Ctrl+Backspace, Redo", ok, "keys " + f.keys + " metas " + f.metas + " [" + f.text + "]");
        }
        // 6b. a key is pressed once only, however often the handheld repeats it
        {
            String tab = new String(Character.toChars(Keys.BASE + Keys.TAB));
            String s = "a" + tab + "b";
            int L = s.getBytes(StandardCharsets.UTF_8).length;
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            for (int i = 0; i < 6; i++) { t.add(new long[]{i * 700L}); fr.add(text(12, 1 + i, L, 0, s)); }
            Field f = run(t, fr, 0, info);
            check("repeats do not press a key twice", f.keys.size() == 1 && f.text.toString().equals("ab"), "keys " + f.keys + " [" + f.text + "]");
        }
        // 6c. a piece that never arrives is given up, so it cannot hold back the text after it
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(13, 1, 4, 0, "abcd"));
            t.add(new long[]{1000}); fr.add(text(13, 3, 12, 8, "ijkl"));      // "efgh" is lost and never repeated
            Field f = run(t, fr, 0, info);
            check("a gap shows as a mark while it may still fill", f.text.toString().equals("abcd\u00b7ijkl") && f.composing(), "[" + f.text + "]");
            t.add(new long[]{40000}); fr.add(text(13, 4, 14, 12, "mn"));       // later typing; the gap is old by now
            Field g = run(t, fr, 0, info);
            check("the gap is given up, the rest follows", g.text.toString().equals("abcdijklmn") && !g.composing(), "[" + g.text + "]");
        }
        // 6d. a gap that fills in time leaves nothing out
        {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            t.add(new long[]{0}); fr.add(text(14, 1, 4, 0, "abcd"));
            t.add(new long[]{1000}); fr.add(text(14, 3, 12, 8, "ijkl"));
            t.add(new long[]{20000}); fr.add(text(14, 4, 12, 4, "efgh"));     // 19 s later: still in time
            Field f = run(t, fr, 0, info);
            check("a late repeat still fills the gap", f.text.toString().equals("abcdefghijkl"), "[" + f.text + "]");
        }
        // 6. the frames from the device test (16 October 2026), the field opened before any of them
        if (a.length > 0) {
            List<long[]> t = new ArrayList<>(); List<byte[]> fr = new ArrayList<>();
            for (String ln : Files.readAllLines(Paths.get(a[0]))) {
                String[] p = ln.trim().split(" ");
                byte[] b = new byte[p[1].length() / 2];
                for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(p[1].substring(2 * i, 2 * i + 2), 16);
                t.add(new long[]{Math.round(Double.parseDouble(p[0]) * 1000) + 1000}); fr.add(b);
            }
            // the page held 50 bytes before the recording began; the field opened at 0.5 s, with the first of them known
            Mirror tl0 = new Mirror();
            Field f = run(t, fr, 500, info);
            for (byte[] b : fr) { onText(tl0, b, 0); }
            String expect = new String(tl0.bytes, 50, tl0.L - 50, StandardCharsets.UTF_8);
            // typed after the field opened: from byte 50, minus what Backspace took back; nothing left underlined
            check("device-test frames: written for good, no gap mark", !f.composing() && f.text.indexOf("·") < 0
                    && f.text.toString().equals(expect), "[" + f.text.toString().replace("\n", "⏎") + "] expected [" + expect.replace("\n", "⏎") + "]");
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
