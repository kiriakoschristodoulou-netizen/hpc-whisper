package net.kyriakos.whisper;

import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.nio.charset.StandardCharsets;

/**
 * Puts the handheld's text into whatever field is open, as a keyboard does.
 *
 * New text appears at once, underlined while it may still change (a gap from
 * a lost frame shows as "·" and fills in when the handheld repeats it). Text
 * that has been complete for a few seconds is written for good, and from then
 * on it is never touched again, except by the handheld's own Backspace.
 */
public final class Writer {
    private static final long SETTLE_MS = 3000;
    private static final int LONGEST_UNDERLINE = 160;      // bytes; older text is written even with a gap
    private static final String GAP = "·";

    public final Mirror mirror = new Mirror();
    private int committed = 0;                              // bytes of the current document written for good
    private String shown = "";                              // the underlined text in the field now
    private boolean singleLine = false;

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
            int chars = new String(mirror.bytes, f.L, committed - f.L, StandardCharsets.UTF_8).length();
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

    /** Called on every frame and every half second: settle what has settled, show the rest. */
    public void update(InputConnection ic, EditorInfo info, long now) {
        if (ic == null) return;
        Mirror m = mirror;
        if (committed > m.L) committed = m.L;
        int fu = m.firstUnknown(committed);
        int s = committed;
        while (s < fu && now - m.since[s] > SETTLE_MS) s++;
        if (m.L - committed > LONGEST_UNDERLINE) s = Math.max(s, Math.min(fu, m.L - LONGEST_UNDERLINE / 2));
        while (s > committed && s < m.L && (m.bytes[s] & 0xC0) == 0x80) s--;   // whole characters only
        String write = m.text(committed, s, "");
        String under = m.text(s, m.L, GAP);
        if (singleLine) { under = under.replace('\n', ' '); }
        if (write.isEmpty() && under.equals(shown)) return;
        ic.beginBatchEdit();
        if (!write.isEmpty()) {
            if (singleLine && write.indexOf('\n') >= 0) {
                // Enter in a one-line field does what Enter does there (search, send, next)
                String[] parts = write.split("\n", -1);
                ic.commitText(parts[0], 1);
                for (int i = 1; i < parts.length; i++) {
                    int action = info == null ? EditorInfo.IME_ACTION_DONE : info.imeOptions & EditorInfo.IME_MASK_ACTION;
                    if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) ic.performEditorAction(action);
                    ic.commitText(parts[i], 1);
                }
            } else ic.commitText(write, 1);
        }
        if (under.isEmpty()) { if (!shown.isEmpty() || !write.isEmpty()) ic.setComposingText("", 1); ic.finishComposingText(); }
        else ic.setComposingText(under, 1);
        ic.endBatchEdit();
        shown = under;
        committed = s;
    }
}
