package net.kyriakos.whisper;

import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.nio.charset.StandardCharsets;

/**
 * Puts the handheld's text into whatever field is open, as a keyboard does.
 *
 * It reads the link's one copy of the handheld's page (the same copy the link
 * confirms from), so nothing the handheld sent before the field opened can
 * leave a hole in it. A field gets only what is typed after it opened.
 *
 * New text appears at once, underlined while it may still change (a gap from
 * a lost frame shows as "·" and fills in when the handheld repeats it). Text
 * that has been complete for a moment is written for good, and from then on
 * it is never touched again, except by the handheld's own Backspace.
 *
 * Keys (Tab, arrows, Ctrl+C, Send...) arrive inside the text (see Keys). The
 * text before a key is written for good at once, then the key is pressed.
 */
public final class Writer {
    private static final long SETTLE_MS = 2000;
    /** A gap in the text that has not filled for this long (while later text is waiting behind it) is given up. */
    public static final long GAP_GIVEUP_MS = 30000;
    private static final int LONGEST_UNDERLINE = 160;      // bytes; older text is written even with a gap
    private static final String GAP = "·";

    public final Mirror mirror;
    private int doc = -1;                                   // the page this field writes from
    private int committed = 0;                              // bytes of that page written for good
    private int base = 0;                                   // where this field's own text starts in that page
    private byte[] done = new byte[0];                      // a copy of them, to know how much a Backspace takes back
    private String shown = "";                              // the underlined text in the field now
    private boolean singleLine = false;
    public int keysPressed = 0, gapsGivenUp = 0, fixes = 0;

    public Writer(Mirror shared) { mirror = shared; }

    /** Bytes of the page that the handheld announced and that have not arrived (and not been given up). */
    public int missing() {
        Mirror m = mirror;
        if (m.doc != doc) return 0;
        int n = 0;
        for (int i = committed; i < m.L; i++) if (!m.known[i] && !m.skipped[i]) n++;
        return n;
    }

    /** A new field: only what is typed from now on goes into it. */
    public void startField(EditorInfo info) {
        doc = mirror.doc;
        committed = mirror.L;
        base = committed;
        shown = "";
        int cls = info.inputType & EditorInfo.TYPE_MASK_CLASS;
        singleLine = cls == EditorInfo.TYPE_CLASS_TEXT
                && (info.inputType & EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE) == 0;
        DiagLog.log("keyboard: a new field (" + (singleLine ? "one line" : "several lines") + "), from page byte " + committed);
    }

    /** The field is closing or the keyboard is hidden: write what is underlined as it is. */
    public void finish(InputConnection ic) {
        if (ic != null && !shown.isEmpty()) ic.finishComposingText();
        doc = mirror.doc;
        committed = mirror.L;
        base = committed;
        shown = "";
    }

    private void keep(int upTo) {
        if (done.length < upTo) done = java.util.Arrays.copyOf(done, Math.max(upTo, done.length * 2 + 64));
        System.arraycopy(mirror.bytes, committed, done, committed, upTo - committed);
        committed = upTo;
    }

    /** A piece of text arrived (the link has already put it into the shared copy). */
    public void frame(InputConnection ic, EditorInfo info, long now) {
        Mirror m = mirror;
        if (m.doc != doc) {
            // the handheld started a new page: what is underlined is written as it is, and the new page goes in whole.
            // But a field that opened before this phone knew any page joins the handheld's page where it is now:
            // from the first piece heard (the earlier text was typed before the field opened).
            if (ic != null && !shown.isEmpty()) ic.finishComposingText();
            shown = "";
            int from = 0;
            if (doc == -1) while (from < m.L && !m.known[from]) from++;
            doc = m.doc;
            committed = from;
            base = from;
            DiagLog.log("keyboard: a new page from the handheld, writing from byte " + from);
        }
        // the handheld's Backspace went past text already written: take it back
        if (m.L < committed && ic != null) {
            int chars = Keys.strip(new String(done, m.L, committed - m.L, StandardCharsets.UTF_8)).replace("\0", "").replace("\uFFFD", "").length();
            ic.beginBatchEdit();
            if (!shown.isEmpty()) { ic.setComposingText("", 1); ic.finishComposingText(); shown = ""; }
            ic.deleteSurroundingText(chars, 0);
            DiagLog.log("keyboard: took back " + chars + " characters (Backspace on the handheld)");
            ic.endBatchEdit();
            committed = m.L;
        }
        update(ic, info, now);
    }

