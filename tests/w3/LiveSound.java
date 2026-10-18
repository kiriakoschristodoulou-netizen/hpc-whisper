import net.kyriakos.whisper.w3.Pair;
import java.nio.*;
import java.nio.file.*;

/**
 * The handheld's real test sound (recorded by the phone, 3.9.0): its clock is 0.01 % off what it says, which the
 * pitch of the markers must show (and which the receivers need no correction for).
 *   java -cp cls LiveSound live-sound-390.wav
 */
public class LiveSound {
    public static void main(String[] a) throws Exception {
        byte[] d = Files.readAllBytes(Paths.get(a[0]));
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        int rate = b.getInt(24), n = (d.length - 44) / 2;
        float[] x = new float[n];
        b.position(44);
        for (int i = 0; i < n; i++) x[i] = b.getShort() / 32768f;
        Pair.Result r = Pair.analyze(x, n, rate);
        double sc = r.found ? Pair.pitchScale(x, n, rate, r.aAt, r.bAt) : Double.NaN;
        boolean ok = r.found && Math.abs(sc - 0.9999) < 0.0001;
        System.out.printf("%s    live test sound: the handheld's clock %+.4f %% (expected -0.0096 %%)%n", ok ? "ok  " : "FAIL", (sc - 1) * 100);
        System.exit(ok ? 0 : 1);
    }
}
