package net.kyriakos.whisper.w3;

/**
 * Tones down (docs/FORMAT3.md, section 9): how the phone reaches the handheld without the modem. 16 tones, 100 Hz
 * apart from 17.8 kHz, one tone a symbol (4 bits), 30 ms a symbol. A frame is a preamble of 8 symbols, then the
 * coded header and message of format 3, scrambled as on the silent channel down, a nibble (high first) at a time.
 * The handheld's receiver is handheld/wtone.pas.
 */
public final class ToneDown {
    public static final int NT = 16, FIRST = 178, SYM = 1536, MAXMSG = 60, FADE = 64;
    public static final int[] PREAMBLE = {2, 13, 2, 13, 9, 6, 9, 6};

    /** The symbols of a frame. */
    public static int[] symbols(int type, byte[] msg) {
        byte[] hdr = Codec.header(type, msg.length, 0);
        byte[] body = Codec.encode(msg);
        Channel.scramble(hdr, Channel.get(Channel.SD)); Channel.scramble(body, Channel.get(Channel.SD));
        int[] s = new int[PREAMBLE.length + 2 * (hdr.length + body.length)];
        int n = 0;
        for (int p : PREAMBLE) s[n++] = p;
        for (byte b : hdr) { s[n++] = (b >> 4) & 15; s[n++] = b & 15; }
        for (byte b : body) { s[n++] = (b >> 4) & 15; s[n++] = b & 15; }
        return s;
    }

    /** The sound of a frame at the modem rate (51,200/s). level = the peak, of full scale. */
    public static float[] frame(int type, byte[] msg, float level) {
        if (msg.length > MAXMSG) throw new IllegalArgumentException("message too long for tones");
        int[] s = symbols(type, msg);
        float[] x = new float[s.length * SYM];
        for (int i = 0; i < s.length; i++) {
            double w = 2 * Math.PI * (FIRST + s[i]) * 100.0 / Channel.RATE;
            for (int j = 0; j < SYM; j++) {
                double g = level;
                if (j < FADE) g *= 0.5 - 0.5 * Math.cos(Math.PI * j / FADE);
                else if (SYM - 1 - j < FADE) g *= 0.5 - 0.5 * Math.cos(Math.PI * (SYM - 1 - j) / FADE);
                x[i * SYM + j] = (float) (g * Math.sin(w * j));
            }
        }
        return x;
    }

    /** How long a frame sounds (ms). */
    public static int ms(int msgLen) {
        return (PREAMBLE.length + 2 * (Codec.HEADER + Codec.HEADER_CHECK + Codec.codedLength(msgLen))) * SYM * 1000 / Channel.RATE;
    }
}
