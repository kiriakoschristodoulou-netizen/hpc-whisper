import net.kyriakos.whisper.w3.*;
import java.util.*;

/** Both directions through simulated devices and a room, with a link check (TRAIN -> map). */
public class Sim {
    static Random R = new Random(42);

    /** The Jornada's sound chip: straight-line interpolation from 44.1 kHz to its own 43.2 kHz (the ghost). */
    static float[] chip(float[] x44) {
        double ratio = 44100.0 / 43200.0; int n = (int) (x44.length / ratio);
        float[] y = new float[n];
        for (int i = 0; i < n; i++) { double p = i * ratio; int a = (int) p; double f = p - a; y[i] = (float) (x44[a] * (1 - f) + (a + 1 < x44.length ? x44[a + 1] : 0) * f); }
        return y;
    }
    static float[] room(float[] x, double rate, double noise, double gain) {
        // a table close by, the room, and a far wall (Turbo test 2: a longer guard gap gained nothing)
        int d1 = (int) (rate * 0.0006), d2 = (int) (rate * 0.004), d3 = (int) (rate * 0.012);
        float[] y = new float[x.length + d3 + 100];
        for (int i = 0; i < x.length; i++) { y[i] += x[i]; y[i + d1] += 0.3f * x[i]; y[i + d2] += 0.1f * x[i]; y[i + d3] += 0.05f * x[i]; }
        for (int i = 0; i < y.length; i++) y[i] = (float) (y[i] * gain + noise * R.nextGaussian() + 0.01 * Math.sin(2 * Math.PI * 160 * i / rate));
        return y;
    }
    static float[] pad(float[] f, int pre, int post) { float[] x = new float[pre + f.length + post]; System.arraycopy(f, 0, x, pre, f.length); return x; }

    /** handheld -> phone */
    static float[] up(float[] f51) {
        float[] x44 = Resampler.convert(pad(f51, 4000, 4000), 51200, 44100);
        float[] x432 = chip(x44);
        float[] air = Resampler.convert(x432, 43200, 48000 * 1.00012);      // the phone's clock runs 120 ppm fast
        float[] mic = room(air, 48000, NOISE, 0.5);
        return Resampler.convert(mic, 48000, 51200);
    }
    /** phone -> handheld: the handheld records at 43,229.6 but we only know it to 0.02 % */
    static float[] down(float[] f51) {
        float[] x48 = Resampler.convert(pad(f51, 4000, 4000), 51200, 48000);
        float[] air = Resampler.convert(x48, 48000, 43229.6);
        float[] mic = room(air, 43229.6, NOISE, 0.5);
        return Resampler.convert(mic, 43229.6 * 1.0002, 51200);
    }
    static double NOISE = 0.002;

    static byte[] got; static float[] snr; static int fails;
    static Rx rx(Channel ch) {
        return new Rx(ch, new Rx.Sink() {
            public void onMessage(Rx x, int t, byte[] m, float s, int f) { got = m; }
            public void onTrain(Rx x, float[] s) { snr = s; }
            public void onFail(Rx x, String w) { fails++; }
        });
    }

    public static void main(String[] a) {
        for (double nz : new double[]{0.001, 0.003, 0.006}) {
            NOISE = nz;
            System.out.printf("--- background noise %.3f%n", nz);
            for (int id = 0; id < Channel.COUNT; id++) {
                Channel ch = Channel.get(id);
                boolean isUp = id == Channel.SU_NARROW || id == Channel.SU_WIDE || id == Channel.FU;
                // link check: TRAIN, then a map
                Rx r = rx(ch); snr = null; fails = 0;
                float[] y = isUp ? up(Tx.train(ch, ch.level)) : down(Tx.train(ch, ch.level));
                r.push(y, 0, y.length);
                BitMap map = BitMap.standard(ch);
                String ms = "no training";
                if (snr != null) {
                    map = BitMap.fromSnr(ch, 1, snr); if (map.bitsPerSymbol() < 4) { System.out.println(Arrays.toString(snr)); map = BitMap.standard(ch); } r.addMap(map);
                    float mn = 99, mx = -99; for (int c = 0; c < snr.length; c++) { mn = Math.min(mn, snr[c]); mx = Math.max(mx, snr[c]); }
                    ms = String.format("trained %4.1f..%4.1f dB, %d bits/symbol (default %d)", mn, mx, map.bitsPerSymbol(), BitMap.standard(ch).bitsPerSymbol());
                }
                int ok = 0, tries = 6, len = ch.silent ? 40 : 1000;
                for (int k = 0; k < tries; k++) {
                    byte[] msg = new byte[len]; R.nextBytes(msg);
                    got = null;
                    float[] f = Tx.frame(ch, map, 1, msg, ch.level);
                    y = isUp ? up(f) : down(f);
                    r.push(y, 0, y.length);
                    if (got != null && Arrays.equals(got, msg)) ok++;
                }
                double kbps = map.bitsPerSymbol() * 80 / 1000.0;
                System.out.printf("%-18s %s  -> %d of %d frames (%.1f kbit/s raw)%n", Channel.NAMES[id], ms, ok, tries, kbps);
            }
        }
    }
}
