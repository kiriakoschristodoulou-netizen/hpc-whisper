package net.kyriakos.whisper;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.graphics.Rect;
import android.os.Bundle;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The optional Whisper Tools helper (an accessibility service, off until you
 * turn it on in the phone's settings). It does only what you ask from the
 * handheld: press Send, go Back, Home or to Recent apps, and, for the remote,
 * tap, long-press, swipe and type. It reads nothing and keeps nothing.
 */
public class Helper extends AccessibilityService {
    public static final int BACK = 1, HOME = 2, RECENTS = 3;
    private static volatile Helper instance;

    /** Words a Send button carries (its label or description), in the languages it is most likely to meet. */
    private static final String[] SEND_WORDS = {"send", "αποστολή", "senden", "envoyer", "enviar", "invia", "verzenden", "отправить", "wyślij"};

    public static boolean on() { return instance != null; }

    @Override protected void onServiceConnected() { instance = this; }
    @Override public boolean onUnbind(android.content.Intent intent) { instance = null; return super.onUnbind(intent); }
    @Override public void onDestroy() { instance = null; super.onDestroy(); }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
    @Override public void onInterrupt() { }

    public static boolean global(int which) {
        Helper h = instance;
        if (h == null) return false;
        int a = which == BACK ? GLOBAL_ACTION_BACK : which == HOME ? GLOBAL_ACTION_HOME : GLOBAL_ACTION_RECENTS;
        return h.performGlobalAction(a);
    }

    /** Presses the Send button of the app in front, if one can be found. */
    public static boolean pressSend() {
        Helper h = instance;
        if (h == null) return false;
        AccessibilityNodeInfo root = h.getRootInActiveWindow();
        if (root == null) return false;
        List<AccessibilityNodeInfo> found = new ArrayList<>();
        collect(root, found, 0);
        // of several, the one lowest and furthest right is usually the one beside the text you wrote
        AccessibilityNodeInfo best = null;
        int bestScore = Integer.MIN_VALUE;
        Rect r = new Rect();
        for (AccessibilityNodeInfo n : found) {
            n.getBoundsInScreen(r);
            int score = r.bottom + r.right;
            if (score > bestScore) { bestScore = score; best = n; }
        }
        if (best == null) return false;
        AccessibilityNodeInfo c = best;
        while (c != null && !c.isClickable()) c = c.getParent();
        return c != null && c.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }

    private static void collect(AccessibilityNodeInfo n, List<AccessibilityNodeInfo> out, int depth) {
        if (n == null || depth > 40) return;
        if (n.isVisibleToUser() && isSend(n)) out.add(n);
        for (int i = 0; i < n.getChildCount(); i++) collect(n.getChild(i), out, depth + 1);
    }

    private static boolean isSend(AccessibilityNodeInfo n) {
        String[] texts = {str(n.getText()), str(n.getContentDescription()), n.getViewIdResourceName() == null ? "" : n.getViewIdResourceName()};
        for (String t : texts) {
            String l = t.toLowerCase(Locale.ROOT);
            if (l.isEmpty() || l.length() > 40) continue;
            for (String w : SEND_WORDS) if (l.equals(w) || l.startsWith(w + " ") || l.endsWith("/" + w) || l.endsWith("_" + w) || l.endsWith(":id/" + w)) return true;
        }
        return false;
    }

    private static String str(CharSequence s) { return s == null ? "" : s.toString(); }

    /** A tap (ms = 50), a long press (ms = 700), or a swipe, at screen pixels. */
    public static boolean gesture(float x1, float y1, float x2, float y2, long ms) {
        Helper h = instance;
        if (h == null) return false;
        Path p = new Path();
        p.moveTo(Math.max(0, x1), Math.max(0, y1));
        if (x2 != x1 || y2 != y1) p.lineTo(Math.max(0, x2), Math.max(0, y2));
        GestureDescription g = new GestureDescription.Builder().addStroke(new GestureDescription.StrokeDescription(p, 0, Math.max(1, ms))).build();
        return h.dispatchGesture(g, null, null);
    }

    /** Adds text to the field that has the focus (for the remote, when the Whisper Tools keyboard is not open). */
    public static boolean type(String s) {
        Helper h = instance;
        if (h == null) return false;
        AccessibilityNodeInfo root = h.getRootInActiveWindow();
        if (root == null) return false;
        AccessibilityNodeInfo f = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (f == null || !f.isEditable()) return false;
        CharSequence cur = f.getText();
        String now = cur == null ? "" : cur.toString();
        if (android.os.Build.VERSION.SDK_INT >= 26 && f.isShowingHintText()) now = "";
        Bundle b = new Bundle();
        b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, now + s);
        return f.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b);
    }
}
