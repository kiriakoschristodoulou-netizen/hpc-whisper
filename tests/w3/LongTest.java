import net.kyriakos.whisper.w3.*;
import java.util.*;
public class LongTest { public static void main(String[] a) {
  Random r = new Random(9);
  for (int id = 0; id < Channel.COUNT; id++) {
    Channel ch = Channel.get(id); boolean up = id == 0 || id == 1 || id == 3;
    int ok = 0, n = 3, len = ch.silent ? 1000 : 2000; String info = "";
    for (int k = 0; k < n; k++) {
      byte[] msg = new byte[len]; r.nextBytes(msg);
      final byte[][] got = {null}; final float[] snr = {0};
      Rx rx = new Rx(ch, new Rx.Sink() { public void onMessage(Rx x, int t, byte[] m, float s, int f) { got[0] = m; snr[0] = s; }
        public void onTrain(Rx x, float[] s) {} public void onFail(Rx x, String w) {} });
      float[] f = Tx.frame(ch, BitMap.standard(ch), 1, msg, ch.level);
      float[] y = up ? Sim.up(f) : Sim.down(f);
      rx.push(y, 0, y.length);
      if (got[0] != null && Arrays.equals(got[0], msg)) ok++;
      info = String.format("%d symbols, %.1f s, snr %.1f dB", f.length / 640, f.length / 51200.0, snr[0]);
    }
    System.out.println(Channel.NAMES[id] + ": " + ok + " of " + n + " (" + info + ")");
  }
}}
