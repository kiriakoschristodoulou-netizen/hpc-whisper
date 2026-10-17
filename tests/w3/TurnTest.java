import net.kyriakos.whisper.TextLink;
import net.kyriakos.whisper.w3.BitMap;
import net.kyriakos.whisper.w3.Channel;
import net.kyriakos.whisper.w3.Tx;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Turn-taking between the half-duplex handheld and the phone, in time (1 ms steps):
 * someone types on the handheld; the handheld sends text frames, each as its own turn
 * (lead-in, frame, tail, then the microphone opens again) and then listens; the phone
 * reads each frame when it ends, and answers (TextLink, the real code) through its
 * speaker after its sound delay. An answer is heard only if it sounds entirely while
 * the handheld's microphone is open and nothing else is sounding.
 *
 * Frame lengths come from the real transmitter (Tx). Device delays are the measured
 * or stated ones: the handheld's 150 ms lead-in and tail and about 60 ms to open its
 * microphone again; the phone reads a frame about 40 ms after it ends; its sound
 * comes out about 250-300 ms late (a full buffer of silence); 3.3 also waited 450 ms
 * of quiet first, while 3.5 waits less by the delay it measures. The same run with the 3.3 settings shows why no answer ever got through.
 */
public class TurnTest {
    static final int LEAD = 150, TAIL = 150, READ = 40;
    static int REOPEN = 60, EXTRA = 0;      // worse devices: a slower microphone, a slower phone (TurnTest REOPEN EXTRA)

    static int frameMs(int ch, int payload) {
        Channel c = Channel.get(ch);
        return Tx.frame(c, BitMap.standard(c), 1, new byte[payload], 0.5f).length * 1000 / Channel.RATE;
    }

