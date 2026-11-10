package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Custom anchored controls; no platform alert/list chrome. */
final class PlayerBubble {
    interface IntAction {
        void accept(int index);
    }

    static Dialog show(
            MainActivity a,
            View anchor,
            String title,
            String[] labels,
            int selected,
            IntAction action,
            Runnable closed) {
        return show(a, anchor, title, labels, selected, action, closed, "");
    }

    static Dialog show(
            MainActivity a,
            View anchor,
            String title,
            String[] labels,
            int selected,
            IntAction action,
            Runnable closed,
            String message) {
        Dialog dialog = new Dialog(a);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout shell = a.vertical();
        shell.setTag("player-bubble");
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(16), a.dp(16), a.dp(16), a.dp(12));
        android.graphics.drawable.GradientDrawable glass = a.bg(0xfa29292e, 26);
        glass.setStroke(a.dp(1), 0x38ffffff);
        panel.setBackground(glass);
        panel.setClipChildren(false);
        panel.setClipToPadding(false);
        TextView heading = a.text(title, 18, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        heading.setPadding(a.dp(10), 0, a.dp(10), a.dp(10));
        panel.addView(heading);
        ScrollView scroll = new TvScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        LinearLayout items = a.vertical();
        items.setClipChildren(false);
        items.setClipToPadding(false);
        items.setPadding(a.dp(6), a.dp(4), a.dp(6), a.dp(4));
        scroll.addView(items);
        int[] origin = new int[2];
        anchor.getLocationInWindow(origin);
        int maxHeight = Math.min(a.dp(246), Math.max(a.dp(100), origin[1] - a.dp(140)));
        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas canvas) {
                        int save = canvas.save();
                        canvas.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(canvas);
                        canvas.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        panel.addView(
                viewport,
                new LinearLayout.LayoutParams(
                        -1,
                        Math.min(
                                (labels.length + (message.isEmpty() ? 0 : 6)) * a.dp(44),
                                maxHeight)));
        if (!message.isEmpty()) {
            TextView description = a.text(message, 13, 0xffdddddf);
            description.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(14));
            description.setLineSpacing(a.dp(4), 1);
            description.setFocusable(true);
            items.addView(description);
        }
        final String defaultHint = "上下选择 · 返回关闭";
        TextView hint = a.text(defaultHint, 11, MainActivity.MUTED);
        hint.setSingleLine(false);
        hint.setMaxLines(2);
        hint.setEllipsize(android.text.TextUtils.TruncateAt.END);
        for (int i = 0; i < labels.length; i++) {
            final int index = i;
            Button item =
                    a.button(
                            (i == selected ? "✓  " : "") + labels[i],
                            "player-option:" + i,
                            () -> {
                                dialog.dismiss();
                                action.accept(index);
                            });
            item.setTextSize(14);
            item.setSingleLine();
            item.setEllipsize(android.text.TextUtils.TruncateAt.END);
            item.setMinHeight(0);
            item.setMinimumHeight(0);
            item.setPadding(a.dp(12), 0, a.dp(12), 0);
            item.setGravity(Gravity.CENTER);
            item.setBackground(a.bg(i == selected ? 0x30ffffff : 0x00ffffff, 16));
            item.setOnFocusChangeListener(
                    (v, f) -> {
                        item.setSelected(f);
                        item.setEllipsize(
                                f
                                        ? android.text.TextUtils.TruncateAt.MARQUEE
                                        : android.text.TextUtils.TruncateAt.END);
                        if (f && labels[index] != null && labels[index].length() > 14) {
                            hint.setText(labels[index]);
                            hint.setTextColor(0xffdddddf);
                        } else if (f) {
                            hint.setText(defaultHint);
                            hint.setTextColor(MainActivity.MUTED);
                        }
                        FocusMotion.style(
                                a,
                                item,
                                f,
                                index == selected ? 0x30ffffff : 0x00ffffff,
                                MainActivity.WHITE,
                                16,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.015f);
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, a.dp(40));
            lp.setMargins(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
            items.addView(item, lp);
        }
        hint.setGravity(Gravity.CENTER);
        hint.setPadding(a.dp(8), a.dp(10), a.dp(8), 0);
        panel.addView(hint);
        shell.addView(panel);
        int width = Math.min(a.dp(310), a.root.getWidth() - a.dp(32));
        int x =
                Math.max(
                        a.dp(16),
                        Math.min(
                                a.root.getWidth() - width - a.dp(16),
                                origin[0] + anchor.getWidth() / 2 - width / 2));
        float tip = origin[0] + anchor.getWidth() / 2f - x;
        View arrow =
                new View(a) {
                    final Paint p = new Paint(3);

                    protected void onDraw(Canvas c) {
                        p.setColor(0xfa29292e);
                        Path path = new Path();
                        path.moveTo(tip - a.dp(10), 0);
                        path.lineTo(tip + a.dp(10), 0);
                        path.lineTo(tip, a.dp(9));
                        path.close();
                        c.drawPath(path, p);
                    }
                };
        shell.addView(arrow, new LinearLayout.LayoutParams(-1, a.dp(9)));
        dialog.setContentView(shell);
        dialog.setOnDismissListener(
                d -> {
                    closed.run();
                    if (UiCompat.isAttached(anchor)) anchor.requestFocus();
                });
        dialog.show();
        Window window = dialog.getWindow();
        window.setBackgroundDrawableResource(android.R.color.transparent);
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        window.setLayout(width, -2);
        window.setGravity(Gravity.TOP | Gravity.LEFT);
        window.getDecorView().setSystemUiVisibility(5894);
        shell.measure(
                View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(a.root.getHeight(), View.MeasureSpec.AT_MOST));
        WindowManager.LayoutParams attrs = window.getAttributes();
        attrs.x = x;
        attrs.y = Math.max(a.dp(16), origin[1] - shell.getMeasuredHeight() - a.dp(8));
        window.setAttributes(attrs);
        shell.post(
                () -> {
                    shell.setPivotX(tip);
                    shell.setPivotY(shell.getHeight());
                    if (!a.reduced) {
                        shell.setScaleX(.85f);
                        shell.setScaleY(.75f);
                        shell.setAlpha(0);
                        shell.animate()
                                .scaleX(1)
                                .scaleY(1)
                                .alpha(1)
                                .setDuration(180)
                                .setInterpolator(
                                        new android.view.animation.DecelerateInterpolator())
                                .start();
                    }
                    View first =
                            items.getChildAt(
                                    Math.max(0, Math.min(selected, items.getChildCount() - 1)));
                    if (first != null) first.requestFocus();
                });
        return dialog;
    }
}
