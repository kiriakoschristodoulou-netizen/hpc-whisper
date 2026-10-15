import net.kyriakos.whisper.w3.*;
import java.util.*;
public class TrainTest {
    public static void main(String[] a) {
        for (int id = 0; id < Channel.COUNT; id++) {
            Channel ch = Channel.get(id);
            final float[][] got = {null};
            Rx rx = new Rx(ch, new Rx.Sink() {
                public void onMessage(Rx x, int t, byte[] m, float s, int f) {}
                public void onTrain(Rx x, float[] s) { got[0] = s; }
                public void onFail(Rx x, String w) { System.out.println("fail " + w); }
            });
            float[] f = Tx.train(ch, ch.level);
            float[] x = new float[f.length + 8000]; System.arraycopy(f, 0, x, 4000, f.length);
            Random r = new Random(1); for (int i = 0; i < x.length; i++) x[i] += 0.002 * r.nextGaussian();
            rx.push(x, 0, x.length);
            System.out.println(Channel.NAMES[id] + ": " + (got[0] == null ? "none" : String.format("%.1f %.1f %.1f ...", got[0][0], got[0][1], got[0][2])));
        }
    }
}
