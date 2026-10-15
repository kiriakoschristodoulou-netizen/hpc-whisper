import net.kyriakos.whisper.*;
import java.io.*;
import java.util.*;

/** The handheld's TEXT payloads (texttool) into the phone's TextLink; keys found; the answer confirms everything. */
public class TextTest {
    public static void main(String[] a) throws Exception {
        Process p = new ProcessBuilder(a[0]).start();
        BufferedReader in = new BufferedReader(new InputStreamReader(p.getInputStream()));
        PrintWriter out = new PrintWriter(p.getOutputStream(), true);
        TextLink t = new TextLink();
        String line; long now = 0; int frames = 0;
        while (!(line = in.readLine()).equals("END")) {
            byte[] b = new byte[line.length() / 2];
            for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(line.substring(2 * i, 2 * i + 2), 16);
            t.onText(b, now += 100); frames++;
        }
        Mirror m = t.mirror;
        String shown = Keys.show(m.text(0, m.L, "?"));
        List<String> keys = new ArrayList<>();
        int k = 0;
        while ((k = Keys.findKey(m.bytes, k, m.L)) >= 0) { keys.add(Keys.name(Keys.codeAt(m.bytes, k))); k += 3; }
        byte[] ack = t.ackIfDue(now + 1000);
        StringBuilder h = new StringBuilder(); for (byte x : ack) h.append(String.format("%02X", x & 255));
        out.println(h); out.close();
        String last = null, l2; while ((l2 = in.readLine()) != null) last = l2;
        System.out.println(frames + " frames; phone has: " + shown);
        System.out.println("keys: " + keys + "; handheld: " + last);
        boolean ok = shown.equals("Dear Ann⇥H[Copy]⌫[Send]") && keys.equals(Arrays.asList("Tab", "Copy", "Backspace", "Send")) && last.startsWith("unconfirmed 0 ");
        System.out.println(ok ? "ALL PASS" : "FAILED");
        System.exit(ok ? 0 : 1);
    }
}
