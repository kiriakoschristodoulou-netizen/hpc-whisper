package net.kyriakos.whisper;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The self test (docs/FORMAT3.md, section 8), on the phone's side: what this phone heard of the handheld's
 * scripted frames, what the handheld says it heard of the phone's, and what that means. Plain Java (tested on a
 * computer; the same numbers and fill as handheld/wtest.pas).
 *
 * <pre>
 * handheld -> phone: 5 frames of version 2 tones, 3 on the silent channel, 2 on the fast channel, the end mark (tones)
 * phone -> handheld: 3 frames of tones down and 3 on the fast channel (each at another loudness), 3 on the silent
 *                    channel, the end mark (tones down); then the handheld's results, in a frame of tones
 * </pre>
 */
public final class SelfTest {
    public static final int TYPE = 0x35, DOC_TONES = 0xFD, DOC_REPORT = 0xFE;
    public static final int ST_SU = 1, ST_FU = 2, ST_END_H = 3, ST_SD = 10, ST_FD = 11, ST_TD = 12, ST_END_P = 20;
    public static final int NTONE = 5, NSU = 3, NFU = 2, NSD = 3, NFD = 3, NTD = 3, LEN = 24, TD_LEN = 8, REPORT_LEN = 20;
    /** The loudnesses the phone's frames of tones down and fast down are played at (frame 0, 1, 2). */
    public static final float[] TD_LEVELS = {0.5f, 0.2f, 0.08f}, FD_LEVELS = {0.35f, 0.15f, 0.06f};
    public static final int[] TONE_HZ = {20000, 20000, 18000, 20000, 20000};
    public static final int[] TONE_MS = {32, 20, 32, 48, 32};

    // from the handheld
    public int run = -1;
    public int toneMask, suMask, fuMask;
    public boolean endH;
    private float suSnr, fuSnr;
    private int suN, fuN;
    // the handheld's results about the phone's part
    public boolean reported, endPHeard;
    public int sdMask, fdMask, tdMask, framesHeard, lowDb, highDb;
    public int micRate, spkRate, peakPct, tdStarts, tdHdrs, sdHdrs, fdHdrs, fdStarts;
    public int reportVersion;

    public void begin() {
        run = -1; toneMask = suMask = fuMask = 0; endH = false; suSnr = fuSnr = 0; suN = fuN = 0;
        reported = false; endPHeard = false; sdMask = fdMask = tdMask = framesHeard = 0; lowDb = highDb = 0;
        micRate = spkRate = peakPct = tdStarts = tdHdrs = sdHdrs = fdHdrs = fdStarts = 0; reportVersion = 0;
    }

    /** A test frame's payload: run, stage, number, and a fill both sides can recompute. */
    public static byte[] payload(int run, int stage, int idx) { return payload(run, stage, idx, LEN); }

    public static byte[] payload(int run, int stage, int idx, int len) {
        byte[] p = new byte[len];
        p[0] = (byte) run; p[1] = (byte) stage; p[2] = (byte) idx;
        for (int i = 3; i < len; i++) p[i] = (byte) (stage * 31 + idx * 7 + i * 13 + (run & 255) * 5);
        return p;
    }

    public static boolean payloadOk(byte[] p) {
        if (p == null || (p.length != LEN && p.length != TD_LEN)) return false;
        int run = p[0] & 255, stage = p[1] & 255, idx = p[2] & 255;
        for (int i = 3; i < p.length; i++) if (p[i] != (byte) (stage * 31 + idx * 7 + i * 13 + run * 5)) return false;
        return true;
    }

    /** Of the frames that were read (bit = number, loudest first), the one to play at: the middle one, the quieter of two. */
    public static int middle(int mask) {
        int n = Integer.bitCount(mask);
        if (n == 0) return -1;
        int skip = n / 2, i = 0;
        for (; i < 16; i++) if ((mask >> i & 1) != 0) { if (skip == 0) return i; skip--; }
        return -1;
    }

    /** A frame of version 2 tones. True when it was a self-test frame (then it must not reach the keyboard). */
    public boolean onTone(Receiver.Frame f) {
        if (f.doc == DOC_TONES) {
            byte[] b = f.bytes;
            if (b != null && b.length == 4 && b[0] == 'S' && b[1] == 'T') {
                int i = (b[2] & 255) - 'A';
                if (i >= 0 && i < NTONE) toneMask |= 1 << i;
                else if (i == 'Z' - 'A') endH = true;                // the end mark of the handheld's part
                run = b[3] & 255;
            }
            return true;
        }
        if (f.doc == DOC_REPORT) {
            byte[] b = f.bytes;
            if (b != null && b.length >= 9 && (b[0] == 1 || (b[0] == 2 && b.length >= REPORT_LEN))) {
                reported = true; reportVersion = b[0];
                sdMask = b[2] & 255; fdMask = b[3] & 255; endPHeard = b[4] != 0; framesHeard = b[5] & 255;
                lowDb = (b[6] & 255) - 20; highDb = (b[7] & 255) - 20;
                if (b[0] == 2) {
                    tdMask = b[8] & 255;
                    micRate = (b[9] & 255) << 8 | (b[10] & 255); spkRate = (b[11] & 255) << 8 | (b[12] & 255);
                    peakPct = b[13] & 255; tdStarts = b[14] & 255; tdHdrs = b[15] & 255;
                    sdHdrs = b[16] & 255; fdHdrs = b[17] & 255; fdStarts = b[18] & 255;
                }
            }
            return true;
        }
        return false;
    }

