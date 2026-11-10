package com.pilipala.marcomovie;

import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.IOException;
import java.util.List;

/**
 * Live TV source/group/channel browsing, channel tuning, numeric keypad overlay, and remote key
 * bindings extracted from {@link MainActivity}.
 */
final class LiveController {
    private LiveController() {}

    static List<LiveCatalog.Source> sourcesFor(MainActivity a) {
        if (a == null) return java.util.Collections.emptyList();
        String raw = a.config != null ? a.config.raw : "";
        String customUrl = a.prefs != null ? a.prefs.getString(Prefs.LIVE_URL, "") : "";
        String customName = a.prefs != null ? a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源") : "";
        return LiveCatalog.sourcesFor(raw, a.configOrigin, customUrl, customName);
    }

    static void liveSources(MainActivity a) {
        a.renderPage("直播", "LIVE TV");
        LinearLayout actions = a.row();
        a.addButton(
                actions,
                a.button(
                        "＋ 导入直播源 (M3U / TXT / JSON)",
                        "live-import",
                        () -> SourceController.showLiveImportDialog(a)));
        a.body.addView(actions);
        a.gap(a.body, 10);
        try {
            List<LiveCatalog.Source> sources = sourcesFor(a);
            if (sources.isEmpty()) {
                a.paragraph("当前没有直播频道列表。可点击上方「＋ 导入直播源」导入 M3U、TXT 或 JSON 直播源。");
                return;
            }
            int cols = 3;
            LinearLayout row = null;
            for (int i = 0; i < sources.size(); i++) {
                if (i % cols == 0) {
                    row = a.row();
                    LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                    rlp.bottomMargin = a.dp(10);
                    a.body.addView(row, rlp);
                }
                LiveCatalog.Source source = sources.get(i);
                TextView btn =
                        a.button(
                                source.name,
                                "live-source:" + source.name,
                                () ->
                                        a.open(
                                                new MainActivity.Screen(
                                                        () -> liveGroups(a, source)),
                                                true));
                LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
                if (i % cols != cols - 1) blp.rightMargin = a.dp(10);
                row.addView(btn, blp);
            }
        } catch (Exception e) {
            AppLog.w("LiveController", "parse live sources failed", e);
            a.paragraph("无法读取直播配置。");
        }
    }

