import net.kyriakos.whisper.Mirror;
import net.kyriakos.whisper.Receiver;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Desktop check of the keyboard's receiver: decode a 48 kHz 16-bit mono raw file, print the text. */
public class Decode {
    public static void main(String[] a) throws Exception {
        byte[] raw = Files.readAllBytes(Paths.get(a[0]));
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        float[] x = new float[raw.length / 2];
        for (int i = 0; i < x.length; i++) x[i] = bb.getShort() / 32768f;
        Mirror m = new Mirror();
        final int[] frames = {0};
        Receiver rx = new Receiver(48000, new Receiver.Listener() {
            public void onFrame(Receiver.Frame f) { frames[0]++; m.apply(f, 0); }
            public void onUnreadable(int b, int ms) {}
        });
        long t0 = System.nanoTime();
        for (int i = 0; i < x.length; i += 2048) rx.push(x, i, Math.min(2048, x.length - i), 1);
        double s = (System.nanoTime() - t0) / 1e9;
        System.out.println(frames[0] + " frames, " + String.format("%.1f", x.length / 48000.0 / s) + "x real time");
        System.out.println(m.text(0, m.L, "#"));
    }
}
