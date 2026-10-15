package net.kyriakos.whisper;

import android.content.Context;
import android.content.res.Configuration;

/** The app's colours, light or dark as the phone is set. */
public final class Theme {
    private Theme() { }

    public static boolean dark(Context c) {
        return (c.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    public final int navy, paper, ink, muted, card, green, line, warn, link, button;

    private Theme(boolean d) {
        navy = d ? 0xFF10151F : 0xFF1B2536;
        paper = d ? 0xFF161B24 : 0xFFF4F2EE;
        ink = d ? 0xFFECE9E3 : 0xFF1D2430;
        muted = d ? 0xFFA3A8B2 : 0xFF6B6F78;
        card = d ? 0xFF202734 : 0xFFFFFFFF;
        green = d ? 0xFF7CC75A : 0xFF3D8A1F;
        line = d ? 0xFF323B4B : 0xFFDCD8D0;
        warn = d ? 0xFFE8915A : 0xFFB4531A;
        link = d ? 0xFF8DB4FF : 0xFF2A5DB0;
        button = d ? 0xFF2C3545 : 0xFFEDEAE4;
    }

    public static Theme of(Context c) { return new Theme(dark(c)); }
}
