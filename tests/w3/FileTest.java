import net.kyriakos.whisper.w3.*;
import java.util.*;

/** File transfer logic: sender and receiver over a lossy link, with and without answers. */
public class FileTest {
    static int run(int size, double loss, double backLoss, boolean answers, long seed) {
        Random r = new Random(seed);
        byte[] d = new byte[size]; r.nextBytes(d);
        FileSend s = new FileSend(77, "photo.jpg", 1, d);
        FileRecv v = null;
        long now = 0, busyUntil = 0, unknownAt = -1;
        int steps = 0;
        while (!s.done && !s.failed && steps++ < 200000) {
            now += 10;
            if (now >= busyUntil) {
                FileSend.Msg m = s.next(now);
                if (m != null) {
                    busyUntil = now + 300 + m.payload.length / 2;   // a frame's time on air
                    if (r.nextDouble() >= loss) {
                        long t = busyUntil;
                        if (m.type == FileSend.T_OFFER) { if (v == null) v = FileRecv.fromOffer(m.payload, t, 1 << 24); else v.onOffer(t); }
                        else if (m.type == FileSend.T_DATA && v != null) v.onData(m.payload, t);
                        else if (m.type == FileSend.T_DATA) { unknownAt = t; }
                    }
                }
            }
            if (v == null && answers && unknownAt >= 0 && now - unknownAt > FileRecv.QUIET_MS && now >= busyUntil) {
                unknownAt = -1;
                if (r.nextDouble() >= backLoss) s.onNeed(FileRecv.needOffer(77), now + 200);
                busyUntil = Math.max(busyUntil, now + 200);
            }
            if (v != null && answers && now >= busyUntil && v.needDue(now)) {
                byte[] n = v.need();
                if (r.nextDouble() >= backLoss) s.onNeed(n, now + 200);
                busyUntil = Math.max(busyUntil, now + 200);
            }
        }
        boolean ok = v != null && v.complete() && Arrays.equals(v.data(), d);
        System.out.printf("size %7d loss %.2f back %.2f answers %-5b: %s%s, %d packets sent for %d, %.1f s%n", size, loss, backLoss, answers,
                ok ? "complete" : "INCOMPLETE", s.confirmedAll ? " (confirmed)" : s.failed ? " (failed)" : "", s.sentPackets, s.packets, now / 1000.0);
        return ok ? 0 : 1;
    }
    public static void main(String[] a) {
        int bad = 0;
        bad += run(1, 0, 0, true, 1);
        bad += run(1024, 0, 0, true, 2);
        bad += run(50000, 0, 0, true, 3);
        bad += run(50000, 0.1, 0.1, true, 4);
        bad += run(300000, 0.2, 0.2, true, 5);
        bad += run(300000, 0.4, 0.3, true, 6);
        bad += run(20000, 0.0, 0, false, 7);
        int blind = run(20000, 0.05, 0, false, 8);          // without answers some loss is expected to remain sometimes
        System.out.println(bad == 0 ? "ALL PASS" : bad + " FAILED");
        System.exit(bad);
    }
}
