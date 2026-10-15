package net.kyriakos.whisper;

/**
 * Keys that travel inside the handheld's text as characters from Unicode's
 * private area, U+E000 + code (docs/FORMAT3.md, section 3).
 */
public final class Keys {
    public static final int BASE = 0xE000;
    public static final int BACKSPACE = 0x08, TAB = 0x09, SHIFT_TAB = 0x0A, ESC = 0x1B, PAGE_UP = 0x21, PAGE_DOWN = 0x22,
            END = 0x23, HOME = 0x24, LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, DELETE = 0x2E,
            SELECT_ALL = 0x41, COPY = 0x43, PASTE = 0x56, CUT = 0x58, UNDO = 0x5A,
            SEND = 0x80, BACK = 0x81, HOME_SCREEN = 0x82, RECENTS = 0x83;

    private Keys() { }

    /** The key a character stands for, or -1 for an ordinary character. */
    public static int keyOf(int codePoint) {
        return codePoint >= BASE && codePoint < BASE + 0x100 ? codePoint - BASE : -1;
    }

    /** Where the first key character starts in UTF-8 bytes [from, to), or -1. */
    public static int findKey(byte[] b, int from, int to) {
        for (int i = from; i + 2 < to; i++)
            if ((b[i] & 255) == 0xEE && (b[i + 1] & 0xFC) == 0x80 && (b[i + 2] & 0xC0) == 0x80) return i;
        return -1;
    }

    /** The key code of the UTF-8 key character at i. */
    public static int codeAt(byte[] b, int i) { return ((b[i + 1] & 3) << 6) | (b[i + 2] & 63); }

    /** Text with the key characters taken out (for showing, underlined, what is not written yet). */
    public static String strip(String s) {
        StringBuilder o = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) { char c = s.charAt(i); if (keyOf(c) < 0) o.append(c); }
        return o.toString();
    }

    public static String name(int code) {
        switch (code) {
            case BACKSPACE: return "Backspace"; case TAB: return "Tab"; case SHIFT_TAB: return "Shift+Tab"; case ESC: return "Esc";
            case PAGE_UP: return "Page Up"; case PAGE_DOWN: return "Page Down"; case END: return "End"; case HOME: return "Home";
            case LEFT: return "Left"; case UP: return "Up"; case RIGHT: return "Right"; case DOWN: return "Down"; case DELETE: return "Delete";
            case SELECT_ALL: return "Select all"; case COPY: return "Copy"; case PASTE: return "Paste"; case CUT: return "Cut"; case UNDO: return "Undo";
            case SEND: return "Send"; case BACK: return "Back"; case HOME_SCREEN: return "Home screen"; case RECENTS: return "Recent apps";
            default: return "Key " + code;
        }
    }

    /** As shown in text on the phone's own screen: a short sign for each key. */
    public static String sign(int code) {
        switch (code) {
            case TAB: return "⇥"; case SHIFT_TAB: return "⇤"; case BACKSPACE: return "⌫"; case ESC: return "⎋"; case LEFT: return "←";
            case RIGHT: return "→"; case UP: return "↑"; case DOWN: return "↓"; case SEND: return "[Send]"; default: return "[" + name(code) + "]";
        }
    }

    /** Text for showing: keys as signs. */
    public static String show(String s) {
        StringBuilder o = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) { char c = s.charAt(i); int k = keyOf(c); if (k < 0) o.append(c); else o.append(sign(k)); }
        return o.toString();
    }
}