    /** A format 3 test frame from the handheld. Returns its stage, or -1 when it was not a whole test frame. */
    public int onMessage(int type, byte[] p, float snrDb) {
        if (type != TYPE || !payloadOk(p)) return -1;
        int stage = p[1] & 255, idx = p[2] & 255;
        if (run < 0) run = p[0] & 255;
        switch (stage) {
            case ST_SU: if (idx < NSU) { suMask |= 1 << idx; suSnr += snrDb; suN++; } break;
            case ST_FU: if (idx < NFU) { fuMask |= 1 << idx; fuSnr += snrDb; fuN++; } break;
            case ST_END_H: endH = true; break;
            default: break;
        }
        return stage;
    }

    public static int count(int mask) { return Integer.bitCount(mask); }

    public int tonesRead() { return count(toneMask); }
    public boolean tonesOk() { return tonesRead() >= 3; }
    public boolean suOk() { return count(suMask) >= 2; }
    public boolean fuOk() { return count(fuMask) >= 1; }
    public boolean sdOk() { return reported && count(sdMask) >= 2; }
    public boolean fdOk() { return reported && count(fdMask) >= 1; }
    public boolean tdOk() { return reported && count(tdMask) >= 1; }

    /** Nothing at all of the handheld's part was heard. */
    public boolean heardNothing() { return toneMask == 0 && suMask == 0 && fuMask == 0 && !endH; }

    /** The result in words, line by line. */
    public List<String> lines() {
        List<String> s = new ArrayList<>();
        s.add("Handheld to phone, as this phone heard it:");
        for (int i = 0; i < NTONE; i++)
            s.add(String.format(Locale.US, "  tones %.1f kHz, %d ms a symbol: %s", TONE_HZ[i] / 1000.0, TONE_MS[i], (toneMask >> i & 1) != 0 ? "read" : "not read"));
        s.add(String.format(Locale.US, "  silent channel: %d of %d frames%s", count(suMask), NSU, suN > 0 ? String.format(Locale.US, " (%.0f dB)", suSnr / suN) : ""));
        s.add(String.format(Locale.US, "  fast channel: %d of %d frames%s", count(fuMask), NFU, fuN > 0 ? String.format(Locale.US, " (%.0f dB)", fuSnr / fuN) : ""));
        s.add("Phone to handheld, as the handheld heard it:");
        if (reported) {
            if (reportVersion >= 2) s.add(String.format(Locale.US, "  tones: %d of %d frames (%s)", count(tdMask), NTD, levelsRead(tdMask, TD_LEVELS)));
            s.add(String.format(Locale.US, "  silent channel: %d of %d frames", count(sdMask), NSD));
            s.add(String.format(Locale.US, "  fast channel: %d of %d frames (%s)", count(fdMask), NFD, levelsRead(fdMask, FD_LEVELS)));
            s.add("  the test sound's silent band reached it at " + highDb + " dB, its middle band at " + lowDb + " dB");
            if (reportVersion >= 2)
                s.add(String.format(Locale.US, "  the handheld's own hearing: microphone %d samples/s, speaker %d, loudest input %d %% of full scale; tones started %d, headers %d; "
                        + "silent headers %d; fast frames found %d, headers %d", micRate, spkRate, peakPct, tdStarts, tdHdrs, sdHdrs, fdStarts, fdHdrs));
        } else s.add("  not reported yet");
        s.add("So:");
        if (heardNothing()) s.add("  Nothing of the handheld's part was heard. Is Whisper Tools running on it, beside the phone?");
        else {
            if (tonesOk()) s.add("  Typing works with tones, whatever the other formats do.");
            else s.add("  Even the tones did not get through well: the handheld's volume (Tones volume in Settings) or the distance.");
            if (suOk()) s.add("  The silent format reaches this phone: typing can be silent."); else s.add("  The silent format does not reach this phone: typing stays on tones" + (fuOk() ? " (the fast format does reach it)." : "."));
        }
        if (reported) {
            if (sdOk()) s.add("  This phone can answer silently.");
            else if (tdOk()) s.add("  The handheld hears this phone's tones: confirmations and requests go as tones" + (fdOk() ? "; files come down the fast channel." : "; files cannot come down yet."));
            else if (fdOk()) s.add("  The handheld hears this phone only on the fast channel: answers go there (a soft hiss).");
            else s.add("  The handheld heard none of this phone's sound: it will not hear confirmations, files or the remote; typing goes on tones.");
        }
        return s;
    }

    private static String levelsRead(int mask, float[] lv) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < lv.length; i++) b.append(i > 0 ? ", " : "").append(Math.round(lv[i] * 100)).append(" %: ").append((mask >> i & 1) != 0 ? "read" : "not read");
        return b.toString();
    }

    /** One line for the log. */
    public String oneLine() {
        return String.format(Locale.US, "self test: tones up %d/%d, silent up %d/%d, fast up %d/%d, tones down %s, silent down %s, fast down %s",
                count(toneMask), NTONE, count(suMask), NSU, count(fuMask), NFU,
                reported && reportVersion >= 2 ? count(tdMask) + "/" + NTD : "?", reported ? count(sdMask) + "/" + NSD : "?", reported ? count(fdMask) + "/" + NFD : "?");
    }
}
