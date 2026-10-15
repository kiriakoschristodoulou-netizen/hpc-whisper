import net.kyriakos.whisper.w3.*;
import java.io.*;
import java.util.*;
/** Writes SCREEN messages (scr_N.bin) and the picture they make (scr_pic.bin, 640 x 240, one grey per byte). */
public class ScreenDump {
    public static void main(String[] a) throws Exception {
        String dir = a[0];
        int gw = 540, gh = 1170; byte[] g = new byte[gw * gh]; Random r = new Random(5);
        for (int i = 0; i < g.length; i++) g[i] = (byte) ((i / gw) % 37 < 20 ? 240 : r.nextInt(256));
        RemoteView v = new RemoteView(); v.setScreen(1080, 2340); v.setView(1, 640, 192);
        Screen s = new Screen(); byte[] pic = v.render(g, gw, gh); s.set(pic, v.picW(), v.picH(), 0);
        int k = 0; byte[] m;
        while ((m = s.next(0, false)) != null) try (FileOutputStream o = new FileOutputStream(dir + "/scr_" + (k++) + ".bin")) { o.write(m); }
        byte[] full = new byte[640 * 240]; Arrays.fill(full, (byte) 15);
        for (int y = 0; y < v.picH(); y++) for (int x = 0; x < v.picW(); x++) full[y * 640 + x] = pic[y * v.picW() + x];
        try (FileOutputStream o = new FileOutputStream(dir + "/scr_pic.bin")) { o.write(full); }
        System.out.println(k + " messages");
    }
}