    private long lastFixLog = 0;

    /**
     * The double check: what was written into the field for good must still be what the page says. A late repeat can
     * change a byte that was already written (the handheld edited that text and the new version only arrived now);
     * then the field holds old text. That part is taken back and written again from the page. Keys already pressed
     * cannot be taken back, so a difference before one is left alone.
     */
    private void checkWritten(InputConnection ic, long now) {
        Mirror m = mirror;
        int d = -1;
        for (int i = base; i < committed && i < done.length; i++) if (m.known[i] && m.bytes[i] != done[i]) { d = i; break; }
        if (d < 0) return;
        while (d > base && (done[d] & 0xC0) == 0x80) d--;
        if (Keys.findKey(done, d, committed) >= 0) {
            if (now - lastFixLog > 30000) { lastFixLog = now; DiagLog.log("keyboard: the text written differs from the page at byte " + d + ", but a key was pressed after it: left as it is"); }
            return;
        }
        int chars = Keys.strip(new String(done, d, committed - d, StandardCharsets.UTF_8)).replace("\0", "").replace("\uFFFD", "").length();
        ic.beginBatchEdit();
        if (!shown.isEmpty()) { ic.setComposingText("", 1); ic.finishComposingText(); shown = ""; }
        ic.deleteSurroundingText(chars, 0);
        ic.endBatchEdit();
        DiagLog.log("keyboard: the text written differed from the page at byte " + d + ": took back " + chars + " characters and wrote them again");
        committed = d;
        fixes++;
    }

    /** Called on every frame and every half second: settle what has settled, press keys, show the rest. */
    public void update(InputConnection ic, EditorInfo info, long now) {
        if (ic == null) return;
        Mirror m = mirror;
        if (m.doc != doc) return;                           // frame() handles a new page
        if (committed > m.L) committed = m.L;
        checkWritten(ic, now);
        int fu = m.firstUnknown(committed);
        while (fu < m.L) {
            // the handheld repeats its text for a while; a piece that is still missing long after the text behind it
            // arrived is given up, so that one lost piece cannot hold back everything typed after it
            int k2 = fu;
            while (k2 < m.L && !m.known[k2]) k2++;
            if (k2 < m.L && now - m.since[k2] > GAP_GIVEUP_MS) {
                DiagLog.log("keyboard: page bytes " + fu + " to " + (k2 - 1) + " never arrived: given up");
                m.skipGap(fu);
                gapsGivenUp++;
                fu = m.firstUnknown(committed);
            } else break;
        }
        if (fu < m.L) DiagLog.log("keyboard: page byte " + fu + " not heard yet (page " + m.L + " bytes): what follows waits");
        // keys: the text before a key is written at once, then the key is pressed
        int k;
        while ((k = Keys.findKey(m.bytes, committed, fu)) >= 0) {
            String before = m.text(committed, k, "");
            ic.beginBatchEdit();
            commit(ic, info, before);
            if (!shown.isEmpty() && before.isEmpty()) ic.commitText("", 1);
            shown = "";
            ic.endBatchEdit();
            keep(k + 3);
            press(ic, info, Keys.codeAt(m.bytes, k));
            keysPressed++;
        }
        int s = committed;
        while (s < fu && now - m.since[s] > SETTLE_MS) s++;
        if (m.L - committed > LONGEST_UNDERLINE) s = Math.max(s, Math.min(fu, m.L - LONGEST_UNDERLINE / 2));
        while (s > committed && s < m.L && (m.bytes[s] & 0xC0) == 0x80) s--;   // whole characters only
        String write = m.text(committed, s, "");
        String under = Keys.strip(m.text(s, m.L, GAP));
        if (singleLine) under = under.replace('\n', ' ');
        if (write.isEmpty() && under.equals(shown)) return;
        ic.beginBatchEdit();
        commit(ic, info, write);
        if (under.isEmpty()) { if (!shown.isEmpty() || !write.isEmpty()) ic.setComposingText("", 1); ic.finishComposingText(); }
        else ic.setComposingText(under, 1);
        ic.endBatchEdit();
        shown = under;
        keep(s);
    }

