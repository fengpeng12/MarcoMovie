package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.view.*;
import android.widget.*;

/** One account entry, anchored to the navigation button. No account status is guessed. */
final class AccountPanel {
    static void show(MainActivity a, View anchor) {
        Dialog dialog = new Dialog(a);
        a.accountDialog = dialog;
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel = a.vertical();
        panel.setTag("account-panel");
        panel.setPadding(a.dp(24), a.dp(22), a.dp(24), a.dp(18));
        panel.setBackground(a.bg(0xf5222227, 28));
        panel.addView(a.text("网盘与账号", 24, MainActivity.WHITE));
        a.gap(panel, 8);
        TextView note = a.text("登录与账号状态由你导入的配置提供。", 13, MainActivity.MUTED);
        panel.addView(note);
        a.gap(panel, 16);
        String[] labels = {"网盘登录与启用", "登录凭据配置", "网盘优先顺序", "网盘搜索顺序"};
        String[] actions = {"LoginShow", "pushCkShow", "panSortShow", "panSourceSortShow"};
        for (int i = 0; i < labels.length; i++) {
            String action = actions[i];
            Button item =
                    a.button(
                            labels[i],
                            "account-action:" + action,
                            () -> {
                                dialog.dismiss();
                                new SettingsScreen(a).accountAction(action);
                            });
            item.setOnFocusChangeListener(
                    (v, f) -> {
                        FocusMotion.style(
                                a,
                                item,
                                f,
                                0x18ffffff,
                                MainActivity.WHITE,
                                20,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.015f);
                    });
            item.setBackground(a.bg(0x18ffffff, 20));
            item.setMinHeight(a.dp(46));
            item.setTextSize(15);
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(48));
            size.bottomMargin = a.dp(6);
            panel.addView(item, size);
        }
        a.gap(panel, 6);
        Button close = a.navButton("完成", "account-close", dialog::dismiss);
        panel.addView(close, new LinearLayout.LayoutParams(-1, a.dp(42)));
        dialog.setContentView(panel);
        dialog.setOnDismissListener(
                d -> {
                    a.accountDialog = null;
                    if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
                });
        dialog.show();
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            int panelW = Math.min(a.dp(410), a.windowWidth() - a.dp(a.isTvDevice() ? 48 : 32));
            window.setLayout(panelW, -2);
            WindowManager.LayoutParams lp = window.getAttributes();
            if (a.isTvDevice()) {
                window.setGravity(Gravity.TOP | Gravity.RIGHT);
                int[] point = {0, 0};
                if (anchor != null) anchor.getLocationInWindow(point);
                lp.x = a.dp(38);
                lp.y = anchor == null ? a.dp(80) : point[1] + anchor.getHeight() + a.dp(8);
            } else {
                window.setGravity(Gravity.CENTER);
                lp.x = 0;
                lp.y = 0;
            }
            lp.dimAmount = .5f;
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setAttributes(lp);
        }
        panel.post(
                () -> {
                    boolean side =
                            a.homeDock != null && anchor != null && a.homeDock.contains(anchor);
                    int pivotY = 0;
                    if (side && window != null) {
                        int[] point = {0, 0};
                        anchor.getLocationInWindow(point);
                        int height = a.windowHeight();
                        WindowManager.LayoutParams position = window.getAttributes();
                        position.x = a.windowWidth() - point[0] + a.dp(12);
                        position.y =
                                Math.max(
                                        a.dp(24),
                                        Math.min(
                                                height - panel.getHeight() - a.dp(24),
                                                point[1]
                                                        + anchor.getHeight() / 2
                                                        - panel.getHeight() / 2));
                        window.setAttributes(position);
                        pivotY = point[1] + anchor.getHeight() / 2 - position.y;
                    }
                    panel.setPivotX(side ? panel.getWidth() : panel.getWidth() - a.dp(70));
                    panel.setPivotY(pivotY);
                    if (!a.reduced) {
                        panel.setScaleX(.88f);
                        panel.setScaleY(.7f);
                        panel.setAlpha(0);
                        panel.animate()
                                .scaleX(1)
                                .scaleY(1)
                                .alpha(1)
                                .setDuration(200)
                                .setInterpolator(
                                        new android.view.animation.DecelerateInterpolator())
                                .start();
                    }
                    View first = panel.findViewWithTag("account-action:LoginShow");
                    if (first != null) first.requestFocus();
                });
    }
}
