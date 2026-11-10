package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Base64;
import android.widget.EditText;
import android.widget.LinearLayout;
import java.security.SecureRandom;

/** Separate private configuration namespace; unlock state exists only in this process. */
final class PrivacySpace {
    static boolean active;
    private static long lastTap;
    private static int taps;
    private static boolean dialogOpen;
    private static AppDialog pendingDialog;

    static void cancelPrompt(MainActivity owner) {
        if (pendingDialog != null && pendingDialog.a == owner) pendingDialog.dismiss();
        taps = 0;
    }

    static void logoTap(MainActivity a) {
        long now = SystemClock.elapsedRealtime();
        if (now < lastTap || now - lastTap > 2500) {
            taps = 0;
        }
        lastTap = now;
        if (++taps < 5) return;
        taps = 0;
        if (a.privateMode) {
            switchSpace(a, false);
            return;
        }
        if (dialogOpen) return;
        prompt(a);
    }

    private static void prompt(MainActivity a) {
        SharedPreferences lock = a.getSharedPreferences("private-lock", Context.MODE_PRIVATE);
        if (System.currentTimeMillis() < lock.getLong("retry_at", 0)) {
            a.toast("尝试次数较多，请稍后再输入密码");
            return;
        }
        boolean setup = !lock.contains("hash");
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        panel.addView(
                a.text(
                        setup ? "设置 4 位数字密码。私密订阅单独保存，不进入公开备份。" : "输入密码进入隐私空间",
                        15,
                        MainActivity.MUTED));
        EditText pin = input(a, "4 位数字密码");
        panel.addView(pin);
        EditText confirm = input(a, "再次输入密码");
        if (setup) panel.addView(confirm);
        dialogOpen = true;
        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(setup ? "设置隐私密码" : "隐私空间")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(setup ? "设置并进入" : "进入", null)
                        .create();
        pendingDialog = dialog;
        dialog.setOnDismissListener(
                d -> {
                    dialogOpen = false;
                    if (pendingDialog == dialog) pendingDialog = null;
                });
        dialog.show();
        final android.widget.Button submit = dialog.getButton(-1);
        submit.setOnClickListener(
                button -> {
                    if (!submit.isEnabled()) return;
                    if (System.currentTimeMillis() < lock.getLong("retry_at", 0)) {
                        a.toast("尝试次数较多，请稍后再输入密码");
                        return;
                    }
                    String value = pin.getText().toString();
                    if (!value.matches("[0-9]{4}")
                            || (setup && !value.equals(confirm.getText().toString()))) {
                        a.toast(setup ? "请输入两次相同的 4 位数字密码" : "请输入 4 位数字密码");
                        return;
                    }
                    submit.setEnabled(false);
                    a.worker.execute(
                            () -> {
                                try {
                                    final byte[] salt;
                                    final byte[] hash;
                                    final boolean accepted;
                                    if (setup) {
                                        salt = new byte[16];
                                        new SecureRandom().nextBytes(salt);
                                        hash = PrivacyPin.derive(value, salt);
                                        accepted = true;
                                    } else {
                                        salt =
                                                Base64.decode(
                                                        lock.getString("salt", ""), Base64.DEFAULT);
                                        hash =
                                                Base64.decode(
                                                        lock.getString("hash", ""), Base64.DEFAULT);
                                        accepted = PrivacyPin.matches(value, salt, hash);
                                    }
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || a.isDestroyed()
                                                        || !dialog.isShowing()) return;
                                                submit.setEnabled(true);
                                                if (!a.foreground) {
                                                    dialog.dismiss();
                                                    return;
                                                }
                                                if (!accepted) {
                                                    int failures = lock.getInt("failures", 0) + 1;
                                                    lock.edit()
                                                            .putInt("failures", failures)
                                                            .putLong(
                                                                    "retry_at",
                                                                    failures >= 5
                                                                            ? System
                                                                                            .currentTimeMillis()
                                                                                    + 30000
                                                                            : 0)
                                                            .commit();
                                                    pin.setText("");
                                                    a.toast("密码错误，请重新输入");
                                                } else {
                                                    SharedPreferences.Editor save =
                                                            lock.edit()
                                                                    .remove("failures")
                                                                    .remove("retry_at");
                                                    if (setup)
                                                        save.putString(
                                                                        "salt",
                                                                        Base64.encodeToString(
                                                                                salt,
                                                                                Base64.NO_WRAP))
                                                                .putString(
                                                                        "hash",
                                                                        Base64.encodeToString(
                                                                                hash,
                                                                                Base64.NO_WRAP));
                                                    if (!save.commit()) {
                                                        a.toast("无法保存隐私密码，请重试");
                                                        return;
                                                    }
                                                    dialog.dismiss();
                                                    switchSpace(a, true);
                                                }
                                            });
                                } catch (Exception error) {
                                    a.ui.post(
                                            () -> {
                                                if (dialog.isShowing()) {
                                                    submit.setEnabled(true);
                                                    a.toast("隐私密码验证失败，请重试");
                                                }
                                            });
                                }
                            });
                });
    }

    private static EditText input(MainActivity a, String hint) {
        EditText input = new EditText(a);
        input.setHint(hint);
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(MainActivity.MUTED);
        input.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        input.setFilters(
                new android.text.InputFilter[] {new android.text.InputFilter.LengthFilter(4)});
        input.setSingleLine(true);
        return input;
    }

    static void switchSpace(MainActivity a, boolean privateMode) {
        a.savePlaybackHistory(true);
        a.cancelPageRequests();
        a.closeEngines();
        active = privateMode;
        a.switchingPrivacy = true;
        MobileShell.activeTab = 0;
        MobileShell.clearSearchSession();
        a.recreate();
    }
}
