import net.kyriakos.whisper.w3.*;
import java.io.*; import java.nio.*; import java.util.*;

/**
 * The pairing check through a simulated pair: one side's pattern, played at its rate, through a speaker
 * with a shaped response, a 25 ms fade-in, a room (echoes, noise, a steady 20 kHz tone), recorded at the
 * other side's real rate while its sound card claims another; read by the phone's Java and the handheld's
 * Pascal (pairtool). Checks: found, the rate ratio, and each tone's level against what was put in.
 */
public class PairTest {
    static double gainDb(double f) {           // a weak small speaker: strong 4-12 kHz, falling above 18 kHz
        if (f < 1000) return -25; if (f < 3000) return -12; if (f < 13000) return 0; if (f < 18000) return -10;
        if (f < 20000) return -18; return -24 - (f - 20000) / 300.0;
    }
    public static void main(String[] a) throws Exception {
        int bad = 0;
        int[][] cases = {{44100, 48000, 48011, 48000}, {48000, 44100, 43230, 44100}, {48000, 48000, 48000, 48000}};
        for (int[] cs : cases) {
            int txRate = cs[0], rxClaim = cs[1], rxTrue = cs[2];
            float[] p = Pair.pattern(txRate);
            // speaker: shape each tone by its gain (filter in the frequency domain over the whole pattern)
            float[] shaped = shape(p, txRate);
            // 25 ms fade-in from the start of the sound
            for (int i = 0; i < txRate * 25 / 1000 && i < shaped.length; i++) shaped[i] *= i / (txRate * 0.025f);
            // into the air at the true receiving rate (the sender's clock taken as exact), with 1 s before and after
            float[] air = Resampler.convert(shaped, txRate, rxTrue);
            float[] rec = new float[air.length + 2 * rxTrue];
            Random r = new Random(7);
            for (int i = 0; i < rec.length; i++) rec[i] = (float) (r.nextGaussian() * 0.002 + 0.0005 * Math.sin(2 * Math.PI * 19999.8 * i / rxTrue));
            for (int i = 0; i < air.length; i++) { rec[rxTrue + i] += air[i]; if (i > 300) rec[rxTrue + i] += 0.3f * air[i - 300]; }
            Pair.Result res = Pair.analyze(rec, rec.length, rxClaim);
            write("/tmp/pairsim.wav", rec, rxClaim);
            Process pr = new ProcessBuilder("./linux/pairtool", "an", "/tmp/pairsim.wav").start();
            String out = new String(pr.getInputStream().readAllBytes());
            double expect = (double) rxTrue / rxClaim;
            System.out.printf("%d -> %d (says %d): java %s scale %.4f (expected %.4f)%n", txRate, rxTrue, rxClaim, res.found ? "found" : "NOT FOUND", res.scale10k / 10000.0, expect);
            System.out.print("  pascal: " + out.replace("\n", "\n  "));
            StringBuilder s = new StringBuilder("  java snr:");
            for (int i = 0; i < Pair.N; i++) s.append(' ').append(res.snr10[i] / 10);
            System.out.println(s);
            StringBuilder g = new StringBuilder("  speaker: ");
            for (int i = 0; i < Pair.N; i++) g.append(' ').append((int) gainDb(Pair.HZ[i]));
            System.out.println(g);
            if (!res.found || Math.abs(res.scale10k / 10000.0 - expect) > 0.002 || !out.startsWith("found")) bad++;
            // tones the speaker plays well must read well, and the weakest ones lowest
            if (res.snr10[10] < 200 || res.snr10[31] > res.snr10[10]) bad++;
        }
        // nothing but noise and the tone: must not be found
        float[] z = new float[48000 * 5]; Random r = new Random(3);
        for (int i = 0; i < z.length; i++) z[i] = (float) (r.nextGaussian() * 0.01 + 0.001 * Math.sin(2 * Math.PI * 2000 * i / 48000.0 * (i % 30000 < 9000 ? 1 : 0)));
        if (Pair.analyze(z, z.length, 48000).found) { bad++; System.out.println("found in noise!"); }
        System.out.println(bad == 0 ? "ALL PASS" : bad + " FAILED");
        System.exit(bad);
    }
    static float[] shape(float[] x, int rate) {
        int n = 1; while (n < x.length) n <<= 1;
        double[] re = new double[n], im = new double[n];
        for (int i = 0; i < x.length; i++) re[i] = x[i];
        fft(re, im, -1);
        for (int k = 0; k < n; k++) { double f = Math.min(k, n - k) * (double) rate / n; double g = Math.pow(10, gainDb(f) / 20); re[k] *= g; im[k] *= g; }
        fft(re, im, 1);
        float[] y = new float[x.length]; for (int i = 0; i < y.length; i++) y[i] = (float) (re[i] / n); return y;
    }
    static void fft(double[] re, double[] im, int sign) {
        int n = re.length;
        for (int i = 1, j = 0; i < n; i++) { int bit = n >> 1; for (; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
        for (int len = 2; len <= n; len <<= 1) { double ang = sign * 2 * Math.PI / len;
            for (int i = 0; i < n; i += len) for (int k = 0; k < len / 2; k++) { double c = Math.cos(ang * k), s = Math.sin(ang * k);
                double xr = re[i + k + len / 2] * c - im[i + k + len / 2] * s, xi = re[i + k + len / 2] * s + im[i + k + len / 2] * c;
                re[i + k + len / 2] = re[i + k] - xr; im[i + k + len / 2] = im[i + k] - xi; re[i + k] += xr; im[i + k] += xi; } }
    }
    static void write(String fn, float[] x, int rate) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(44 + x.length * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + x.length * 2).put("WAVEfmt ".getBytes()).putInt(16).putShort((short) 1).putShort((short) 1)
         .putInt(rate).putInt(rate * 2).putShort((short) 2).putShort((short) 16).put("data".getBytes()).putInt(x.length * 2);
        for (float v : x) b.putShort((short) Math.max(-32767, Math.min(32767, Math.round(v * 32767))));
        try (FileOutputStream o = new FileOutputStream(fn)) { o.write(b.array()); }
    }
}
