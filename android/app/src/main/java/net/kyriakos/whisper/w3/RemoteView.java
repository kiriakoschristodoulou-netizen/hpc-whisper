package net.kyriakos.whisper.w3;

/**
 * Which part of the phone's screen the remote shows, and where a tap on the
 * handheld's picture lands on the phone. Modes: 0 whole screen (a portrait
 * screen turned sideways, its top on the left), 1 zoom (the screen's width
 * fills the handheld's), 2 zoom twice as large. Plain Java (tested).
 */
public final class RemoteView {
    public int mode = 1;
    public int viewW = 640, viewH = 192;       // the handheld's picture area
    public int sw = 1080, sh = 2340;           // the phone's screen
    public float x0, y0;                       // zoom: top-left of the window, in phone pixels

    public void setScreen(int w, int h) { sw = w; sh = h; clamp(); }
    public void setView(int mode, int w, int h) {
        this.mode = Math.max(0, Math.min(2, mode));
        viewW = Math.max(64, Math.min(Screen.MAX_W, w)); viewH = Math.max(32, Math.min(Screen.MAX_H, h));
        clamp();
    }

    public boolean rotated() { return mode == 0 && sh > sw; }

    /** Pixels of the picture per phone pixel. */
    public float scale() {
        if (mode == 0) return rotated() ? Math.min(viewW / (float) sh, viewH / (float) sw) : Math.min(viewW / (float) sw, viewH / (float) sh);
        return (mode == 2 ? 2f : 1f) * viewW / (float) sw;
    }

    /** The picture's size now. */
    public int picW() {
        float s = scale();
        if (mode == 0) return Math.max(1, Math.round((rotated() ? sh : sw) * s));
        return Math.min(viewW, Math.round(sw * s));
    }
    public int picH() {
        float s = scale();
        if (mode == 0) return Math.max(1, Math.round((rotated() ? sw : sh) * s));
        return Math.min(viewH, Math.round(sh * s));
    }

    /** Moves the zoom window by a number of picture pixels. */
    public void scroll(int dx, int dy) {
        float s = scale();
        x0 += dx / s; y0 += dy / s;
        clamp();
    }

    private void clamp() {
        if (mode == 0) { x0 = 0; y0 = 0; return; }
        float s = scale();
        float ww = viewW / s, wh = viewH / s;
        x0 = Math.max(0, Math.min(x0, sw - ww));
        y0 = Math.max(0, Math.min(y0, sh - wh));
    }

    /** A picture pixel to a phone pixel {x, y}. */
    public float[] toPhone(int px, int py) {
        float s = scale();
        if (rotated()) return new float[]{sw - (py + 0.5f) / s, (px + 0.5f) / s};
        return new float[]{x0 + (px + 0.5f) / s, y0 + (py + 0.5f) / s};
    }

    /**
     * The picture, from the phone's screen as greys (0..255, one byte per
     * pixel, screen size gw x gh, possibly smaller than the screen), averaged
     * over each picture pixel and cut to 16 greys.
     */
    public byte[] render(byte[] grey, int gw, int gh) {
        int W = picW(), H = picH();
        byte[] out = new byte[W * H];
        float s = scale();
        float gx = gw / (float) sw, gy = gh / (float) sh;        // grey pixels per phone pixel
        for (int py = 0; py < H; py++)
            for (int px = 0; px < W; px++) {
                // the phone-pixel area of this picture pixel
                float ax, ay, bx, by;
                if (rotated()) { ax = sw - (py + 1) / s; bx = sw - py / s; ay = px / s; by = (px + 1) / s; }
                else { ax = x0 + px / s; bx = x0 + (px + 1) / s; ay = y0 + py / s; by = y0 + (py + 1) / s; }
                int x1 = (int) (ax * gx), x2 = Math.max(x1 + 1, (int) (bx * gx)), y1 = (int) (ay * gy), y2 = Math.max(y1 + 1, (int) (by * gy));
                x1 = clampI(x1, 0, gw - 1); x2 = clampI(x2, x1 + 1, gw); y1 = clampI(y1, 0, gh - 1); y2 = clampI(y2, y1 + 1, gh);
                int sum = 0, n = 0;
                int stepX = Math.max(1, (x2 - x1) / 4), stepY = Math.max(1, (y2 - y1) / 4);
                for (int y = y1; y < y2; y += stepY) for (int x = x1; x < x2; x += stepX) { sum += grey[y * gw + x] & 255; n++; }
                int v = sum / Math.max(1, n);
                out[py * W + px] = (byte) ((v * 15 + 127) / 255);
            }
        return out;
    }

    private static int clampI(int v, int a, int b) { return v < a ? a : Math.min(v, b); }
}
