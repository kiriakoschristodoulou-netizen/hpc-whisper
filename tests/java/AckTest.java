import net.kyriakos.whisper.Ack;
import net.kyriakos.whisper.Mirror;

/** prints: doc P G hash and then the acknowledgement symbols, for a mirror with a gap (compared with modem.js by test_ack_java.js) */
public class AckTest {
    public static void main(String[] a) {
        Mirror m = new Mirror();
        byte[] text = "Hello world, this is a test of 27".getBytes();
        m.doc = 77; m.L = 33;
        for (int i = 0; i < 33; i++) { m.bytes[i] = text[i]; m.known[i] = i < 20 || i >= 26; }
        Ack.State s = Ack.of(m);
        StringBuilder sb = new StringBuilder(s.doc + " " + s.p + " " + s.g + " " + s.hash + " :");
        for (int v : Ack.symbols(s.doc, s.p, s.g, s.hash)) sb.append(' ').append(v);
        System.out.println(sb);
        m.known[20] = true;                       // a prefix of 21, a gap of 5 bytes (21..25)
        s = Ack.of(m);
        System.out.println(s.p + " " + s.g);
        for (int i = 0; i < 33; i++) m.known[i] = true;
        s = Ack.of(m);
        System.out.println(s.p + " " + s.g);
        short[] pcm = Ack.pcm(Ack.symbols(1, 2, 3, 4), 48000, 0.5);
        System.out.println(pcm.length);
    }
}
