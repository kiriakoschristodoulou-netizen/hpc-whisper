import net.kyriakos.whisper.Mirror;
import net.kyriakos.whisper.Receiver;
import net.kyriakos.whisper.SelfTest;
import net.kyriakos.whisper.w3.Resampler;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;

/**
 * The self test's two programs agree: the handheld's frames of tones (wtest.pas, made by selftool) are read by the
 * phone's Receiver through the Jornada's playback chain (samples dropped, 44,100 to 43,200) and the room, and
 * counted by SelfTest.onTone; the handheld's results arrive the same way; the test frames' fill is the same
 * bytes on both sides.
 *   java SelfToolTest DIR   (DIR holds t0..t4.wav, report.wav, p.bin made by selftool; see selftest.sh)
 */
public class SelfToolTest {
    static float[] load(String f) throws Exception {
        byte[] raw = Files.readAllBytes(Paths.get(f));
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int rate = bb.getInt(24);
        float[] x = new float[(raw.length - 44) / 2];
        bb.position(44);
        for (int i = 0; i < x.length; i++) x[i] = bb.getShort() / 32768f;
        return x;
    }

    static int fails = 0;
    static void check(String what, boolean ok) { System.out.println((ok ? "ok    " : "FAIL  ") + what); if (!ok) fails++; }

    /** What the phone reads from a recording at 44,100 that the Jornada's chip played at 43,200 by dropping samples. */
    static void read(float[] x44, double noise, SelfTest st, int[] frames) {
        float[] air = Resampler.convert(ToneChain.drop(x44, 43200), 43200, 48000 * 1.00012);
        float[] mic = ToneChain.room(air, 48000, noise, 0.5);
        Receiver rx = new Receiver(48000, new Receiver.Listener() {
            public void onFrame(Receiver.Frame f) { frames[0]++; st.onTone(f); }
            public void onUnreadable(int b, int ms) { }
        });
        for (int i = 0; i < mic.length; i += 2048) rx.push(mic, i, Math.min(2048, mic.length - i), 1);
    }

    public static void main(String[] a) throws Exception {
        String d = a[0];
        SelfTest st = new SelfTest();
        int[] frames = {0};
        for (int i = 0; i < SelfTest.NTONE; i++) read(load(d + "/t" + i + ".wav"), 0.002, st, frames);
        check("the five test tone frames are all read through the Jornada's playback chain", st.toneMask == 31 && frames[0] == 5);
        check("their run number comes through", st.run == 42);
        SelfTest st2 = new SelfTest();
        read(load(d + "/report.wav"), 0.002, st2, new int[]{0});
        check("the handheld's results frame is read: silent down 5, fast down 3, end mark", st2.reported && st2.sdMask == 5 && st2.fdMask == 3 && st2.endPHeard);
        check("its two loudness values come through (23 dB, -4 dB)", st2.lowDb == 23 && st2.highDb == -4);
        check("the results are not text for the keyboard (onTone says so)", new SelfTest().onTone(frame(SelfTest.DOC_REPORT, new byte[]{1, 0, 0, 0, 0, 0, 20, 20, 0})));
        byte[] p = Files.readAllBytes(Paths.get(d + "/p.bin"));
        check("a test frame's fill is the same on both sides", Arrays.equals(p, SelfTest.payload(42, SelfTest.ST_SD, 2)));
        check("and passes the phone's check", SelfTest.payloadOk(p));
        p[10] ^= 1;
        check("a damaged one does not", !SelfTest.payloadOk(p));
        System.exit(fails == 0 ? 0 : 1);
    }

    static Receiver.Frame frame(int doc, byte[] b) { Receiver.Frame f = new Receiver.Frame(); f.doc = doc; f.bytes = b; return f; }
}
