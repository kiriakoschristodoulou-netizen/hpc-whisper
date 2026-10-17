import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/**
 * The handheld's chip plays its frames at a rate a little different from the one they were made for. The phone
 * measures the offset from each frame's sync symbol and corrects its conversion; the next frame must read cleanly.
 *   java -cp cls AfcTest linux/w3tool [channel]
 */
public class AfcTest {
    public static void main(String[] a) throws Exception {
        String tool = a[0];
        int chId = a.length > 1 ? Integer.parseInt(a[1]) : 0;
        int L = 43200;
        byte[] pl = new byte[chId <= 2 ? 27 : 600]; new Random(5).nextBytes(pl);
        Files.write(Paths.get("afc-payload.bin"), pl);
        new ProcessBuilder(tool, "tx", String.valueOf(chId == 0 ? 0 : chId), "1", "afc-payload.bin", "afc.wav", String.valueOf(L)).inheritIO().start().waitFor();
        byte[] d = Files.readAllBytes(Paths.get("afc.wav"));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[(d.length - 44) / 2];
        b.position(44);
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        int fails = 0;
        double[] pcts = {-1.0, -0.5, -0.3, -0.14, -0.05, 0, 0.05, 0.14, 0.3, 0.5, 1.0};
        for (double noiseDb : new double[]{1e-4, 3e-3}) {
            for (double pct : pcts) {
                int T = (int) Math.round(L * (1 + pct / 100));
                Resampler toPhone = new Resampler(T, 48000);
                float[] y = new float[toPhone.maxOut(x.length) + 48000];
                toPhone.process(x, 0, x.length, y, 0);
                Random rnd = new Random(7);
                for (int i = 0; i < y.length; i++) y[i] = y[i] * 0.1f + (float) (noiseDb * rnd.nextGaussian());
                double scale = 1.0;                           // what the phone has learned so far
                String line = "";
                double lastQ = -99;
                for (int round = 0; round < 3; round++) {
                    Resampler toModem = new Resampler(48000 * scale, Channel.RATE);
                    float[] z = new float[toModem.maxOut(y.length)];
                    int m = toModem.process(y, 0, y.length, z, 0);
                    final double[] q = {-99}, est = {Double.NaN, 0};
                    Rx r = new Rx(Channel.get(chId), new Rx.Sink() {
                        public void onMessage(Rx rx, int type, byte[] msg, float snr, int fixed) { q[0] = snr; }
                        public void onTrain(Rx rx, float[] snr) { }
                        public void onFail(Rx rx, String w) { }
                        public void onRateOffset(Rx rx, double delta, double qual) { if (Double.isNaN(est[0])) { est[0] = delta; est[1] = qual; } }
                    });
                    r.push(z, 0, m);
                    line += String.format("  round %d: estimate %s -> %s", round,
                            Double.isNaN(est[0]) ? "none" : String.format("%+.3f%% (q %.2f)", est[0] * 100, est[1]),
                            q[0] > -99 ? String.format("read %.1f dB", q[0]) : "not read");
                    lastQ = q[0];
                    if (!Double.isNaN(est[0]) && est[1] > 0.3) scale = scale * (1 - est[0] * 0.8);
                }
                boolean ok = lastQ >= 18;
                if (!ok) fails++;
                System.out.printf("%s noise %.0e, play rate off %+5.2f%%:%s%n", ok ? "ok  " : "FAIL", noiseDb, pct, line);
            }
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
    }
}
