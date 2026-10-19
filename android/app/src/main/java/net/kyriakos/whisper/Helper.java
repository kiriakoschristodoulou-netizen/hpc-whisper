package net.kyriakos.whisper;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The optional HPC Whisper helper (an accessibility service, off until you
 * turn it on in the phone's settings). It does only what you ask from the
 * handheld: press Send, go Back, Home or to Recent apps. It reads nothing and
 * keeps nothing.
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
}
