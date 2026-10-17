import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Random;

/**
 * The handheld's frames made at the rate its sound chip really runs at (3.8): the handheld's own code makes a
 * silent frame at each rate (w3tool tx ... RATE), the chip plays it at that rate, the phone hears it at 48,000
 * with a little noise, and reads it. Every rate must read cleanly (30 dB or more; frames made at 44,100 and turned into 43,200 by Windows CE read at 16 dB at best).
 *   java -cp cls RateTest linux/w3tool
 */
public class RateTest {
    public static void main(String[] a) throws Exception {
        String tool = a[0];
        Files.write(Paths.get("rate-payload.bin"), "hello world, this is a test".getBytes());
        int fails = 0;
        for (int rate : (a.length > 1 ? java.util.Arrays.stream(a, 1, a.length).mapToInt(Integer::parseInt).toArray() : new int[]{44100, 43203, 43260, 47950, 48000})) {
            Process p = new ProcessBuilder(tool, "tx", "0", "1", "rate-payload.bin", "rate.wav", String.valueOf(rate)).inheritIO().start();
            p.waitFor();
            byte[] d = Files.readAllBytes(Paths.get("rate.wav"));
            ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
            int got = b.getInt(24);
            float[] x = new float[(d.length - 44) / 2];
            b.position(44);
            for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
            // played at its rate, heard at 48,000
            Resampler toPhone = new Resampler(got, 48000);
            float[] y = new float[toPhone.maxOut(x.length) + 48000];
            int n = toPhone.process(x, 0, x.length, y, 0);
            Random rnd = new Random(rate);
            for (int i = 0; i < y.length; i++) y[i] = y[i] * 0.1f + (float) (1e-4 * rnd.nextGaussian());
            Resampler toModem = new Resampler(48000, Channel.RATE);
            float[] z = new float[toModem.maxOut(y.length)];
            int m = toModem.process(y, 0, y.length, z, 0);
            final double[] q = {-99};
            Rx r = new Rx(Channel.get(Channel.SU_NARROW), new Rx.Sink() {
                public void onMessage(Rx rx, int type, byte[] msg, float snr, int fixed) { q[0] = snr; }
                public void onTrain(Rx rx, float[] snr) { }
                public void onFail(Rx rx, String why) { }
            });
            r.push(z, 0, m);
            boolean ok = got == rate && q[0] >= 30;
            System.out.printf("%s made at %d (file says %d): %s%n", ok ? "ok  " : "FAIL", rate, got, q[0] > -99 ? String.format("read, %.1f dB", q[0]) : "not read");
            if (!ok) fails++;
        }
        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        if (fails > 0) System.exit(1);
    }
}
