import net.kyriakos.whisper.w3.*;
import java.util.*;
public class Loop {
    public static void main(String[] a) { if (a.length > 0) Rx.DEBUG = true;
        Random r = new Random(5);
        String[] names = Channel.NAMES;
        for (int id = 0; id < Channel.COUNT; id++) {
            Channel ch = Channel.get(id);
            for (double noise : new double[]{0.0, 0.01, 0.02, 0.03}) {
                final int[] got = {0}; final float[] snr = {0}; final List<String> fails = new ArrayList<>();
                byte[] msg = new byte[id <= 2 ? 30 : 700]; r.nextBytes(msg);
                Rx rx = new Rx(ch, new Rx.Sink() {
                    public void onMessage(Rx x, int type, byte[] m, float s, int f) { if (Arrays.equals(m, msg) && type == 1) got[0]++; snr[0] = s; }
                    public void onTrain(Rx x, float[] s) {}
                    public void onFail(Rx x, String w) { fails.add(w); }
                });
                int frames = 5;
                for (int k = 0; k < frames; k++) {
                    float[] f = Tx.frame(ch, BitMap.standard(ch), 1, msg, ch.level);
                    int gap = 3000 + r.nextInt(5000);
                    float[] x = new float[gap + f.length + 2000];
                    System.arraycopy(f, 0, x, gap, f.length);
                    for (int i = 0; i < x.length; i++) x[i] += (float) (noise * r.nextGaussian());
                    rx.push(x, 0, x.length);
                }
                System.out.printf("%-18s noise %.2f: %d of %d  snr %.1f dB  fails %s%n", names[id], noise, got[0], frames, snr[0], fails);
            }
        }
    }
}
