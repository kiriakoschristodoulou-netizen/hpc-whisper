package net.kyriakos.whisper;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/** 36 bars, one per tone from 18.0 to 21.5 kHz; the loud ones light up green. */
public final class MeterView extends View {
    private final float[] lv = new float[Receiver.GRID_N];
    private final Paint off = new Paint(Paint.ANTI_ALIAS_FLAG), on = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();

    public MeterView(Context c) {
        super(c);
        off.setColor(0xFF3A4658);
        on.setColor(0xFF7FC75A);
    }

    public void set(float[] levels) {
        System.arraycopy(levels, 0, lv, 0, lv.length);
        invalidate();
    }

    public void clear() { java.util.Arrays.fill(lv, 0); invalidate(); }

    @Override
    protected void onDraw(Canvas c) {
        float max = 1e-12f;
        for (float v : lv) max = Math.max(max, v);
        float w = getWidth(), h = getHeight(), gap = w / 36f * 0.25f, bw = w / 36f - gap;
        for (int i = 0; i < 36; i++) {
            float rel = (float) Math.sqrt(lv[i] / max);
            boolean hot = lv[i] > max * 0.3f && lv[i] > 1e-3f;
            float bh = Math.max(h * 0.06f, h * (lv[i] > 1e-3f ? rel : 0));
            float x = i * (bw + gap);
            r.set(x, h - bh, x + bw, h);
            c.drawRoundRect(r, bw / 3, bw / 3, hot ? on : off);
        }
    }
}
