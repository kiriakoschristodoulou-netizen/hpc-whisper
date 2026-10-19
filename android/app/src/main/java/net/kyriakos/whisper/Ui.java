package net.kyriakos.whisper;

import android.app.Activity;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** The app's few building blocks: pages, cards, text, buttons, steps, in light or dark. */
final class Ui {
    final Activity a;
    final Theme t;
    LinearLayout root;

    Ui(Activity a) { this.a = a; this.t = Theme.of(a); }

    int dp(float v) { return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, a.getResources().getDisplayMetrics()); }

    /** A scrolling page under a bar with a title (and a back arrow when back is not null); returns its column. */
    LinearLayout page(String title, Runnable back) {
        LinearLayout outer = new LinearLayout(a);
        outer.setOrientation(LinearLayout.VERTICAL);
        outer.setBackgroundColor(t.paper);
        if (title != null) {
            LinearLayout bar = new LinearLayout(a);
            bar.setOrientation(LinearLayout.HORIZONTAL);
            bar.setGravity(Gravity.CENTER_VERTICAL);
            bar.setBackgroundColor(t.navy);
            bar.setPadding(dp(4), 0, dp(16), 0);
            if (back != null) {
                TextView arrow = new TextView(a);
                arrow.setText("←");
                arrow.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
                arrow.setTextColor(0xFFFFFFFF);
                arrow.setGravity(Gravity.CENTER);
                arrow.setContentDescription("Back");
                arrow.setOnClickListener(v -> back.run());
                bar.addView(arrow, new LinearLayout.LayoutParams(dp(52), dp(56)));
            } else bar.setPadding(dp(16), 0, dp(16), 0);
            TextView h = new TextView(a);
            h.setText(title);
            h.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
            h.setTypeface(Typeface.DEFAULT_BOLD);
            h.setTextColor(0xFFFFFFFF);
            bar.addView(h, new LinearLayout.LayoutParams(0, dp(56), 1));
            h.setGravity(Gravity.CENTER_VERTICAL);
            outer.addView(bar);
        }
        ScrollView scroll = new ScrollView(a);
        scroll.setBackgroundColor(t.paper);
        root = new LinearLayout(a);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(8), dp(16), dp(28));
        scroll.addView(root);
        outer.addView(scroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        a.setContentView(outer);
        a.getWindow().setStatusBarColor(t.navy);
        a.getWindow().setNavigationBarColor(t.navy);
        return root;
    }

    LinearLayout page() { return page(null, null); }

    TextView text(LinearLayout into, String s, float sp, int color, boolean bold) {
        TextView v = new TextView(a);
        v.setText(s);
        v.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        v.setTextColor(color);
        if (bold) v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setLineSpacing(0, 1.15f);
        into.addView(v);
        return v;
    }

    TextView body(LinearLayout into, String s) { return text(into, s, 14, t.muted, false); }

    LinearLayout card(String title) {
        LinearLayout c = new LinearLayout(a);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(16), dp(14), dp(16), dp(16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(t.card); bg.setCornerRadius(dp(12)); bg.setStroke(dp(1), t.line);
        c.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(14);
        root.addView(c, lp);
        if (title != null) { TextView h = text(c, title, 17, t.ink, true); h.setPadding(0, 0, 0, dp(6)); }
        return c;
    }

    Button button(LinearLayout into, String label, boolean primary, View.OnClickListener l) {
        Button b = new Button(a);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setTextColor(primary ? 0xFFFFFFFF : t.ink);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(primary ? (Theme.dark(a) ? 0xFF3A5A8C : t.navy) : t.button);
        bg.setCornerRadius(dp(10));
        b.setBackground(bg);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48));
        lp.topMargin = dp(8);
        into.addView(b, lp);
        return b;
    }

    /** A numbered step with a state line under it; returns the state line. */
    TextView step(LinearLayout c, String n, String what) {
        LinearLayout row = new LinearLayout(a);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(10), 0, 0);
        TextView num = new TextView(a);
        num.setText(n);
        num.setTextColor(0xFFFFFFFF);
        num.setTypeface(Typeface.DEFAULT_BOLD);
        num.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL); bg.setColor(Theme.dark(a) ? 0xFF3A5A8C : t.navy);
        num.setBackground(bg);
        row.addView(num, new LinearLayout.LayoutParams(dp(26), dp(26)));
        LinearLayout col = new LinearLayout(a);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(12), 0, 0, 0);
        text(col, what, 15, t.ink, true);
        TextView state = text(col, "", 13.5f, t.muted, false);
        row.addView(col, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        c.addView(row);
        return state;
    }
    /** A box that opens when tapped: the header (title, a short note, an arrow) is always there; returns the hidden content. */
    LinearLayout fold(LinearLayout card, String title, String note) {
        LinearLayout head = new LinearLayout(a);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        TextView h = text(head, title, 17, t.ink, true);
        h.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        TextView n = text(head, note == null ? "" : note, 13, t.muted, false);
        n.setPadding(0, 0, dp(10), 0);
        TextView arrow = text(head, "▾", 18, t.muted, false);
        card.addView(head);
        LinearLayout body = new LinearLayout(a);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setVisibility(View.GONE);
        card.addView(body);
        View.OnClickListener l = v -> {
            boolean open = body.getVisibility() != View.VISIBLE;
            body.setVisibility(open ? View.VISIBLE : View.GONE);
            arrow.setText(open ? "▴" : "▾");
        };
        head.setOnClickListener(l);
        head.setMinimumHeight(dp(36));
        return body;
    }

    /** The note on a fold's header, so a screen can change it ("3 sessions"). */
    TextView noteOf(LinearLayout body) {
        LinearLayout head = (LinearLayout) ((LinearLayout) body.getParent()).getChildAt(((LinearLayout) body.getParent()).indexOfChild(body) - 1);
        return (TextView) head.getChildAt(1);
    }

    /** A round icon with a small label under it, green when on. */
    TextView statusIcon(LinearLayout row, String glyph, String label) {
        LinearLayout col = new LinearLayout(a);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView g = new TextView(a);
        g.setText(glyph);
        g.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        g.setGravity(Gravity.CENTER);
        col.addView(g, new LinearLayout.LayoutParams(dp(48), dp(48)));
        TextView l = text(col, label, 11.5f, t.muted, false);
        l.setGravity(Gravity.CENTER);
        row.addView(col, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        return g;
    }

    /** Colours a status icon: green with a light glyph when on, grey when off. */
    void lamp(TextView g, boolean on) {
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(on ? t.green : t.button);
        g.setBackground(bg);
        g.setTextColor(on ? 0xFFFFFFFF : t.muted);
        g.setAlpha(on ? 1f : 0.7f);
    }

    /** An on/off line: title, a small note, and a switch. */
    android.widget.Switch toggle(LinearLayout into, String title, String note, boolean on, java.util.function.Consumer<Boolean> change) {
        LinearLayout row = new LinearLayout(a);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(10), 0, 0);
        LinearLayout col = new LinearLayout(a);
        col.setOrientation(LinearLayout.VERTICAL);
        text(col, title, 15, t.ink, true);
        if (note != null) text(col, note, 13, t.muted, false);
        row.addView(col, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        android.widget.Switch sw = new android.widget.Switch(a);
        sw.setChecked(on);
        sw.setOnCheckedChangeListener((b, v) -> change.accept(v));
        row.addView(sw);
        into.addView(row);
        return sw;
    }

    /** A line with a value that changes to the next choice when tapped. */
    TextView choice(LinearLayout into, String title, String note, String[] options, int sel, java.util.function.IntConsumer change) {
        LinearLayout row = new LinearLayout(a);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(10), 0, 0);
        LinearLayout col = new LinearLayout(a);
        col.setOrientation(LinearLayout.VERTICAL);
        text(col, title, 15, t.ink, true);
        if (note != null) text(col, note, 13, t.muted, false);
        row.addView(col, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        TextView val = new TextView(a);
        val.setText(options[sel]);
        val.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        val.setTextColor(t.ink);
        val.setGravity(Gravity.CENTER);
        val.setPadding(dp(14), 0, dp(14), 0);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(t.button); bg.setCornerRadius(dp(10));
        val.setBackground(bg);
        final int[] cur = {sel};
        val.setOnClickListener(v -> { cur[0] = (cur[0] + 1) % options.length; val.setText(options[cur[0]]); change.accept(cur[0]); });
        row.addView(val, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)));
        into.addView(row);
        return val;
    }
}
