package com.pilipala.marcomovie;

import android.app.Dialog;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import com.pilipala.catpaw.CatPawHost;

/** Explicit local settings entry; the source owns its login and configuration UI. */
final class CatPawSettings {
    static boolean available(MainActivity a) {
        if (a.config == null) return false;
        for (Cms.Site site : a.config.sites) if (site.api.startsWith("catpaw://")) return true;
        return false;
    }

    static void choose(MainActivity a) {
        java.util.LinkedHashMap<String, Cms.Site> bundles = new java.util.LinkedHashMap<>();
        if (a.config == null) return;
        for (Cms.Site site : a.config.sites)
            if (site.api.startsWith("catpaw://"))
                bundles.put(android.net.Uri.parse(site.api).getHost(), site);
        java.util.ArrayList<Cms.Site> sites = new java.util.ArrayList<>(bundles.values());
        if (sites.isEmpty()) return;
        if (sites.size() == 1) {
            open(a, sites.get(0));
            return;
        }
        String[] names = new String[sites.size()];
        for (int i = 0; i < names.length; i++) names[i] = sites.get(i).name;
        new AppDialog.Builder(a)
                .setTitle("选择 CatPaw 订阅")
                .wrapChoices()
                .setItems(names, (dialog, index) -> open(a, sites.get(index)))
                .show();
    }

    static void open(MainActivity a, Cms.Site site) {
        a.notice("正在打开 CatPaw 本机配置");
        a.worker.execute(
                () -> {
                    try {
                        String address = new CatPawHost(a).settings(site.api);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.isDestroyed()) return;
                                    Dialog dialog = new Dialog(a);
                                    LinearLayout page = a.vertical();
                                    page.setBackgroundColor(MainActivity.DARK);
                                    page.addView(
                                            a.navButton(
                                                    "返回 · CatPaw 配置",
                                                    "catpaw-settings-back",
                                                    dialog::dismiss));
                                    WebView web = new WebView(a);
                                    web.getSettings().setJavaScriptEnabled(true);
                                    web.getSettings().setDomStorageEnabled(true);
                                    web.getSettings().setAllowFileAccess(false);
                                    web.getSettings().setAllowContentAccess(false);
                                    web.setWebViewClient(
                                            new WebViewClient() {
                                                @Override
                                                public boolean shouldOverrideUrlLoading(
                                                        WebView view, String url) {
                                                    String scheme =
                                                            android.net.Uri.parse(url).getScheme();
                                                    return !"https".equals(scheme)
                                                            && !"http".equals(scheme);
                                                }
                                            });
                                    page.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
                                    dialog.setContentView(page);
                                    dialog.setOnDismissListener(
                                            d -> {
                                                web.stopLoading();
                                                web.destroy();
                                            });
                                    dialog.show();
                                    if (dialog.getWindow() != null)
                                        dialog.getWindow().setLayout(-1, -1);
                                    web.loadUrl(address);
                                });
                    } catch (Exception failure) {
                        a.ui.post(() -> a.notice("无法打开本机配置，请确认 CatPaw 订阅已成功导入"));
                    }
                });
    }
}
