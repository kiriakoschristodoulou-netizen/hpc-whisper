import net.kyriakos.whisper.Adpcm;
import java.nio.file.*;
public class AdpcmTest {
    public static void main(String[] a) throws Exception {
        int rate = Integer.parseInt(a[0]);
        short[] x = new short[rate * 3 + 123];
        for (int i = 0; i < x.length; i++) x[i] = (short) (12000 * Math.sin(2 * Math.PI * 440 * i / rate) + 4000 * Math.sin(2 * Math.PI * 1234 * i / rate));
        byte[] w = Adpcm.wav(x, rate);
        Files.write(Paths.get(a[1]), w);
        short[] y = Adpcm.decode(w);
        double e = 0, s = 0;
        for (int i = 0; i < x.length; i++) { s += x[i] * (double) x[i]; e += (x[i] - y[i]) * (double) (x[i] - y[i]); }
        System.out.printf("rate %d: %d bytes, SNR %.1f dB, %d samples back%n", rate, w.length, 10 * Math.log10(s / e), y.length);
    }
}
