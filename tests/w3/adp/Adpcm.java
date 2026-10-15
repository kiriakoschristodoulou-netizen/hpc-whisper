package net.kyriakos.whisper;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** IMA ADPCM in a WAV file (format 0x11), mono, as Windows writes it. Plain Java (tested). */
public final class Adpcm {
    private Adpcm() { }

    static final int[] STEP = {7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
            107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060,
            1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
            8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
    static final int[] INDEX = {-1, -1, -1, -1, 2, 4, 6, 8};

    public static int blockAlign(int rate) { return rate <= 11025 ? 256 : rate <= 22050 ? 512 : 1024; }
    public static int samplesPerBlock(int align) { return (align - 4) * 2 + 1; }

    public static byte[] wav(short[] pcm, int rate) {
        int align = blockAlign(rate), spb = samplesPerBlock(align);
        int blocks = (pcm.length + spb - 1) / spb;
        int dataLen = blocks * align;
        ByteBuffer b = ByteBuffer.allocate(60 + dataLen).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(52 + dataLen).put("WAVE".getBytes());
        b.put("fmt ".getBytes()).putInt(20).putShort((short) 0x11).putShort((short) 1).putInt(rate)
         .putInt(rate * align / spb).putShort((short) align).putShort((short) 4).putShort((short) 2).putShort((short) spb);
        b.put("fact".getBytes()).putInt(4).putInt(pcm.length);
        b.put("data".getBytes()).putInt(dataLen);
        int pred = 0, idx = 0;
        for (int k = 0; k < blocks; k++) {
            int s0 = k * spb;
            pred = s0 < pcm.length ? pcm[s0] : 0;
            b.putShort((short) pred).put((byte) idx).put((byte) 0);
            int nib = -1;
            for (int i = 1; i < spb; i++) {
                int x = s0 + i < pcm.length ? pcm[s0 + i] : 0;
                int step = STEP[idx], diff = x - pred, code = 0;
                if (diff < 0) { code = 8; diff = -diff; }
                int dq = step >> 3;
                if (diff >= step) { code |= 4; diff -= step; dq += step; }
                if (diff >= step >> 1) { code |= 2; diff -= step >> 1; dq += step >> 1; }
                if (diff >= step >> 2) { code |= 1; dq += step >> 2; }
                pred += (code & 8) != 0 ? -dq : dq;
                pred = Math.max(-32768, Math.min(32767, pred));
                idx = Math.max(0, Math.min(88, idx + INDEX[code & 7]));
                if (nib < 0) nib = code; else { b.put((byte) (nib | code << 4)); nib = -1; }
            }
            if (nib >= 0) b.put((byte) nib);
        }
        return b.array();
    }

    /** Decodes (tests, and the same steps as the handheld's player). */
    public static short[] decode(byte[] wav) {
        ByteBuffer b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN);
        int align = b.getShort(32) & 0xFFFF, spb = b.getShort(38) & 0xFFFF;
        int total = b.getInt(48), data = 60, len = b.getInt(56);
        short[] out = new short[total];
        int n = 0;
        for (int p = data; p + align <= data + len && n < total; p += align) {
            int pred = b.getShort(p), idx = wav[p + 2];
            out[n++] = (short) pred;
            for (int i = 0; i < (spb - 1) && n < total; i++) {
                int byt = wav[p + 4 + i / 2] & 255, code = (i & 1) == 0 ? byt & 15 : byt >> 4;
                int step = STEP[idx], dq = step >> 3;
                if ((code & 4) != 0) dq += step;
                if ((code & 2) != 0) dq += step >> 1;
                if ((code & 1) != 0) dq += step >> 2;
                pred += (code & 8) != 0 ? -dq : dq;
                pred = Math.max(-32768, Math.min(32767, pred));
                idx = Math.max(0, Math.min(88, idx + INDEX[code & 7]));
                out[n++] = (short) pred;
            }
        }
        return out;
    }
}
