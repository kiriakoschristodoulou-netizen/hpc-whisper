package net.kyriakos.whisper.w3;

/** In-place complex FFT of 512 points (radix 2). sign -1: forward, +1: inverse (not scaled). */
public final class Fft {
    private static final int N = 512, LOG = 9;
    private static final float[] COS = new float[N / 2], SIN = new float[N / 2];
    private static final int[] REV = new int[N];
    static {
        for (int i = 0; i < N / 2; i++) { COS[i] = (float) Math.cos(2 * Math.PI * i / N); SIN[i] = (float) Math.sin(2 * Math.PI * i / N); }
        for (int i = 0; i < N; i++) { int r = 0; for (int b = 0; b < LOG; b++) if ((i & (1 << b)) != 0) r |= 1 << (LOG - 1 - b); REV[i] = r; }
    }

    public static void run(float[] re, float[] im, int sign) {
        for (int i = 0; i < N; i++) {
            int j = REV[i];
            if (j > i) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
        }
        for (int len = 2; len <= N; len <<= 1) {
            int half = len >> 1, step = N / len;
            for (int i = 0; i < N; i += len)
                for (int k = 0; k < half; k++) {
                    float wr = COS[k * step], wi = sign * SIN[k * step];
                    int a = i + k, b = a + half;
                    float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi;
                    re[a] += xr; im[a] += xi;
                }
        }
    }
}
