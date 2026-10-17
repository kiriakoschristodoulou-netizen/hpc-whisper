import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/** The handheld makes a frame for rate L, but the chip plays it at T (a little different): how well does the phone read it? */
public class MisTest {
    public static void main(String[] a) throws Exception {
        String tool = a[0];
        int L = Integer.parseInt(a[1]);
        int len = a.length > 2 ? Integer.parseInt(a[2]) : 27;
        byte[] pl = new byte[len]; new Random(5).nextBytes(pl);
        Files.write(Paths.get("mis-payload.bin"), pl);
        new ProcessBuilder(tool, "tx", "0", "1", "mis-payload.bin", "mis.wav", String.valueOf(L)).inheritIO().start().waitFor();
        byte[] d = Files.readAllBytes(Paths.get("mis.wav"));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[(d.length - 44) / 2];
        b.position(44);
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        for (double pct : new double[]{-0.5, -0.3, -0.2, -0.14, -0.1, -0.05, 0, 0.05, 0.1, 0.14, 0.2, 0.3, 0.5, 1.0}) {
            int T = (int) Math.round(L * (1 + pct / 100));
            Resampler toPhone = new Resampler(T, 48000);
            float[] y = new float[toPhone.maxOut(x.length) + 48000];
            toPhone.process(x, 0, x.length, y, 0);
            Random rnd = new Random(7);
            for (int i = 0; i < y.length; i++) y[i] = y[i] * 0.1f + (float) (1e-4 * rnd.nextGaussian());
            Resampler toModem = new Resampler(48000, Channel.RATE);
            float[] z = new float[toModem.maxOut(y.length)];
            int m = toModem.process(y, 0, y.length, z, 0);
            final double[] q = {-99};
            final String[] why = {""};
            Rx r = new Rx(Channel.get(Channel.SU_NARROW), new Rx.Sink() {
                public void onMessage(Rx rx, int type, byte[] msg, float snr, int fixed) { q[0] = snr; }
                public void onTrain(Rx rx, float[] snr) { }
                public void onFail(Rx rx, String w) { why[0] = w; }
            });
            r.push(z, 0, m);
            System.out.printf("play rate off %+5.2f%% (%d vs %d): %s%n", pct, T, L, q[0] > -99 ? String.format("read, %.1f dB", q[0]) : "NOT read (" + why[0] + ")");
        }
    }
}
