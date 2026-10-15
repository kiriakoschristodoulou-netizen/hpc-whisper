import net.kyriakos.whisper.w3.Rs;
import java.util.Random;
public class RsTest {
    public static void main(String[] a) {
        Random r = new Random(1); int ok = 0, bad = 0, tries = 0, miscorr = 0;
        for (int t = 0; t < 3000; t++) {
            int p = 8 + 2 * r.nextInt(13), k = 1 + r.nextInt(223 - 0); int n = k + p;
            byte[] cw = new byte[n]; for (int i = 0; i < k; i++) cw[i] = (byte) r.nextInt(256);
            Rs.encode(cw, 0, k, p, cw, k);
            byte[] orig = cw.clone();
            int e = r.nextInt(p / 2 + 1);
            java.util.HashSet<Integer> pos = new java.util.HashSet<>();
            while (pos.size() < e) pos.add(r.nextInt(n));
            for (int q : pos) cw[q] ^= (byte) (1 + r.nextInt(255));
            int got = Rs.decode(cw, 0, n, p); tries++;
            if (got == e && java.util.Arrays.equals(cw, orig)) ok++; else { bad++; if (bad < 5) System.out.println("fail p=" + p + " k=" + k + " e=" + e + " got=" + got); }
        }
        // beyond capacity: must mostly say -1
        for (int t = 0; t < 2000; t++) {
            int p = 16, k = 100, n = k + p; byte[] cw = new byte[n]; for (int i = 0; i < k; i++) cw[i] = (byte) r.nextInt(256);
            Rs.encode(cw, 0, k, p, cw, k); byte[] orig = cw.clone();
            for (int q = 0; q < 12; q++) cw[r.nextInt(n)] ^= (byte) (1 + r.nextInt(255));
            int got = Rs.decode(cw, 0, n, p);
            if (got >= 0) miscorr++;
        }
        System.out.println("correctable: " + ok + " of " + tries + " fixed; too many errors: " + miscorr + " of 2000 wrongly accepted");
        if (bad > 0) System.exit(1);
    }
}
