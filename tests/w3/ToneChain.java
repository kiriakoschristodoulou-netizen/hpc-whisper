import net.kyriakos.whisper.Mirror;
import net.kyriakos.whisper.Receiver;
import net.kyriakos.whisper.w3.Resampler;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/**
 * The version 2 tones (the base layer) through the Jornada's playback chain: the sound a handheld plays at
 * 44,100 that Windows CE turns into the chip's 43,200 by DROPPING samples, against the same tones made at
 * 43,200 directly (nothing dropped) and an ideal path. Reads two raw files made by wmsim (args: ideal 44100
 * raw, native 43200 raw, expected text) and prints how much of the text the phone's receiver gets at each
 * background noise level. Exit 1 when the native path fails at the lowest noise.
 */
public class ToneChain {
    static Random R = new Random(7);

    static float[] load(String f) throws Exception {
        byte[] raw = Files.readAllBytes(Paths.get(f));
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[raw.length / 2];
        for (int i = 0; i < x.length; i++) x[i] = bb.getShort() / 32768f;
        return x;
    }

    /** Windows CE's conversion to the chip: every output sample is an input sample, some are skipped. */
    static float[] drop(float[] x44, double outRate) {
        double ratio = 44100.0 / outRate; int n = (int) (x44.length / ratio);
        float[] y = new float[n];
        for (int i = 0; i < n; i++) y[i] = x44[(int) (i * ratio)];
        return y;
    }

    static float[] room(float[] x, double rate, double noise, double gain) {
        int d1 = (int) (rate * 0.0006), d2 = (int) (rate * 0.004), d3 = (int) (rate * 0.012);
        float[] y = new float[x.length + d3 + 100];
        for (int i = 0; i < x.length; i++) { y[i] += x[i]; y[i + d1] += 0.3f * x[i]; y[i + d2] += 0.1f * x[i]; y[i + d3] += 0.05f * x[i]; }
        for (int i = 0; i < y.length; i++) y[i] = (float) (y[i] * gain + noise * R.nextGaussian() + 0.01 * Math.sin(2 * Math.PI * 160 * i / rate));
        return y;
    }

    /** What the phone's receiver reads from a recording at 48,000 (the phone's own clock 120 ppm fast). */
    static String read(float[] mic) {
        final Mirror m = new Mirror();
        Receiver rx = new Receiver(48000, new Receiver.Listener() {
            public void onFrame(Receiver.Frame f) { m.apply(f, 0); }
            public void onUnreadable(int b, int ms) { }
        });
        for (int i = 0; i < mic.length; i += 2048) rx.push(mic, i, Math.min(2048, mic.length - i), 1);
        return m.text(0, m.L, "#");
    }

    static String chain(String kind, float[] x44, float[] x432, double noise) {
        float[] air;
        if (kind.equals("ideal")) air = Resampler.convert(x44, 44100, 48000 * 1.00012);
        else if (kind.equals("dropped")) air = Resampler.convert(drop(x44, 43200), 43200, 48000 * 1.00012);
        else air = Resampler.convert(x432, 43200, 48000 * 1.00012);
        return read(room(air, 48000, noise, 0.5));
    }

    public static void main(String[] a) throws Exception {
        float[] x44 = load(a[0]), x432 = load(a[1]);
        String want = a[2];
        int bad = 0;
        for (double nz : new double[]{0.001, 0.003, 0.01}) {
            StringBuilder sb = new StringBuilder(String.format("noise %.3f:", nz));
            for (String k : new String[]{"ideal", "dropped", "native"}) {
                int ok = 0, tries = 4;
                for (int t = 0; t < tries; t++) if (chain(k, x44, x432, nz).equals(want)) ok++;
                sb.append(String.format("  %s %d/%d", k, ok, tries));
                if (nz == 0.001 && k.equals("native") && ok < tries) bad++;
            }
            System.out.println(sb);
        }
        if (bad > 0) { System.out.println("FAIL: the native path did not read at low noise"); System.exit(1); }
    }
}
