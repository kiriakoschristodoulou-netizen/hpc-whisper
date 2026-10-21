package net.kyriakos.whisper.gw;

import java.util.List;

/**
 * Makes the sound of one turn: optional lead tone, the frames (60 ms apart),
 * a tail of silence. Same shape as the handheld's turn player (wnframe.pas).
 */
public final class NetTx {
    private NetTx() {}

    /** Samples (16-bit) of a turn at the given rate. volume 0..1. */
    public static short[] turn(List<int[]> frames, int rate, int bandHz, int symMs, double volume,
                               int leadHz, int leadMs, int preMs, int gapMs, int tailMs) {
        long total = ms(rate, preMs) + ms(rate, tailMs);
        if (leadMs > 0) total += ms(rate, leadMs) + ms(rate, 50);
        for (int[] f : frames) total += (long) f.length * rate * symMs / 1000 + ms(rate, gapMs) + 2;
        short[] out = new short[(int) total + 16];
        int pos = (int) ms(rate, preMs);
        double ph = 0;
        int fade = rate / 200;
        if (leadMs > 0) {
            int len = (int) ms(rate, leadMs);
            tone(out, pos, len, leadHz, rate, volume / 4, fade, ph);
            pos += len + (int) ms(rate, 50);
        }
        for (int[] f : frames) {
            long symLen = (long) rate * symMs / 1000;
            int len = (int) (f.length * symLen);
            ph = 0;
            for (int k = 0; k < f.length; k++) {
                int a = pos + (int) (k * symLen), b = pos + (int) ((k + 1) * symLen);
                double w = 2 * Math.PI * (bandHz + 100 * f[k]) / rate;
                for (int i = a; i < b; i++) {
                    int rel = i - pos;
                    double env = 1;
                    if (rel < fade) env = (double) rel / fade;
                    else if (len - rel < fade) env = (double) (len - rel) / fade;
                    out[i] = (short) Math.round(Math.sin(ph) * 30000 * env * volume);
                    ph += w;
                }
            }
            pos += len + (int) ms(rate, gapMs);
        }
        return out;
    }

    private static void tone(short[] out, int pos, int len, int hz, int rate, double vol, int fade, double ph0) {
        double w = 2 * Math.PI * hz / rate, ph = ph0;
        for (int i = 0; i < len; i++) {
            double env = 1;
            if (i < fade) env = (double) i / fade; else if (len - i < fade) env = (double) (len - i) / fade;
            out[pos + i] = (short) Math.round(Math.sin(ph) * 30000 * env * vol);
            ph += w;
        }
    }

    private static long ms(int rate, int ms) { return (long) rate * ms / 1000; }
}
