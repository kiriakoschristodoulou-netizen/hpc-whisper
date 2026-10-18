import net.kyriakos.whisper.w3.*;
import java.util.*;

/**
 * The handheld's silent channel through Windows CE's playback conversion, which drops samples going from
 * 44,100 to the chip's 43,200, against a handheld that plays at 43,200 directly. Prints how many frames the
 * phone reads for each path at each background noise. Exit 1 if the direct path loses frames at low noise.
 */
public class DropTest {
    static Random R = new Random(5);
    static byte[] got; static int fails;

    static float[] drop(float[] x, double outRate) {
        double ratio = 44100.0 / outRate; float[] y = new float[(int) (x.length / ratio)];
        for (int i = 0; i < y.length; i++) y[i] = x[(int) (i * ratio)];
        return y;
    }

    public static void main(String[] a) {
        int ch = a.length > 0 ? Integer.parseInt(a[0]) : Channel.SU_NARROW;
        Channel c = Channel.get(ch);
        BitMap map = BitMap.standard(c);
        int bad = 0;
        for (double nz : new double[]{0.001, 0.003, 0.01}) {
            StringBuilder sb = new StringBuilder(String.format("noise %.3f:", nz));
            for (String k : new String[]{"ideal 44100", "CE drops 44100->43200", "plays 43200"}) {
                Rx rx = new Rx(c, new Rx.Sink() {
                    public void onMessage(Rx x, int t, byte[] m, float s, int f) { got = m; }
                    public void onTrain(Rx x, float[] s) { }
                    public void onFail(Rx x, String w) { fails++; }
                });
                int ok = 0, tries = 8;
                for (int t = 0; t < tries; t++) {
                    byte[] msg = new byte[40]; R.nextBytes(msg); got = null;
                    float[] f = Tx.frame(c, map, 1, msg, c.level);
                    float[] pad = new float[f.length + 8000]; System.arraycopy(f, 0, pad, 4000, f.length);
                    float[] air;
                    if (k.startsWith("ideal")) air = Resampler.convert(Resampler.convert(pad, 51200, 44100), 44100, 48000 * 1.00012);
                    else if (k.startsWith("CE")) air = Resampler.convert(drop(Resampler.convert(pad, 51200, 44100), 43200), 43200, 48000 * 1.00012);
                    else air = Resampler.convert(Resampler.convert(pad, 51200, 43200), 43200, 48000 * 1.00012);
                    float[] mic = ToneChain.room(air, 48000, nz, 0.5);
                    float[] y = Resampler.convert(mic, 48000, 51200);
                    rx.push(y, 0, y.length);
                    if (got != null && Arrays.equals(got, msg)) ok++;
                }
                sb.append(String.format("  [%s] %d/%d", k, ok, tries));
                if (nz == 0.001 && k.startsWith("plays") && ok < tries - 1) bad++;
            }
            System.out.println(sb);
        }
        if (bad > 0) { System.out.println("FAIL: playing at 43,200 directly lost frames at low noise"); System.exit(1); }
    }
}
