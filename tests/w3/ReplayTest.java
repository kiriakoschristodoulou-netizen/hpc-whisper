import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/**
 * What the phone's listener does with a handheld whose sound runs fast or slow: the first frame shows the error, the
 * conversion is corrected at once and the last half second is given again, so that very frame is read.
 *   java -cp cls ReplayTest linux/w3tool [channel]
 */
public class ReplayTest {
    static volatile double pend; static volatile boolean has;
    public static void main(String[] a) throws Exception {
        String tool = a[0];
        int chId = a.length > 1 ? Integer.parseInt(a[1]) : 3;
        int L = 43200, RATE = 48000, CH = 2048;
        byte[] pl = new byte[chId <= 2 ? 27 : 300]; new Random(5).nextBytes(pl);
        Files.write(Paths.get("rep-payload.bin"), pl);
        new ProcessBuilder(tool, "tx", String.valueOf(chId), "1", "rep-payload.bin", "rep.wav", String.valueOf(L)).inheritIO().start().waitFor();
        byte[] d = Files.readAllBytes(Paths.get("rep.wav"));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[(d.length - 44) / 2];
        b.position(44);
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        int fails = 0;
        for (double pct : new double[]{-1.0, -0.7, -0.5, -0.3, -0.1, 0, 0.1, 0.3, 0.5, 0.7, 1.0}) {
            int T = (int) Math.round(L * (1 + pct / 100));
            Resampler toPhone = new Resampler(T, RATE);
            float[] y = new float[toPhone.maxOut(x.length) + RATE];
            toPhone.process(x, 0, x.length, y, 0);
            Random rnd = new Random(7);
            for (int i = 0; i < y.length; i++) y[i] = y[i] * 0.1f + (float) (1e-4 * rnd.nextGaussian());
            final int[] read = {0, 0};
            final double[] q = {-99};
            Rx rx = new Rx(Channel.get(chId), new Rx.Sink() {
                public void onMessage(Rx r, int type, byte[] msg, float snr, int fixed) { read[0]++; q[0] = snr; }
                public void onTrain(Rx r, float[] snr) { }
                public void onFail(Rx r, String w) { }
                public void onRateOffset(Rx r, double delta, double qual) { if (qual >= 0.7 && Math.abs(delta) <= 0.03) { pend = delta; has = true; } }
            });
            double jScale = 1.0;
            Resampler rs = new Resampler(RATE * jScale, Channel.RATE);
            float[] out = new float[CH * 2 + 16];
            int replays = 0; long lastReplay = -1;
            has = false;
            for (int pos = 0; pos < y.length; pos += CH) {
                int n = Math.min(CH, y.length - pos);
                // applyRateOffset: before this chunk is converted
                if (has) {
                    has = false;
                    double dl = pend;
                    if (Math.abs(dl) >= 0.00003) {
                        jScale *= 1 - (Math.abs(dl) > 0.001 ? 1.0 : 0.9) * dl;
                        rs.setRates(RATE * jScale, Channel.RATE);
                        if (Math.abs(dl) > 0.0004 && (lastReplay < 0 || pos - lastReplay > RATE)) {
                            lastReplay = pos; replays++;
                            rs = new Resampler(RATE * jScale, Channel.RATE);
                            rx.reset();
                            for (int p = Math.max(0, pos - RATE / 2); p < pos; ) {
                                int m = Math.min(CH, pos - p);
                                int o = rs.process(y, p, m, out, 0);
                                rx.push(out, 0, o);
                                p += m;
                            }
                        }
                    }
                }
                
                int o = rs.process(y, pos, n, out, 0);
                rx.push(out, 0, o);
            }
            boolean ok = read[0] >= 1 && q[0] >= 10;
            if (!ok) fails++;
            System.out.printf("%s play rate off %+5.2f%%: %s, %d replay(s), scale %.4f%n", ok ? "ok  " : "FAIL", pct,
                    read[0] > 0 ? String.format("read %.1f dB", q[0]) : "not read", replays, jScale);
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails != 0) System.exit(1);
    }
}