    static void liveGroups(MainActivity a, LiveCatalog.Source source) {
        a.renderPage(source.name, "LIVE CHANNELS");
        a.load(
                "读取频道分组…",
                () -> loadCatalog(a, source),
                catalog -> {
                    a.liveSession = new LiveSession(source, catalog);
                    a.paragraph(catalog.channelCount() + " 个频道 · 选择分组");
                    int cols = 4;
                    LinearLayout row = null;
                    for (int i = 0; i < catalog.groups.size(); i++) {
                        if (i % cols == 0) {
                            row = a.row();
                            LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                            rlp.bottomMargin = a.dp(10);
                            a.body.addView(row, rlp);
                        }
                        LiveCatalog.Group group = catalog.groups.get(i);
                        TextView btn =
                                a.button(
                                        group.name + "  ·  " + group.channels.size(),
                                        "group:" + group.name,
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () ->
                                                                        liveChannels(
                                                                                a, source, group,
                                                                                0)),
                                                        true));
                        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
                        if (i % cols != cols - 1) blp.rightMargin = a.dp(10);
                        row.addView(btn, blp);
                    }
                });
    }

    static LiveCatalog.Catalog loadCatalog(MainActivity a, LiveCatalog.Source source)
            throws Exception {
        if (source.plugin != null || source.isLocalProxy()) {
            if (!a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true))
                throw new IOException("请先启用来源扩展");
            a.ensureProxy(a.config);
            if (source.plugin == null) source.url = LocalProxy.rewrite(source.url);
        }
        return LiveCatalog.load(source, (site, url) -> a.engine(site).liveContent(url));
    }

    static void liveChannels(
            MainActivity a, LiveCatalog.Source source, LiveCatalog.Group group, int page) {
        a.renderPage(group.name, "LIVE CHANNELS");
        int pageSize = 40;
        int start = page * pageSize, end = Math.min(group.channels.size(), start + pageSize);
        int cols = 4;
        LinearLayout row = null;
        for (int i = start; i < end; i++) {
            int offset = i - start;
            if (offset % cols == 0) {
                row = a.row();
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                rlp.bottomMargin = a.dp(10);
                a.body.addView(row, rlp);
            }
            LiveCatalog.Channel channel = group.channels.get(i);
            String label =
                    channel.streams.size() > 1
                            ? channel.name + "  ·  " + channel.streams.size() + "源"
                            : channel.name;
            TextView btn =
                    a.button(
                            label,
                            "channel:" + i,
                            () -> {
                                if (channel.streams.size() == 1)
                                    playLive(a, source, channel, channel.streams.get(0));
                                else {
                                    String[] names = new String[channel.streams.size()];
                                    for (int n = 0; n < names.length; n++)
                                        names[n] = "线路 " + (n + 1);
                                    new AppDialog.Builder(a)
                                            .setTitle(channel.name)
                                            .setItems(
                                                    names,
                                                    (dialog, n) ->
                                                            playLive(
                                                                    a,
                                                                    source,
                                                                    channel,
                                                                    channel.streams.get(n)))
                                            .show();
                                }
                            });
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (offset % cols != cols - 1) blp.rightMargin = a.dp(10);
            row.addView(btn, blp);
        }
        LinearLayout pages = a.row();
        if (page > 0)
            a.addButton(
                    pages,
                    a.button(
                            "上一页",
                            "previous",
                            () ->
                                    a.open(
                                            new MainActivity.Screen(
                                                    () -> liveChannels(a, source, group, page - 1)),
                                            true)));
        if (end < group.channels.size())
            a.addButton(
                    pages,
                    a.button(
                            "下一页",
                            "next",
                            () ->
                                    a.open(
                                            new MainActivity.Screen(
                                                    () -> liveChannels(a, source, group, page + 1)),
                                            true)));
        a.body.addView(pages);
    }

    private static boolean isPlayableLiveUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return false;
        String u = rawUrl.trim();
        if (u.regionMatches(true, 0, "webview://", 0, 10)) return true;
        return Cms.isMedia(LocalProxy.rewrite(u));
    }

    static void playLive(
            MainActivity a,
            LiveCatalog.Source source,
            LiveCatalog.Channel channel,
            LiveCatalog.Stream stream) {
        if (a.liveSession != null && a.liveSession.source == source)
            a.liveSession.index = a.liveSession.channels.indexOf(channel);
        if (a.config != null) {
            try {
                a.ensureProxy(a.config);
            } catch (Exception ignored) {
            }
        }
        LiveCatalog.Stream chosen = stream;
        if (channel != null
                && !channel.streams.isEmpty()
                && (chosen == null || !isPlayableLiveUrl(chosen.url))) {
            for (LiveCatalog.Stream candidate : channel.streams) {
                if (isPlayableLiveUrl(candidate.url)) {
                    chosen = candidate;
                    break;
                }
            }
            if (chosen == null) chosen = channel.streams.get(0);
        }
        a.activeLine = null;
        a.activeEpisode = null;
        a.resumeAt = 0;
        String resolvedUrl = LocalProxy.rewrite(chosen.url);
        Cms.Site site = new Cms.Site();
        site.key = "live";
        site.name = source.name;
        site.api = resolvedUrl;
        site.type = 1;
        site.playUrl = "";
        site.headers.putAll(chosen.headers);
        Cms.Video video = new Cms.Video();
        video.title = channel.name;
        Cms.Episode ep = new Cms.Episode();
        ep.name =
                chosen.label != null && !chosen.label.trim().isEmpty() ? chosen.label.trim() : "直播";
        ep.url = resolvedUrl;
        ep.headers.putAll(chosen.headers);
        try {
            ep.media.put("live", true);
            if (channel != null && channel.streams.size() > 1) {
                org.json.JSONArray qualities = new org.json.JSONArray();
                int selectedIdx = 0;
                for (int i = 0; i < channel.streams.size(); i++) {
                    LiveCatalog.Stream st = channel.streams.get(i);
                    if (!isPlayableLiveUrl(st.url)
                            || st.url.regionMatches(true, 0, "webview://", 0, 10)) continue;
                    if (st == chosen) selectedIdx = qualities.length();
                    org.json.JSONObject q = new org.json.JSONObject();
                    String lbl =
                            st.label != null && !st.label.trim().isEmpty()
                                    ? st.label.trim()
                                    : ("线路 " + (i + 1));
                    q.put("name", lbl);
                    q.put("url", LocalProxy.rewrite(st.url));
                    if (!st.headers.isEmpty()) {
                        q.put("headers", new org.json.JSONObject(st.headers));
                    }
                    qualities.put(q);
                }
                if (qualities.length() > 1) {
                    ep.media.put("qualities", qualities);
                    ep.media.put("_qualityIdx", selectedIdx);
                }
            }
        } catch (Exception ignored) {
        }
        if (resolvedUrl != null && resolvedUrl.regionMatches(true, 0, "webview://", 0, 10)) {
            ep.url = resolvedUrl.substring(10).trim();
            site.api = ep.url;
            PlaybackController.resolveWebPage(a, site, video, ep, "");
            return;
        }
        if (a.current != null && a.current.player) {
            if (!Cms.isMedia(ep.url)) {
                PlaybackController.openPlayer(a, site, video, ep);
                return;
            }
            MainActivity.Screen next =
                    new MainActivity.Screen(
                            () -> PlaybackController.playerPage(a, site, video, ep));
            next.player = true;
            a.current = next;
            next.render.run();
        } else a.openPlayer(site, video, ep);
    }

    static boolean isLive(MainActivity a) {
        return a.playbackControls != null && "live".equals(a.playbackControls.site.key);
    }

    static boolean liveStep(MainActivity a, int direction) {
        if (a.liveSession == null || a.liveSession.channels.isEmpty()) return false;
        tuneLive(a, a.liveSession.step(direction), 0);
        return true;
    }

    static void tuneLive(MainActivity a, int index, int stream) {
        if (a.liveSession == null || index < 0 || index >= a.liveSession.channels.size()) return;
        LiveCatalog.Channel channel = a.liveSession.channels.get(index);
        playLive(
                a,
                a.liveSession.source,
                channel,
                channel.streams.get(Math.min(stream, channel.streams.size() - 1)));
    }

    static void chooseLiveChannel(MainActivity a) {
        if (a.liveSession == null) return;
        String[] labels = new String[a.liveSession.channels.size()];
        for (int i = 0; i < labels.length; i++)
            labels[i] = (i + 1) + " · " + a.liveSession.channels.get(i).name;
        a.playbackControls.choose("选择频道", labels, a.liveSession.index, i -> tuneLive(a, i, 0));
    }

    static void chooseLiveStream(MainActivity a) {
        if (a.liveSession == null || a.liveSession.index < 0) return;
        LiveCatalog.Channel c = a.liveSession.channels.get(a.liveSession.index);
        String[] labels = new String[c.streams.size()];
        for (int i = 0; i < labels.length; i++) {
            String lbl = c.streams.get(i).label;
            labels[i] =
                    "线路 "
                            + (i + 1)
                            + (lbl != null && !lbl.trim().isEmpty() ? " · " + lbl.trim() : "");
        }
        a.playbackControls.choose("直播线路", labels, -1, i -> tuneLive(a, a.liveSession.index, i));
    }

    static void clearLiveNumber(MainActivity a) {
        a.ui.removeCallbacks(a.tuneLiveNumber);
        if (a.liveSession != null) a.liveSession.clear();
        if (a.root != null) {
            View old = a.root.findViewWithTag("live-number");
            if (old != null) a.root.removeView(old);
        }
    }

    static void commitLiveNumber(MainActivity a) {
        if (!isLive(a) || a.liveSession == null) {
            clearLiveNumber(a);
            return;
        }
        int index = a.liveSession.selectedNumber();
        clearLiveNumber(a);
        if (index >= 0) tuneLive(a, index, 0);
        else a.toast("没有这个频道号");
    }

    static boolean liveKey(MainActivity a, KeyEvent event) {
        if (!isLive(a) || a.miniMode || a.liveSession == null || a.playbackControls.dialogOpen)
            return false;
        int key = event.getKeyCode();
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        int digit =
                key >= KeyEvent.KEYCODE_0 && key <= KeyEvent.KEYCODE_9
                        ? key - KeyEvent.KEYCODE_0
                        : key >= KeyEvent.KEYCODE_NUMPAD_0 && key <= KeyEvent.KEYCODE_NUMPAD_9
                                ? key - KeyEvent.KEYCODE_NUMPAD_0
                                : -1;
        if (digit >= 0) {
            if (down && event.getRepeatCount() == 0) {
                a.liveSession.digit(digit);
                TextView label = (TextView) a.root.findViewWithTag("live-number");
                if (label == null) {
                    label = a.text("", 30, MainActivity.WHITE);
                    label.setTag("live-number");
                    label.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
                    label.setBackground(a.bg(0xee25252b, 18));
                    FrameLayout.LayoutParams size =
                            new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                    size.setMargins(0, a.dp(30), a.dp(40), 0);
                    a.root.addView(label, size);
                }
                label.setText(a.liveSession.digits);
                a.ui.removeCallbacks(a.tuneLiveNumber);
                a.ui.postDelayed(a.tuneLiveNumber, 1200);
            }
            return true;
        }
        if (!a.liveSession.digits.isEmpty()
                && (key == KeyEvent.KEYCODE_DPAD_CENTER
                        || key == KeyEvent.KEYCODE_ENTER
                        || key == KeyEvent.KEYCODE_BACK)) {
            if (down && event.getRepeatCount() == 0) {
                if (key == KeyEvent.KEYCODE_BACK) clearLiveNumber(a);
                else commitLiveNumber(a);
            }
            return true;
        }
        boolean up =
                key == KeyEvent.KEYCODE_CHANNEL_UP
                        || !a.controlsVisible && key == KeyEvent.KEYCODE_DPAD_UP;
        boolean lower =
                key == KeyEvent.KEYCODE_CHANNEL_DOWN
                        || !a.controlsVisible && key == KeyEvent.KEYCODE_DPAD_DOWN;
        if (up || lower) {
            if (down && event.getRepeatCount() == 0) {
                clearLiveNumber(a);
                liveStep(
                        a,
                        key == KeyEvent.KEYCODE_CHANNEL_UP
                                ? 1
                                : key == KeyEvent.KEYCODE_CHANNEL_DOWN ? -1 : up ? -1 : 1);
            }
            return true;
        }
        return false;
    }
}
