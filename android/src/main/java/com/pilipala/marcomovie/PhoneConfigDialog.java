package com.pilipala.marcomovie;

import android.graphics.*;
import android.widget.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import com.google.zxing.*;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

/** App-owned QR pairing panel; no external QR service or persistent LAN listener. */
final class PhoneConfigDialog {
    final MainActivity a;
    ConfigTransferServer server;
    AppDialog dialog;
    boolean finished;
    final Runnable expiry = this::expire;

    void expire() {
        if (dialog != null && dialog.isShowing()) {
            dialog.dismiss();
            a.toast("二维码已过期，请重新打开手机配置");
        }
    }

    PhoneConfigDialog(MainActivity host) {
        a = host;
    }

    static String lanAddress() throws Exception {
        List<NetworkInterface> interfaces =
                Collections.list(NetworkInterface.getNetworkInterfaces());
        Collections.sort(
                interfaces,
                (a, b) -> {
                    int pa =
                            a.getName().startsWith("wlan")
                                    ? 0
                                    : a.getName().startsWith("eth") ? 1 : 2;
                    int pb =
                            b.getName().startsWith("wlan")
                                    ? 0
                                    : b.getName().startsWith("eth") ? 1 : 2;
                    return pa < pb ? -1 : (pa > pb ? 1 : 0);
                });
        for (NetworkInterface network : interfaces)
            if (network.isUp() && !network.isLoopback())
                for (InetAddress ip : Collections.list(network.getInetAddresses()))
                    if (ip instanceof Inet4Address && ip.isSiteLocalAddress())
                        return ip.getHostAddress();
        throw new java.io.IOException("No LAN address");
    }

    void show() {
        if (!a.isTvDevice()) {
            MobileShell.showMobileImportDialog(a);
            return;
        }
        try {
            String ip = lanAddress();
            server =
                    new ConfigTransferServer(
                            address -> {
                                Cms.Config config =
                                        Cms.parseConfig(
                                                SourceController.fetchImport(a, address),
                                                SourceController.importOrigin(address));
                                CountDownLatch applied = new CountDownLatch(1);
                                AtomicReference<Exception> failure = new AtomicReference<>();
                                a.ui.post(
                                        () -> {
                                            try {
                                                if (server.closed
                                                        || a.isFinishing()
                                                        || a.phoneConfig != this)
                                                    throw new java.io.IOException("Session closed");
                                                a.saveConfig(
                                                        config,
                                                        SourceController.importOrigin(address));
                                                finished = true;
                                                if (dialog != null) dialog.dismiss();
                                            } catch (Exception e) {
                                                failure.set(e);
                                            } finally {
                                                applied.countDown();
                                            }
                                        });
                                if (!applied.await(20, TimeUnit.SECONDS))
                                    throw new java.io.IOException("Apply timeout");
                                if (failure.get() != null) throw failure.get();
                            });
            String address = server.address(ip);
            LinearLayout panel = a.vertical();
            panel.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
            TextView note = a.text("手机与电视连接同一网络，扫码后在手机粘贴配置地址。", 15, MainActivity.MUTED);
            panel.addView(note);
            a.gap(panel, 12);
            int qrSize = a.dp(190);
            BitMatrix matrix =
                    new QRCodeWriter().encode(address, BarcodeFormat.QR_CODE, qrSize, qrSize);
            int[] pixels = new int[qrSize * qrSize];
            for (int y = 0; y < qrSize; y++)
                for (int x = 0; x < qrSize; x++)
                    pixels[y * qrSize + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            ImageView qr = new ImageView(a);
            qr.setTag("config-qr");
            qr.setContentDescription("手机扫码配置二维码");
            qr.setImageBitmap(Bitmap.createBitmap(pixels, qrSize, qrSize, Bitmap.Config.ARGB_8888));
            panel.addView(qr, new LinearLayout.LayoutParams(a.dp(190), a.dp(190)));
            TextView url = a.text(address, 12, MainActivity.WHITE);
            url.setTag("config-phone-address");
            url.setGravity(android.view.Gravity.CENTER);
            url.setPadding(0, a.dp(10), 0, 0);
            panel.addView(url);
            android.widget.Button emby = new android.widget.Button(a);
            emby.setText("连接 Emby");
            emby.setOnClickListener(
                    v -> {
                        if (dialog != null) dialog.dismiss();
                        EmbyEngine.connect(a);
                    });
            panel.addView(emby);
            a.gap(panel, 6);
            panel.addView(a.text("二维码有效 5 分钟 · 关闭后停止接收", 12, MainActivity.MUTED));
            dialog =
                    new AppDialog.Builder(a)
                            .setTitle("手机扫码配置")
                            .setView(panel)
                            .setNeutralButton("遥控输入", (d, n) -> a.addressImportDialog())
                            .setPositiveButton("刷新二维码", (d, n) -> a.importDialog())
                            .setNegativeButton("完成", null)
                            .create();
            dialog.setOnDismissListener(
                    d -> {
                        a.ui.removeCallbacks(expiry);
                        if (finished) a.ui.postDelayed(this::close, 2000);
                        else close();
                    });
            dialog.show();
            dialog.getButton(-2).requestFocus();
            a.ui.postDelayed(expiry, TimeUnit.MINUTES.toMillis(5));
        } catch (Exception error) {
            close();
            a.toast("未能打开局域网配置，可先使用遥控输入或本地文件");
            a.addressImportDialog();
        }
    }

    void close() {
        a.ui.removeCallbacks(expiry);
        if (server != null) server.close();
        if (a.phoneConfig == this) a.phoneConfig = null;
    }
}
