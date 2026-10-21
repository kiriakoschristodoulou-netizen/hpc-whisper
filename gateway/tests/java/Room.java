import java.util.Random;

/** A simulated room: resampling between the two devices' real clock rates, a ghost
 *  tone 900 Hz lower (the Jornada's sound chip), an echo, noise. */
public final class Room {
    public double noise = 300, ghost = 0.3, echo = 0.3, echoMs = 3;
    public Random rnd = new Random(1);

    public short[] pass(short[] src, int srcRate, int dstRate) {
        int m = (int) ((long) src.length * dstRate / srcRate);
        short[] dst = new short[m];
        double ph = 0, gstep = 2 * Math.PI * (-900) / dstRate;
        for (int i = 0; i < m; i++) {
            double pos = (double) i * srcRate / dstRate;
            int a = (int) pos, b = Math.min(a + 1, src.length - 1);
            double x = src[a] + (src[b] - src[a]) * (pos - a), v = x;
            if (ghost > 0) { ph += gstep; v += ghost * x * Math.cos(ph) * 2; }
            int e = (int) Math.round(pos - echoMs / 1000 * srcRate);
            if (echo > 0 && e >= 0) v += echo * src[e];
            v += noise * rnd.nextGaussian();
            dst[i] = (short) Math.max(-32768, Math.min(32767, Math.round(v)));
        }
        return dst;
    }
}