    /** Writes text for good (it replaces what is underlined). Enter in a one-line field does what Enter does there. */
    private void commit(InputConnection ic, EditorInfo info, String write) {
        if (write.isEmpty()) return;
        StringBuilder e = new StringBuilder();
        for (char c : write.toCharArray()) { if (c >= 32 && c < 127 && c != '"') e.append(c); else e.append('<').append((int) c).append('>'); }
        DiagLog.log("keyboard: wrote \"" + e + "\"");
        if (singleLine && write.indexOf('\n') >= 0) {
            String[] parts = write.split("\n", -1);
            ic.commitText(parts[0], 1);
            for (int i = 1; i < parts.length; i++) {
                int action = action(info);
                if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) ic.performEditorAction(action);
                ic.commitText(parts[i], 1);
            }
        } else ic.commitText(write, 1);
    }

    private static int action(EditorInfo info) {
        return info == null ? EditorInfo.IME_ACTION_DONE : info.imeOptions & EditorInfo.IME_MASK_ACTION;
    }

    public static void key(InputConnection ic, int code, int meta) {
        long t = SystemClock.uptimeMillis();
        ic.sendKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, meta));
        ic.sendKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_UP, code, 0, meta));
    }

    /**
     * Presses one key in the open field (or, for Send, Back, Home and Recent apps, through the helper).
     * code is a key of Keys, with Keys.SHIFT and Keys.CTRL added when the handheld's key was held with them.
     */
    public void press(InputConnection ic, EditorInfo info, int code) {
        int meta = 0;
        if ((code & Keys.SHIFT) != 0) meta |= KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON;
        if ((code & Keys.CTRL) != 0) meta |= KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON;
        switch (code & 0xFF) {
            case Keys.TAB:
                // a one-line field that has a "next" action moves on with it; elsewhere Tab moves the focus
                if (singleLine && action(info) == EditorInfo.IME_ACTION_NEXT) ic.performEditorAction(EditorInfo.IME_ACTION_NEXT);
                else key(ic, KeyEvent.KEYCODE_TAB, meta);
                break;
            case Keys.SHIFT_TAB:
                if (singleLine && action(info) == EditorInfo.IME_ACTION_PREVIOUS) ic.performEditorAction(EditorInfo.IME_ACTION_PREVIOUS);
                else key(ic, KeyEvent.KEYCODE_TAB, KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON);
                break;
            case Keys.BACKSPACE: key(ic, KeyEvent.KEYCODE_DEL, meta); break;
            case Keys.DELETE: key(ic, KeyEvent.KEYCODE_FORWARD_DEL, meta); break;
            case Keys.ESC: key(ic, KeyEvent.KEYCODE_ESCAPE, 0); break;
            case Keys.LEFT: key(ic, KeyEvent.KEYCODE_DPAD_LEFT, meta); break;
            case Keys.RIGHT: key(ic, KeyEvent.KEYCODE_DPAD_RIGHT, meta); break;
            case Keys.UP: key(ic, KeyEvent.KEYCODE_DPAD_UP, meta); break;
            case Keys.DOWN: key(ic, KeyEvent.KEYCODE_DPAD_DOWN, meta); break;
            case Keys.HOME: key(ic, KeyEvent.KEYCODE_MOVE_HOME, meta); break;
            case Keys.END: key(ic, KeyEvent.KEYCODE_MOVE_END, meta); break;
            case Keys.PAGE_UP: key(ic, KeyEvent.KEYCODE_PAGE_UP, meta); break;
            case Keys.PAGE_DOWN: key(ic, KeyEvent.KEYCODE_PAGE_DOWN, meta); break;
            case Keys.SELECT_ALL: ic.performContextMenuAction(android.R.id.selectAll); break;
            case Keys.COPY: ic.performContextMenuAction(android.R.id.copy); break;
            case Keys.PASTE: ic.performContextMenuAction(android.R.id.paste); break;
            case Keys.CUT: ic.performContextMenuAction(android.R.id.cut); break;
            case Keys.UNDO: key(ic, KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON); break;
            case Keys.REDO: key(ic, KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON | KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON); break;
            case Keys.SEND: {
                int a = action(info);
                if (a == EditorInfo.IME_ACTION_SEND || a == EditorInfo.IME_ACTION_GO || a == EditorInfo.IME_ACTION_SEARCH) ic.performEditorAction(a);
                else Helper.pressSend();
                break;
            }
            case Keys.BACK: Helper.global(Helper.BACK); break;
            case Keys.HOME_SCREEN: Helper.global(Helper.HOME); break;
            case Keys.RECENTS: Helper.global(Helper.RECENTS); break;
            default: break;
        }
    }
}