    /** One run; returns {answers sent, answers heard, phone talking over the handheld}. */
    static int[] run(boolean old, long seed) {
        Random rnd = new Random(seed);
        int listen = old ? 0 : 1500;                 // the handheld's listening window after a text frame
        // phone: from the answer to its sound (3.3 also waited 450 ms of quiet, not 200: the 250 more are added here)
        // 3.5 keeps the buffer full again (about 250 ms) and shortens its wait by the delay it measures
        int phoneDelay = (old ? 300 + 250 : 250) + EXTRA;
        int ackMs = LEAD + frameMs(Channel.SD, 5);  // the phone's answer, with its lead-in
        TextLink tl = new TextLink();
        if (!old) tl.quietMs = Math.max(30, 260 - phoneDelay);    // as Link does, from the measured delay
        // typing: bursts of keys, 5 a second, with pauses
        List<Integer> keys = new ArrayList<>();
        int t = 500;
        while (t < 21000) { int burst = 3 + rnd.nextInt(15); for (int i = 0; i < burst; i++) { keys.add(t); t += 120 + rnd.nextInt(160); } t += 500 + rnd.nextInt(2500); }
        int typed = 0, sentL = 0, acked = 0;
        long hhTalkFrom = -1, hhTalkTo = -1;        // the handheld's current turn (speaker on, microphone closed)
        long micOpenAt = 0;
        long lastTurnEnd = -100000;
        long phoneFrom = -1, phoneTo = -1;          // the phone's answer sounding
        int[] answerKnown = new int[1];
        long resendAt = 0, lastEdit = 0;
        boolean waitAnswer = false;
        int sent = 0, heard = 0, over = 0;
        long ackDueCheck = -1;
        int seq = 0;
        long phoneHeardSD = -100000;
        long frameEnds = -1; int frameL = 0, frameO = 0;
        for (long now = 0; now < 30000; now++) {
            while (typed < keys.size() && keys.get(typed) <= now) { typed++; lastEdit = now; }
            // the handheld's turn ends: tail played, speaker closed, microphone opened
            if (hhTalkTo >= 0 && now == hhTalkTo) { lastTurnEnd = now; micOpenAt = now + REOPEN; hhTalkFrom = hhTalkTo = -1; }
            // the phone reads the handheld's frame
            if (frameEnds >= 0 && now == frameEnds + READ) {
                byte[] p = new byte[6 + (frameL - frameO)];
                p[0] = 1; p[1] = (byte) seq; p[2] = (byte) (frameL >> 8); p[3] = (byte) frameL; p[4] = (byte) (frameO >> 8); p[5] = (byte) frameO;
                boolean clash = phoneFrom >= 0 && phoneTo > frameEnds - 300 && phoneFrom < frameEnds;   // the phone talked over it
                if (!clash) { tl.onText(p, now); ackDueCheck = now + Math.max(10, tl.nextCheck(now)); }
                frameEnds = -1;
            }
            // the phone's answer timer (Link.ackCheck); it waits while a frame of the handheld is coming in
            if (ackDueCheck >= 0 && now >= ackDueCheck) {
                boolean incoming = !old && frameEnds >= 0 && now >= hhTalkFrom + LEAD && now < frameEnds;   // Rx.busy()
                if (incoming) ackDueCheck = now + 40;
                else {
                    byte[] a = tl.ackIfDue(now);
                    if (a != null) {
                        answerKnown[0] = ((a[1] & 255) << 8) | (a[2] & 255);
                        phoneFrom = now + phoneDelay; phoneTo = phoneFrom + ackMs; sent++;
                    }
                    long nx = tl.nextCheck(now);
                    ackDueCheck = nx >= 0 ? now + nx : -1;
                }
            }
            // the phone's answer ends: did the handheld hear all of it?
            if (phoneTo >= 0 && now == phoneTo) {
                boolean clean = hhTalkFrom < 0 && micOpenAt <= phoneFrom;
                if (clean) { heard++; acked = Math.max(acked, answerKnown[0]); phoneHeardSD = now; resendAt = 0; }
                else over++;
                phoneFrom = phoneTo = -1;
            }
            // the handheld's next turn (Pump): only when it is not talking
            if (hhTalkFrom < 0 && now >= micOpenAt) {
                if (waitAnswer && (now - lastTurnEnd >= listen || phoneHeardSD > lastTurnEnd)) waitAnswer = false;
                if (waitAnswer) continue;
                boolean newText = typed > sentL;
                boolean resend = !newText && acked < typed && resendAt != 0 && now >= resendAt;
                if (newText || resend) {
                    frameO = newText ? Math.max(acked, sentL - 8) : acked;
                    frameL = typed; sentL = typed; seq++;
                    int ms = LEAD + frameMs(Channel.SU_NARROW, frameL - frameO) + TAIL;
                    hhTalkFrom = now; hhTalkTo = now + ms;
                    frameEnds = now + LEAD + frameMs(Channel.SU_NARROW, frameL - frameO);
                    resendAt = frameEnds + 900;
                    waitAnswer = !old;
                    // a phone answer sounding now is drowned (and the handheld's microphone is closed)
                }
            }
        }
        return new int[]{sent, heard, over, acked, keys.size()};
    }

    public static void main(String[] a) {
        if (a.length >= 2) { REOPEN = Integer.parseInt(a[0]); EXTRA = Integer.parseInt(a[1]); }
        int fails = 0;
        for (String which : new String[]{"3.3 settings", "now"}) {
            boolean old = which.startsWith("3.3");
            int s = 0, h = 0, o = 0, conf = 0, all = 0;
            for (long seed = 1; seed <= 20; seed++) { int[] r = run(old, seed); s += r[0]; h += r[1]; o += r[2]; if (r[3] >= r[4]) conf++; all++; }
            System.out.printf("%-13s answers sent %4d, heard by the handheld %4d (%.0f %%); all text confirmed in %d of %d runs%n",
                    which, s, h, 100.0 * h / Math.max(1, s), conf, all);
            if (!old && (h < 0.95 * s || conf < all)) fails++;
        }
        System.out.println(fails == 0 ? "ALL PASS" : "FAILED");
        if (fails > 0) System.exit(1);
    }
}
