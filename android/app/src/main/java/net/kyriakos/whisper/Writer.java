package net.kyriakos.whisper;

import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.nio.charset.StandardCharsets;

/**
 * Puts the handheld's text into whatever field is open, as a keyboard does.
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
    private static final int LONGEST_UNDERLINE = 160;      // bytes; older text is written even with a gap
    private static final String GAP = "·";

    public final Mirror mirror = new Mirror();
    private int committed = 0;                              // bytes of the current document written for good
    private String shown = "";                              // the underlined text in the field now
    private boolean singleLine = false;
    public int keysPressed = 0;

    /** A new field: only what is typed from now on goes into it. */
    public void startField(EditorInfo info) {
        committed = mirror.L;
        shown = "";
        int cls = info.inputType & EditorInfo.TYPE_MASK_CLASS;
        singleLine = cls == EditorInfo.TYPE_CLASS_TEXT
                && (info.inputType & EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE) == 0;
    }

    /** The field is closing or the keyboard is hidden: write what is underlined as it is. */
    public void finish(InputConnection ic) {
        if (ic != null && !shown.isEmpty()) ic.finishComposingText();
        committed = mirror.L;
        shown = "";
    }

    public void frame(Receiver.Frame f, InputConnection ic, EditorInfo info, long now) {
        if (f.doc != mirror.doc && mirror.doc != -1) {
            // the handheld started a new page: what is underlined is written as it is
            if (ic != null && !shown.isEmpty()) ic.finishComposingText();
            shown = "";
            committed = 0;
        }
        // the handheld's Backspace went past text already written: take it back
        if (f.doc == mirror.doc && f.L < committed && ic != null) {
            int chars = Keys.strip(new String(mirror.bytes, f.L, committed - f.L, StandardCharsets.UTF_8)).length();
            ic.beginBatchEdit();
            if (!shown.isEmpty()) { ic.setComposingText("", 1); ic.finishComposingText(); shown = ""; }
            ic.deleteSurroundingText(chars, 0);
            ic.endBatchEdit();
            committed = f.L;
        }
        boolean fresh = mirror.apply(f, now);
        if (fresh) committed = 0;
        update(ic, info, now);
    }

    /** Called on every frame and every half second: settle what has settled, press keys, show the rest. */
    public void update(InputConnection ic, EditorInfo info, long now) {
        if (ic == null) return;
        Mirror m = mirror;
        if (committed > m.L) committed = m.L;
        int fu = m.firstUnknown(committed);
        // keys: the text before a key is written at once, then the key is pressed
        int k;
        while ((k = Keys.findKey(m.bytes, committed, fu)) >= 0) {
            String before = m.text(committed, k, "");
            ic.beginBatchEdit();
            commit(ic, info, before);
            if (!shown.isEmpty() && before.isEmpty()) ic.commitText("", 1);
            shown = "";
            ic.endBatchEdit();
            committed = k + 3;
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
        committed = s;
    }

    /** Writes text for good (it replaces what is underlined). Enter in a one-line field does what Enter does there. */
    private void commit(InputConnection ic, EditorInfo info, String write) {
        if (write.isEmpty()) return;
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

    private static void key(InputConnection ic, int code, int meta) {
        long t = SystemClock.uptimeMillis();
        ic.sendKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, meta));
        ic.sendKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_UP, code, 0, meta));
    }

    /** Presses one key in the open field (or, for Send, Back, Home and Recent apps, through the helper). */
    public void press(InputConnection ic, EditorInfo info, int code) {
        switch (code) {
            case Keys.TAB:
                // a one-line field that has a "next" action moves on with it; elsewhere Tab moves the focus
                if (singleLine && action(info) == EditorInfo.IME_ACTION_NEXT) ic.performEditorAction(EditorInfo.IME_ACTION_NEXT);
                else key(ic, KeyEvent.KEYCODE_TAB, 0);
                break;
            case Keys.SHIFT_TAB:
                if (singleLine && action(info) == EditorInfo.IME_ACTION_PREVIOUS) ic.performEditorAction(EditorInfo.IME_ACTION_PREVIOUS);
                else key(ic, KeyEvent.KEYCODE_TAB, KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON);
                break;
            case Keys.BACKSPACE: key(ic, KeyEvent.KEYCODE_DEL, 0); break;
            case Keys.DELETE: key(ic, KeyEvent.KEYCODE_FORWARD_DEL, 0); break;
            case Keys.ESC: key(ic, KeyEvent.KEYCODE_ESCAPE, 0); break;
            case Keys.LEFT: key(ic, KeyEvent.KEYCODE_DPAD_LEFT, 0); break;
            case Keys.RIGHT: key(ic, KeyEvent.KEYCODE_DPAD_RIGHT, 0); break;
            case Keys.UP: key(ic, KeyEvent.KEYCODE_DPAD_UP, 0); break;
            case Keys.DOWN: key(ic, KeyEvent.KEYCODE_DPAD_DOWN, 0); break;
            case Keys.HOME: key(ic, KeyEvent.KEYCODE_MOVE_HOME, 0); break;
            case Keys.END: key(ic, KeyEvent.KEYCODE_MOVE_END, 0); break;
            case Keys.PAGE_UP: key(ic, KeyEvent.KEYCODE_PAGE_UP, 0); break;
            case Keys.PAGE_DOWN: key(ic, KeyEvent.KEYCODE_PAGE_DOWN, 0); break;
            case Keys.SELECT_ALL: ic.performContextMenuAction(android.R.id.selectAll); break;
            case Keys.COPY: ic.performContextMenuAction(android.R.id.copy); break;
            case Keys.PASTE: ic.performContextMenuAction(android.R.id.paste); break;
            case Keys.CUT: ic.performContextMenuAction(android.R.id.cut); break;
            case Keys.UNDO: key(ic, KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON); break;
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
