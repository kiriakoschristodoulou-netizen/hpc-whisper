import net.kyriakos.whisper.w3.*;
import java.util.*;

/** The remote's screen: a phone screen rendered, sent as tiles, rebuilt; then a small change. */
public class ScreenTest {
    public static void main(String[] a) {
        int gw = 540, gh = 1170;                         // the screen captured at half size
        byte[] g = new byte[gw * gh];
        Random r = new Random(1);
        Arrays.fill(g, (byte) 245);
        // "text": rows of small dark blocks, and a dark top bar
        for (int y = 0; y < 60; y++) for (int x = 0; x < gw; x++) g[y * gw + x] = (byte) 40;
        for (int line = 0; line < 40; line++) {
            int y0 = 90 + line * 26;
            for (int x = 20; x < gw - 20; x += 9) if (r.nextInt(6) > 0)
                for (int y = y0; y < y0 + 12; y++) for (int xx = x; xx < x + 6; xx++) g[y * gw + xx] = (byte) 30;
        }
        int bad = 0;
        for (int mode = 0; mode <= 2; mode++) {
            RemoteView v = new RemoteView();
            v.setScreen(1080, 2340); v.setView(mode, 640, 192);
            Screen s = new Screen();
            byte[] pic = v.render(g, gw, gh);
            s.set(pic, v.picW(), v.picH(), 0);
            byte[] rebuilt = new byte[s.tw * 16 * s.th * 16];
            int msgs = 0, bytes = 0; byte[] m;
            while ((m = s.next(0, false)) != null) { msgs++; bytes += m.length; if (m.length > 2047) bad++; Screen.apply(m, rebuilt, s.tw * 16); }
            boolean same = true;
            for (int y = 0; y < v.picH(); y++) for (int x = 0; x < v.picW(); x++) if (rebuilt[y * s.tw * 16 + x] != pic[y * v.picW() + x]) same = false;
            if (!same) bad++;
            // a small change: one line of new text
            for (int y = 300; y < 312; y++) for (int x = 100; x < 300; x++) g[y * gw + x] = (byte) 20;
            byte[] pic2 = v.render(g, gw, gh);
            s.set(pic2, v.picW(), v.picH(), 1000);
            int msgs2 = 0, bytes2 = 0;
            while ((m = s.next(1000, false)) != null) { msgs2++; bytes2 += m.length; Screen.apply(m, rebuilt, s.tw * 16); }
            float[] t = v.toPhone(v.picW() / 2, v.picH() / 2);
            System.out.printf("mode %d: picture %dx%d, whole screen %d bytes in %d messages (%s); a change %d bytes in %d; centre tap -> phone %.0f,%.0f%n",
                    mode, v.picW(), v.picH(), bytes, msgs, same ? "rebuilt exactly" : "WRONG", bytes2, msgs2, t[0], t[1]);
        }
        System.out.println(bad == 0 ? "ALL PASS" : bad + " FAILED");
        System.exit(bad);
    }
}
