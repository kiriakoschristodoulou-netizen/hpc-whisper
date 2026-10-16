package net.kyriakos.whisper;

import android.content.Intent;
import android.net.Uri;
import android.widget.LinearLayout;
import android.widget.TextView;

/** About: what Whisper Tools is, the handheld, the iPhone page, privacy. */
public class AboutActivity extends ToolActivity {
    private static final String PAGE = "https://kiriakoschristodoulou-netizen.github.io/hpc-whisper/";

    @Override protected String title() { return "About"; }

    @Override
    protected void build() {
        LinearLayout a = ui.card("Whisper Tools");
        ui.text(a, "Tools that join a Windows CE handheld PC, such as the HP Jornada 720, to this phone: a keyboard, files "
                + "both ways, and a picture remote. They travel as sound: silent tones above 20 kHz for typing, a soft hiss "
                + "for files and the remote. No cable, no network. Created by Kyriakos Christodoulou.", 14, t().ink, false);

        LinearLayout h = ui.card("On the handheld");
        ui.text(h, "Run WhisperTools.exe from the Whisper-Tools download. It needs an ARM processor and Windows CE 3.0 or "
                + "later. Keep both programs at the same version.", 14, t().ink, false);

        LinearLayout i = ui.card("iPhone");
        ui.text(i, "Apple does not let keyboards use the microphone, so an iPhone keyboard is impossible. On an iPhone (or "
                + "any other phone) use the receiver page in the browser, with Copy and Share. It reads the Classic format "
                + "(on the handheld: Settings, Typing format, Classic).", 14, t().ink, false);
        TextView pg = ui.text(i, PAGE, 14, t().link, false);
        pg.setPadding(0, ui.dp(6), 0, 0);
        pg.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(PAGE))));

        LinearLayout p = ui.card("Privacy");
        ui.text(p, "This app has no internet access. The microphone is used only while the keyboard is open, while "
                + "connected (a notification shows it), or while you record on the Link screen. The screen is shared only "
                + "while the remote runs. If another app is using the microphone (a call), the handheld cannot be heard "
                + "until it is free.", 14, t().ink, false);
    }
}
