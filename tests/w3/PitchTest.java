import net.kyriakos.whisper.w3.Pair;
import net.kyriakos.whisper.w3.Resampler;

/**
 * The handheld's clock from the pitch of its test sound's markers (Pair.pitchScale, 3.9.1): the pattern played by a chip
 * whose clock is off by up to 2 %, through a room, recorded at 48,000, must give the error to 0.02 %.
 *   java -cp cls PitchTest
 */
public class PitchTest {
    public static void main(String[] a) {
        int fails = 0;
        double[] errs = {-0.02, -0.005, -0.001, 0.0001, 0.0, 0.0003, 0.002, 0.01, 0.0204};
        for (double e : errs) {
            double s = 1 + e;                                  // the chip plays s times slower than it says
            float[] p = Pair.pattern(44100);
            float[] slow = Resampler.convert(p, 44100, 44100 * s);          // more samples, played at 44,100: stretched by s
            float[] air = Resampler.convert(slow, 44100, 48000);
            float[] x = new float[air.length + 24000];
            java.util.Random r = new java.util.Random(7);
            for (int i = 0; i < air.length; i++) x[12000 + i] = air[i] * 0.3f + (float) (0.002 * r.nextGaussian());
            Pair.Result res = Pair.analyze(x, x.length, 48000);
            double got = res.found ? Pair.pitchScale(x, x.length, 48000, res.aAt, res.bAt) : Double.NaN;
            boolean ok = res.found && Math.abs(got - s) < 0.0002;
            System.out.printf("%s  clock off %+.4f %%: measured %+.4f %%%n", ok ? "ok  " : "FAIL", e * 100, (got - 1) * 100);
            if (!ok) fails++;
        }
        System.out.println(fails == 0 ? "ALL PASS" : "FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
