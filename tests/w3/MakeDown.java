import net.kyriakos.whisper.w3.*;
import java.util.*;
import java.nio.file.*;
/** Phone frames through the room into the handheld's ADC, at many positions: files for w3tool rx. */
public class MakeDown { public static void main(String[] a) throws Exception {
  int id = Integer.parseInt(a[0]), count = Integer.parseInt(a[1]), len = Integer.parseInt(a[2]); String dir = a[3];
  Channel ch = Channel.get(id); Random r = new Random(11);
  for (int k = 0; k < count; k++) {
    byte[] msg = new byte[len]; r.nextBytes(msg);
    Files.write(Paths.get(dir, "m" + k + ".bin"), msg);
    float[] f = Sim.pad(Tx.frame(ch, BitMap.standard(ch), 1, msg, ch.level), 4000 + k * 37, 4000);
    float[] x48 = Resampler.convert(f, 51200, 48000);
    float[] air = Resampler.convert(x48, 48000, 43229.6);
    float[] mic = Sim.room(air, 43229.6, Sim.NOISE, 0.5);
    W3Tool.writeWav(dir + "/m" + k + ".wav", mic, 44100);      // the handheld says 44,100
  }
}}
