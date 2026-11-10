package com.pilipala.marcomovie;

import android.app.Activity;
import android.os.*;
import android.view.*;
import android.webkit.*;
import java.util.*;
import org.json.*;

/** Loads the configured playback page, observes media requests, and preserves its headers. */
public final class WebResolver {
    public interface Listener {
        void media(String url, Map<String, String> headers);

        void failed(String reason);
    }

    final WebView view;
    final Handler main = new Handler(Looper.getMainLooper());
    final Listener callback;
    final Map<String, String> initial;
    final String origin;
    boolean stopped;

    private final class LegacyClient extends WebViewClient {
        @Override
        @SuppressWarnings("deprecation")
        public WebResourceResponse shouldInterceptRequest(WebView web, String url) {
            if (url != null && isMedia(url)) found(url, Collections.<String, String>emptyMap());
            return null;
        }

        @Override
        public void onPageFinished(WebView web, String url) {
            scan();
        }

        @Override
        @SuppressWarnings("deprecation")
        public boolean shouldOverrideUrlLoading(WebView web, String url) {
            return url == null || !Cms.isHttp(url);
        }
    }

    private final class Api21Client extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView web, WebResourceRequest request) {
            String url = request.getUrl().toString();
            if (isMedia(url)) found(url, request.getRequestHeaders());
            return null;
        }

        @Override
        public void onPageFinished(WebView web, String url) {
            scan();
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView web, WebResourceRequest r) {
            return !Cms.isHttp(r.getUrl().toString());
        }
    }

    public WebResolver(
            Activity activity, String address, Map<String, String> headers, Listener listener) {
        origin = address;
        initial = new LinkedHashMap<>(headers);
        callback = listener;
        view = new WebView(activity);
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        if (Build.VERSION.SDK_INT >= 17) {
            settings.setMediaPlaybackRequiresUserGesture(false);
        }
        if (Build.VERSION.SDK_INT >= 21) {
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        }
        if (headers.containsKey("User-Agent"))
            settings.setUserAgentString(headers.get("User-Agent"));
        view.setWebViewClient(Build.VERSION.SDK_INT >= 21 ? new Api21Client() : new LegacyClient());
        main.postDelayed(
                () -> {
                    if (!stopped) {
                        callback.failed("页面未返回可直接播放的视频。可在下方网页完成登录或验证，再重试。");
                    }
                },
                30000);
        view.loadUrl(address, headers);
    }

    public WebView view() {
        return view;
    }

    static boolean isMedia(String url) {
        return Cms.isHttp(url)
                && url.toLowerCase(Locale.ROOT)
                        .matches(".*\\.(m3u8|mp4|mpd|flv|m4v|webm|m4a|mp3|aac)([?&#].*)?$");
    }

    void scan() {
        if (stopped) return;
        if (Build.VERSION.SDK_INT >= 19) {
            view.evaluateJavascript(
                    "JSON.stringify(Array.from(document.querySelectorAll('video,audio')).map(function(v){return v.currentSrc||v.src;}))",
                    value -> {
                        if (stopped) return;
                        try {
                            Object decoded = new JSONTokener(value).nextValue();
                            JSONArray urls = new JSONArray(String.valueOf(decoded));
                            for (int i = 0; i < urls.length(); i++) {
                                String u = urls.optString(i);
                                if (Cms.isHttp(u)) {
                                    found(u, Collections.<String, String>emptyMap());
                                    return;
                                }
                            }
                        } catch (Exception ignored) {
                        }
                        main.postDelayed(this::scan, 1500);
                    });
        }
    }

    void found(String url, Map<String, String> captured) {
        main.post(
                () -> {
                    if (stopped) return;
                    Map<String, String> headers = new LinkedHashMap<>(initial);
                    headers.putAll(captured);
                    headers.remove("Host");
                    headers.remove("host");
                    headers.remove("Range");
                    headers.remove("range");
                    headers.put("User-Agent", view.getSettings().getUserAgentString());
                    if (!headers.containsKey("Referer") && !headers.containsKey("referer"))
                        headers.put("Referer", view.getUrl() == null ? origin : view.getUrl());
                    String cookie = CookieManager.getInstance().getCookie(url);
                    if (cookie != null) headers.put("Cookie", cookie);
                    stop();
                    callback.media(url, headers);
                });
    }

    public void stop() {
        if (stopped) return;
        stopped = true;
        main.removeCallbacksAndMessages(null);
        view.stopLoading();
        view.loadUrl("about:blank");
        if (view.getParent() instanceof ViewGroup) ((ViewGroup) view.getParent()).removeView(view);
        view.destroy();
    }
}
