import java.io.ByteArrayOutputStream;
import java.util.*;
import net.kyriakos.whisper.gw.*;
import net.kyriakos.whisper.gw.NetCodec.Frame;

/** The link layer alone, over a channel that loses frames. */
public class LinkTest {
    static int fails = 0, checks = 0;
    static void check(boolean ok, String what) { checks++; if (!ok) { fails++; System.out.println("FAIL  " + what); } else System.out.println("PASS  " + what); }

    static class Side implements Link.Listener {
        Link link; ByteArrayOutputStream got = new ByteArrayOutputStream(); int resets = 0;
        Side(Random r) { link = new Link(this, r); }
        public void onData(byte[] b, int off, int len) { got.write(b, off, len); }
        public void onPeerReset() { resets++; got.reset(); }
    }

    static void turn(Side from, Side to, Random r, double loss) {
        for (Frame f : from.link.turn()) if (r.nextDouble() >= loss) to.link.receive(f);
    }

    static boolean run(String name, long seed, double loss, int bytes, boolean restartB) {
        Random r = new Random(seed);
        Side a = new Side(r), b = new Side(r);
        byte[] da = new byte[bytes], db = new byte[bytes];
        r.nextBytes(da); r.nextBytes(db);
        int pa = 0, pb = 0, turns = 0;
        boolean restarted = false, aSawReset = false;
        while (turns < 3000) {
            turns++;
            int k = Math.min(r.nextInt(60) + 1, Math.min(bytes - pa, a.link.free()));
            if (k > 0 && (!restarted || aSawReset) && a.link.write(da, pa, k)) pa += k;
            k = Math.min(r.nextInt(60) + 1, Math.min(bytes - pb, b.link.free()));
            if (k > 0 && b.link.write(db, pb, k)) pb += k;
            turn(a, b, r, loss);
            turn(b, a, r, loss);
            if (restarted && !aSawReset && a.resets > 0) {
                // A has been told the other side is new: its next data is for the new program
                aSawReset = true; pa = 0; r.nextBytes(da);
            }
            if (restartB && !restarted && b.got.size() > bytes / 2) {
                restarted = true; pb = 0; r.nextBytes(db);
                b = new Side(r); a.resets = 0;
            }
            if (pa == bytes && pb == bytes && a.link.pending() == 0 && b.link.pending() == 0
                && a.got.size() >= bytes && b.got.size() >= bytes && (!restartB || aSawReset)) break;
        }
        boolean ok = Arrays.equals(a.got.toByteArray(), db) && Arrays.equals(b.got.toByteArray(), da);
        check(ok, name + " (loss " + (int) (loss * 100) + "%, " + turns + " turns)");
        return ok;
    }

    public static void main(String[] x) {
        run("clean, 3000 bytes each way", 1, 0, 3000, false);
        run("20% frames lost", 2, 0.2, 3000, false);
        run("50% frames lost", 3, 0.5, 3000, false);
        run("tiny: 10 bytes, 30% lost", 4, 0.3, 10, false);
        for (int s = 10; s < 16; s++) run("random " + s, s, 0.35, 1500, false);
        for (int s = 20; s < 26; s++) run("other side restarts, seed " + s, s, 0.3, 1500, true);
        System.out.println(checks - fails + " of " + checks + " checks passed");
        if (fails > 0) System.exit(1);
    }
}
