import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Resampler;
import net.kyriakos.whisper.w3.Rx;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;

/** A recording with no frames in it (the phone's diagnostics tape): no frame may be read and no reading of the rate may be trusted.
 *    java -cp cls TapeCheck tape.wav [channel...] */
public class TapeCheck {
    public static void main(String[] a) throws Exception {
        byte[] d = Files.readAllBytes(Paths.get(a[0]));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        int rate = b.getInt(24);
        float[] x = new float[(d.length - 44) / 2];
        b.position(44);
        for (int i = 0; i < x.length; i++) x[i] = b.getShort() / 32768f;
        int bad = 0;
        for (int k = 1; k < a.length; k++) {
            int chId = Integer.parseInt(a[k]);
            final int[] n = {0, 0, 0};
            Rx rx = new Rx(Channel.get(chId), new Rx.Sink() {
                public void onMessage(Rx r, int type, byte[] msg, float snr, int fixed) { n[0]++; }
                public void onTrain(Rx r, float[] snr) { }
                public void onFail(Rx r, String w) { n[1]++; }
                public void onRateOffset(Rx r, double delta, double q) { if (q >= 0.8 && Math.abs(delta) <= 0.015) n[2]++; }
            });
            Resampler rs = new Resampler(rate, Channel.RATE);
            float[] out = new float[rs.maxOut(2048) + 8];
            for (int p = 0; p < x.length; p += 2048) {
                int m = Math.min(2048, x.length - p);
                int o = rs.process(x, p, m, out, 0);
                rx.push(out, 0, o);
            }
            System.out.printf("channel %d: %d frames read, %d starts that failed, %d rate readings trusted%n", chId, n[0], n[1], n[2]);
            if (n[2] > 0) bad++;
        }
        System.out.println(bad == 0 ? "ALL PASS" : bad + " FAILED");
        if (bad != 0) System.exit(1);
    }
}
