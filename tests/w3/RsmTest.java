import net.kyriakos.whisper.w3.Resampler;
public class RsmTest {
    public static void main(String[] a) {
        double[][] pairs = {{51200, 44100}, {51200, 48000}, {44100, 51200}, {48000, 51200}, {43229.6, 51200}};
        for (double[] pr : pairs) {
            StringBuilder sb = new StringBuilder(String.format("%7.1f -> %7.1f:", pr[0], pr[1]));
            for (double f : new double[]{1000, 10000, 18000, 19400, 20800, 21200}) {
                int n = (int) pr[0];
                float[] x = new float[n];
                for (int i = 0; i < n; i++) x[i] = (float) Math.sin(2 * Math.PI * f * i / pr[0]);
                float[] y = Resampler.convert(x, pr[0], pr[1]);
                // amplitude by correlation in the middle
                double sr = 0, si = 0; int m0 = y.length / 4, m1 = 3 * y.length / 4;
                for (int i = m0; i < m1; i++) { sr += y[i] * Math.cos(2 * Math.PI * f * i / pr[1]); si += y[i] * Math.sin(2 * Math.PI * f * i / pr[1]); }
                double amp = 2 * Math.hypot(sr, si) / (m1 - m0);
                double res = 0; double ph = Math.atan2(sr, si);
                for (int i = m0; i < m1; i++) { double e = y[i] - amp * Math.sin(2 * Math.PI * f * i / pr[1] + ph); res += e * e; }
                sb.append(String.format("  %5.1fk %+5.1fdB (err %.0f dB)", f / 1000, 20 * Math.log10(amp), 10 * Math.log10(res / (m1 - m0) / (amp * amp / 2) + 1e-12)));
            }
            System.out.println(sb);
        }
    }
}
