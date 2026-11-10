package com.pilipala.emby;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.text.InputType;
import android.widget.*;
import java.io.IOException;
import java.util.UUID;
import org.json.*;

/** The subscription holds only the account reference. Tokens stay in app-private preferences. */
public final class EmbyAccounts {
    public interface OnConnected {
        void save(JSONObject site) throws Exception;
    }

    public static EmbyLibrary open(Context context, String api) throws Exception {
        if (!api.startsWith(EmbyLibrary.PREFIX)) throw new IOException("Emby 来源无效");
        String raw = context.getSharedPreferences("emby.accounts", 0).getString(api, "");
        if (raw.length() == 0) throw new IOException("请在本机重新登录 Emby");
        return new EmbyLibrary(new JSONObject(raw));
    }

    public static void connect(final Activity a, final OnConnected callback) {
        final LinearLayout fields = new LinearLayout(a);
        fields.setOrientation(1);
        int pad = (int) (18 * a.getResources().getDisplayMetrics().density);
        fields.setPadding(pad, 0, pad, 0);
        final EditText server =
                field(
                        a,
                        fields,
                        "服务器地址（含端口或子路径）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        final EditText user = field(a, fields, "用户名", InputType.TYPE_CLASS_TEXT);
        final EditText pass =
                field(
                        a,
                        fields,
                        "密码",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        final TextView status = new TextView(a);
        fields.addView(status);
        final AlertDialog dlg =
                new AlertDialog.Builder(a)
                        .setTitle("连接 Emby 媒体库")
                        .setView(fields)
                        .setPositiveButton("登录", null)
                        .setNegativeButton("取消", null)
                        .create();
        dlg.show();
        final Button submit = dlg.getButton(AlertDialog.BUTTON_POSITIVE);
        submit.setOnClickListener(
                new android.view.View.OnClickListener() {
                    public void onClick(android.view.View v) {
                        final String address = server.getText().toString().trim(),
                                name = user.getText().toString().trim(),
                                pw = pass.getText().toString();
                        if (address.length() == 0 || name.length() == 0) {
                            status.setText("请填写服务器地址和用户名");
                            return;
                        }
                        submit.setEnabled(false);
                        status.setText("正在连接…");
                        final SharedPreferences prefs = a.getSharedPreferences("emby.accounts", 0);
                        String existing = prefs.getString("device", "");
                        if (existing.length() == 0) {
                            existing = UUID.randomUUID().toString();
                            prefs.edit().putString("device", existing).commit();
                        }
                        final String device = existing;
                        new Thread(
                                        new Runnable() {
                                            public void run() {
                                                try {
                                                    final JSONObject session =
                                                            EmbyLibrary.login(
                                                                    address, name, pw, device);
                                                    final String key =
                                                            EmbyLibrary.accountKey(session);
                                                    final String api = EmbyLibrary.PREFIX + key;
                                                    final JSONObject site =
                                                            new JSONObject()
                                                                    .put("key", "emby_" + key)
                                                                    .put("name", "Emby · " + name)
                                                                    .put("type", 1)
                                                                    .put("api", api);
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (!dlg.isShowing()
                                                                            || a.isFinishing())
                                                                        return;
                                                                    try {
                                                                        if (!prefs.edit()
                                                                                .putString(
                                                                                        api,
                                                                                        session
                                                                                                .toString())
                                                                                .commit())
                                                                            throw new IOException(
                                                                                    "无法保存 Emby 登录状态");
                                                                        callback.save(site);
                                                                        pass.setText("");
                                                                        dlg.dismiss();
                                                                    } catch (Exception ex) {
                                                                        submit.setEnabled(true);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                    }
                                                                }
                                                            });
                                                } catch (Exception ex) {
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (dlg.isShowing()) {
                                                                        submit.setEnabled(true);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                    }
                                                                }
                                                            });
                                                }
                                            }
                                        },
                                        "emby-login")
                                .start();
                    }
                });
    }

    private static EditText field(Activity a, LinearLayout parent, String hint, int type) {
        EditText field = new EditText(a);
        field.setSingleLine(true);
        field.setInputType(type);
        field.setHint(hint);
        parent.addView(field);
        return field;
    }
}
