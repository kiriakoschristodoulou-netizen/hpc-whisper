import net.kyriakos.whisper.w3.*;
import java.util.*;
public class PosScan { public static void main(String[] a) {
  int id = Integer.parseInt(a[0]); Channel ch = Channel.get(id); int only = a.length > 1 ? Integer.parseInt(a[1]) : -1;
  Random r = new Random(1); int ok = 0, n = 0; StringBuilder bad = new StringBuilder();
  for (int shift = 0; shift < 1300; shift += 23) {
    byte[] msg = new byte[ch.silent ? 40 : 900]; r.nextBytes(msg);
    Rx.DEBUG = shift == only;
    final byte[][] got = {null};
    Rx rx = new Rx(ch, new Rx.Sink() { public void onMessage(Rx x, int t, byte[] m, float s, int f) { got[0] = m; }
      public void onTrain(Rx x, float[] s) {} public void onFail(Rx x, String w) {} });
    float[] f = Sim.pad(Tx.frame(ch, BitMap.standard(ch), 1, msg, ch.level), 4000 + shift, 4000);
    float[] y = Sim.up(f);
    rx.push(y, 0, y.length); n++;
    if (got[0] != null && Arrays.equals(got[0], msg)) ok++; else bad.append(shift).append(' ');
  }
  System.out.println(Channel.NAMES[id] + ": " + ok + " of " + n + "  failed at " + bad);
}}
