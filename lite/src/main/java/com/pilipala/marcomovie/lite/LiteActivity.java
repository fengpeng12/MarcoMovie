// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.UiModeManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewConfiguration;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.MultiFormatWriter;
import com.google.zxing.common.BitMatrix;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Android 4.0+ (API 14+) TV Lite Edition: TV-adapted multi-column poster grid, D-pad focus
 * navigation, line & episode group tabs, built-in remote search keyboard, watch history,
 * favorites, live TV, HTTPS media proxy, and auto-hiding playback OSD.
 */
public final class LiteActivity extends Activity {
    static final int COLOR_BG = 0xff101013;
    static final int COLOR_CARD = 0xff22232b;
    static final int COLOR_CARD_SUBTLE = 0xff1a1b22;
    static final int COLOR_BUTTON = 0xff28282f;
    static final int COLOR_BORDER = 0xff383a47;
    static final int COLOR_ACCENT = 0xff0a84ff;
    static final int COLOR_FOCUS = 0xfff5f5f7;
    static final int COLOR_TEXT = 0xffeeeef2;
    static final int COLOR_MUTED = 0xff9e9ea8;
    static final int EPISODE_GROUP_SIZE = 40;
    static final long OSD_AUTO_HIDE_MS = 4500L;

    final Handler ui = new Handler();
    final ThreadPoolExecutor io =
            new ThreadPoolExecutor(
                    3,
                    3,
                    0L,
                    TimeUnit.MILLISECONDS,
                    new LinkedBlockingQueue<Runnable>(16),
                    new ThreadPoolExecutor.DiscardOldestPolicy());
    Future<?> activeWork;
    ScrollView mainScroll;
    LinearLayout page;
    TextView status;
    ConfigServer pairing;
    LitePlayer player;
    com.pilipala.emby.EmbyLibrary.Reporter embyReporter;
    String playbackTitle = "";
    String playbackAddress = "";
    SurfaceView surface;
    FrameLayout playback;
    LinearLayout playerTopBar, playerBottomPanel, playerControlRow;
    TextView aspectBtnView, pauseResumeBtnView, proxyBtnView;
    int videoWidth, videoHeight, aspectMode;
    java.util.List<LiteCatalog.Site> sites = new ArrayList<LiteCatalog.Site>();
    LiteCatalog.Site selected;
    java.util.List<LiteCatalog.Category> categories = new ArrayList<LiteCatalog.Category>();
    volatile int epoch;
    volatile boolean ready, dead;
    JSONObject currentDetail;
    int activeDetailLine;
    int activeEpisodeGroup;
    boolean episodeReversed;
    List<EpisodeItem> currentLineEpisodes = new ArrayList<EpisodeItem>();
    int playingEpisodeIndex = -1;
    LiteCatalog.LiveGroup playingLiveGroup;
    int playingLiveChannelIndex = -1;
    int playingLiveUrlIndex = 0;
    final Object importLock = new Object();
    boolean homeVisible, inPlayback, backgrounded, inDetail;
    String lastQuery = "", lastCategory = "";
    int lastPage = 1;
    SeekBar timeline;
    TextView clockView;
    boolean touchSeeking, sliderSeeking;
    int lastUserSeekMs = -1;
    long lastUserSeekAt;
    long lastUpKeyAt;
    int upKeyStreak;

    static final class EpisodeItem {
        final String name;
        final String url;
        final int originalIndex;

        EpisodeItem(String name, String url, int originalIndex) {
            this.name = name;
            this.url = url;
            this.originalIndex = originalIndex;
        }
    }

    final Runnable hideOsdTask =
            new Runnable() {
                public void run() {
                    if (dead || !inPlayback || !ready) return;
                    if (touchSeeking || sliderSeeking) {
                        scheduleOsdHide();
                        return;
                    }
                    setOsdVisibility(View.GONE);
                }
            };

    final Runnable clockTick =
            new Runnable() {
                public void run() {
                    if (dead || !inPlayback || player == null) return;
                    if (ready && !touchSeeking && !sliderSeeking) {
                        try {
                            int pos = player.getCurrentPosition(), dur = player.getDuration();
                            if (embyReporter != null)
                                embyReporter.update(pos, !player.isPlaying());
                            if (lastUserSeekMs >= 0
                                    && SystemClock.uptimeMillis() - lastUserSeekAt < 1500)
                                pos = lastUserSeekMs;
                            else lastUserSeekMs = -1;
                            if (timeline != null && dur > 0) {
                                timeline.setMax(dur);
                                timeline.setProgress(Math.max(0, Math.min(dur, pos)));
                            }
                            if (clockView != null)
                                clockView.setText(formatTime(pos) + " / " + formatTime(dur));
                        } catch (Exception ignored) {
                        }
                    }
                    ui.postDelayed(this, 1000);
                }
            };

    interface Job {
        void run() throws Exception;
    }

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        aspectMode = getPreferences(0).getInt("aspect_mode", 0);
        String crashedSite = getPreferences(0).getString("loading_site", "");
        if (crashedSite != null && crashedSite.length() > 0) {
            getPreferences(0)
                    .edit()
                    .putString("loading_site", "")
                    .putString("selected_site", "")
                    .commit();
        }
        home();
        if (crashedSite != null && crashedSite.length() > 0 && status != null) {
            status.setText("上次加载片源时异常退出，已自动重置片源选择。");
        }
    }

    int dp(int n) {
        return (int) (n * getResources().getDisplayMetrics().density + .5f);
    }

    int screenWidthDp() {
        int w = getResources().getDisplayMetrics().widthPixels;
        float d = getResources().getDisplayMetrics().density;
        return d > 0 ? (int) (w / d) : 640;
    }

    boolean isTvOrLandscape() {
        try {
            UiModeManager um = (UiModeManager) getSystemService(Context.UI_MODE_SERVICE);
            if (um != null
                    && um.getCurrentModeType() == Configuration.UI_MODE_TYPE_TELEVISION) {
                return true;
            }
        } catch (Throwable ignored) {
        }
        int w = getResources().getDisplayMetrics().widthPixels;
        int h = getResources().getDisplayMetrics().heightPixels;
        return w >= h || screenWidthDp() >= 560;
    }

    int posterColumns() {
        int w = screenWidthDp();
        if (w >= 860) return 5;
        if (w >= 560) return 4;
        if (w >= 380) return 3;
        return 2;
    }

    int siteColumns() {
        if (!isTvOrLandscape()) return 1;
        return screenWidthDp() >= 760 ? 3 : 2;
    }

    int episodeColumns(List<EpisodeItem> list) {
        int maxLen = 0;
        for (int i = 0; i < Math.min(list.size(), 20); i++) {
            maxLen = Math.max(maxLen, list.get(i).name.length());
        }
        if (isTvOrLandscape()) {
            if (maxLen > 14) return 3;
            return screenWidthDp() >= 800 ? 5 : 4;
        }
        return maxLen > 10 ? 2 : 3;
    }

    static String formatTime(int ms) {
        int total = Math.max(0, ms / 1000),
                s = total % 60,
                m = (total / 60) % 60,
                h = total / 3600;
        return h > 0
                ? String.format(Locale.US, "%d:%02d:%02d", h, m, s)
                : String.format(Locale.US, "%02d:%02d", m, s);
    }

    static String aspectLabel(int mode) {
        switch (mode % 4) {
            case 1:
                return "铺满";
            case 2:
                return "16:9";
            case 3:
                return "4:3";
            default:
                return "适应";
        }
    }

    static String proxyModeLabel(int mode) {
        switch (mode % 3) {
            case LiteMediaProxy.MODE_ALWAYS:
                return "始终开启";
            case LiteMediaProxy.MODE_OFF:
                return "关闭";
            default:
                return "自动(HTTPS/HLS)";
        }
    }

    public static int computeLongPressSeekStepMs(int repeatCount) {
        if (repeatCount <= 0) return 15000;
        if (repeatCount <= 3) return 25000;
        if (repeatCount <= 7) return 45000;
        if (repeatCount <= 12) return 75000;
        return 120000;
    }

    public static int[] computeAspectDimensions(
            int containerW, int containerH, int videoW, int videoH, int aspectMode) {
        if (containerW <= 0 || containerH <= 0) return new int[] {containerW, containerH};
        int mode = ((aspectMode % 4) + 4) % 4;
        if (mode == 1) {
            return new int[] {containerW, containerH};
        }
        double targetRatio;
        if (mode == 2) {
            targetRatio = 16.0 / 9.0;
        } else if (mode == 3) {
            targetRatio = 4.0 / 3.0;
        } else {
            if (videoW <= 0 || videoH <= 0) return new int[] {containerW, containerH};
            targetRatio = (double) videoW / videoH;
        }
        double containerRatio = (double) containerW / containerH;
        int outW, outH;
        if (containerRatio > targetRatio) {
            outH = containerH;
            outW = Math.max(1, (int) Math.round(outH * targetRatio));
        } else {
            outW = containerW;
            outH = Math.max(1, (int) Math.round(outW / targetRatio));
        }
        return new int[] {outW, outH};
    }

    TextView text(String value, int size) {
        TextView t = new TextView(this);
        t.setText(value);
        t.setTextSize(size);
        t.setTextColor(COLOR_TEXT);
        t.setPadding(dp(8), dp(8), dp(8), dp(8));
        return t;
    }

    void cancelWork() {
        if (activeWork != null) {
            activeWork.cancel(true);
            activeWork = null;
        }
        io.purge();
        LiteCatalog.cancelAll();
    }

    void base(String title) {
        homeVisible = false;
        inPlayback = false;
        playingLiveGroup = null;
        ui.removeCallbacks(clockTick);
        ui.removeCallbacks(hideOsdTask);
        epoch++;
        cancelWork();
        closePairing();
        release();
        mainScroll = new ScrollView(this);
        mainScroll.setFillViewport(true);
        mainScroll.setBackgroundColor(COLOR_BG);
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        int hPad = isTvOrLandscape() ? dp(28) : dp(16);
        page.setPadding(hPad, dp(14), hPad, dp(28));
        mainScroll.addView(page);
        setContentView(mainScroll);
        addTopHeader(title);
        status = text("", 14);
        status.setTextColor(COLOR_MUTED);
        page.addView(status);
    }

    void addTopHeader(String title) {
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(0, 0, 0, dp(4));

        TextView titleView = text(title, isTvOrLandscape() ? 24 : 20);
        titleView.setTypeface(null, Typeface.BOLD);
        header.addView(titleView, new LinearLayout.LayoutParams(0, -2, 1f));

        HorizontalScrollView navScroll = new HorizontalScrollView(this);
        navScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout navRow = new LinearLayout(this);
        navRow.setOrientation(LinearLayout.HORIZONTAL);
        navRow.setGravity(Gravity.CENTER_VERTICAL);
        navScroll.addView(navRow);

        addNavPill(
                navRow,
                "首页片源",
                new Runnable() {
                    public void run() {
                        home();
                    }
                });
        if (selected != null && selected.supported) {
            addNavPill(
                    navRow,
                    "当前：" + truncate(selected.name, 8),
                    new Runnable() {
                        public void run() {
                            catalog("", 1);
                        }
                    });
        }
        addNavPill(
                navRow,
                "搜索",
                new Runnable() {
                    public void run() {
                        search();
                    }
                });
        addNavPill(
                navRow,
                "直播",
                new Runnable() {
                    public void run() {
                        livePage();
                    }
                });
        addNavPill(
                navRow,
                "历史",
                new Runnable() {
                    public void run() {
                        historyPage();
                    }
                });
        addNavPill(
                navRow,
                "收藏",
                new Runnable() {
                    public void run() {
                        favoritesPage();
                    }
                });
        addNavPill(
                navRow,
                "配置",
                new Runnable() {
                    public void run() {
                        configure();
                    }
                });
        header.addView(navScroll, new LinearLayout.LayoutParams(-2, -2));
        page.addView(header, new LinearLayout.LayoutParams(-1, -2));
    }

    void addNavPill(LinearLayout row, String label, final Runnable action) {
        final TextView pill = text(label, 14);
        pill.setPadding(dp(12), dp(6), dp(12), dp(6));
        pill.setGravity(Gravity.CENTER);
        pill.setSingleLine(true);
        pill.setFocusable(true);
        pill.setClickable(true);
        styleChip(pill, false, false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(36));
        lp.setMargins(dp(3), dp(2), dp(3), dp(2));
        pill.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        styleChip(pill, false, focus);
                    }
                });
        pill.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        action.run();
                    }
                });
        row.addView(pill, lp);
    }

    static String truncate(String s, int maxChars) {
        if (s == null) return "";
        String t = s.trim();
        return t.length() <= maxChars ? t : t.substring(0, maxChars) + "…";
    }

    void button(String title, final Runnable action) {
        final TextView b = text(title, 17);
        b.setGravity(Gravity.CENTER);
        b.setFocusable(true);
        b.setClickable(true);
        style(b, false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(48));
        lp.setMargins(dp(4), dp(4), dp(4), dp(4));
        page.addView(b, lp);
        b.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        style(b, focus);
                    }
                });
        b.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        action.run();
                    }
                });
    }

    TextView makeActionButton(String title, final boolean primary, final Runnable action) {
        final TextView b = text(title, 15);
        b.setPadding(dp(14), dp(8), dp(14), dp(8));
        b.setGravity(Gravity.CENTER);
        b.setSingleLine(true);
        b.setEllipsize(TextUtils.TruncateAt.END);
        b.setFocusable(true);
        b.setClickable(true);
        styleChip(b, primary, false);
        b.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        styleChip(b, primary, focus);
                    }
                });
        b.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        action.run();
                    }
                });
        return b;
    }

    @SuppressWarnings("deprecation")
    void style(TextView b, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(focused ? COLOR_FOCUS : COLOR_BUTTON);
        bg.setCornerRadius(dp(12));
        bg.setStroke(dp(1), focused ? 0xffffffff : COLOR_BORDER);
        b.setBackgroundDrawable(bg);
        b.setTextColor(focused ? COLOR_BG : COLOR_TEXT);
        b.setTypeface(null, focused ? Typeface.BOLD : Typeface.NORMAL);
    }

    @SuppressWarnings("deprecation")
    void styleChip(TextView chip, boolean active, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        if (focused) {
            bg.setColor(COLOR_FOCUS);
            bg.setStroke(dp(2), COLOR_ACCENT);
            chip.setTextColor(COLOR_BG);
            chip.setTypeface(null, Typeface.BOLD);
        } else if (active) {
            bg.setColor(COLOR_ACCENT);
            bg.setStroke(dp(1), 0xff409cff);
            chip.setTextColor(0xffffffff);
            chip.setTypeface(null, Typeface.BOLD);
        } else {
            bg.setColor(COLOR_BUTTON);
            bg.setStroke(dp(1), COLOR_BORDER);
            chip.setTextColor(COLOR_TEXT);
            chip.setTypeface(null, Typeface.NORMAL);
        }
        bg.setCornerRadius(dp(10));
        chip.setBackgroundDrawable(bg);
    }

    @SuppressWarnings("deprecation")
    void styleCard(View card, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(focused ? 0xff2c3040 : COLOR_CARD);
        bg.setCornerRadius(dp(12));
        bg.setStroke(dp(focused ? 2 : 1), focused ? COLOR_FOCUS : COLOR_BORDER);
        card.setBackgroundDrawable(bg);
        try {
            card.setScaleX(focused ? 1.02f : 1.0f);
            card.setScaleY(focused ? 1.02f : 1.0f);
        } catch (Throwable ignored) {
        }
    }

    void addGridViews(LinearLayout container, List<View> views, int columns, int itemHeightDp) {
        if (views == null || views.isEmpty()) return;
        int cols = Math.max(1, columns);
        LinearLayout row = null;
        for (int i = 0; i < views.size(); i++) {
            if (i % cols == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                container.addView(row, new LinearLayout.LayoutParams(-1, -2));
            }
            View child = views.get(i);
            LinearLayout.LayoutParams lp =
                    new LinearLayout.LayoutParams(
                            0, itemHeightDp > 0 ? dp(itemHeightDp) : -2, 1f);
            lp.setMargins(dp(4), dp(4), dp(4), dp(4));
            row.addView(child, lp);
        }
        int rem = views.size() % cols;
        if (rem != 0 && row != null) {
            for (int i = rem; i < cols; i++) {
                View spacer = new View(this);
                spacer.setFocusable(false);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, 1, 1f);
                lp.setMargins(dp(4), dp(4), dp(4), dp(4));
                row.addView(spacer, lp);
            }
        }
    }

    void addSectionHeader(String title) {
        TextView hdr = text(title, 16);
        hdr.setTextColor(COLOR_MUTED);
        hdr.setTypeface(null, Typeface.BOLD);
        hdr.setPadding(dp(4), dp(10), dp(4), dp(4));
        page.addView(hdr, new LinearLayout.LayoutParams(-1, -2));
    }

    void work(final Job job) {
        final int id = epoch;
        status.setText("正在加载…");
        cancelWork();
        activeWork =
                io.submit(
                        new Runnable() {
                            public void run() {
                                if (dead || epoch != id) return;
                                try {
                                    job.run();
                                } catch (final Throwable ex) {
                                    ui.post(
                                            new Runnable() {
                                                public void run() {
                                                    getPreferences(0)
                                                            .edit()
                                                            .putString("loading_site", "")
                                                            .commit();
                                                    if (!dead && epoch == id)
                                                        status.setText(
                                                                "加载失败，请重试。请检查网络、配置类型及旧系统 HTTPS 兼容性。");
                                                }
                                            });
                                }
                            }
                        });
    }

    void loadConfiguredSites() {
        String raw = getPreferences(0).getString("config", "");
        sites = new ArrayList<LiteCatalog.Site>();
        try {
            if (raw.length() > 0)
                sites = LiteCatalog.parse(raw, getPreferences(0).getString("address", ""));
        } catch (Throwable ignored) {
        }
        try {
            JSONObject libraries =
                    new JSONObject(getPreferences(0).getString("emby_libraries", "{}"));
            java.util.Iterator<String> it = libraries.keys();
            while (it.hasNext()) {
                JSONObject item = libraries.getJSONObject(it.next());
                sites.addAll(
                        LiteCatalog.parse(
                                new JSONObject().put("sites", new JSONArray().put(item)).toString(),
                                ""));
            }
        } catch (Exception ignored) {
        }
        applySiteEdits();
        String preferred = getPreferences(0).getString("preferred_site_identity", "");
        for (int i = 0; i < sites.size(); i++) {
            LiteCatalog.Site site = sites.get(i);
            if (site.supported && (site.key + "\n" + site.api).equals(preferred)) {
                sites.remove(i);
                sites.add(0, site);
                break;
            }
        }
        if (selected == null && !sites.isEmpty()) {
            String lastKey = getPreferences(0).getString("selected_site", "");
            for (int i = 0; i < sites.size(); i++) {
                LiteCatalog.Site s = sites.get(i);
                if (s.supported && s.key.equals(lastKey)) {
                    selected = s;
                    break;
                }
            }
            if (selected == null) {
                for (int i = 0; i < sites.size(); i++) {
                    if (sites.get(i).supported) {
                        selected = sites.get(i);
                        break;
                    }
                }
            }
        }
    }

    void home() {
        inDetail = false;
        base("MARCO MOVIE  Lite");
        homeVisible = true;
        status.setText("Android 4.0+ 电视轻量兼容版 · 遥控器方向键与确认键操作 · 不含任何影视资源");

        loadConfiguredSites();
        final String raw = getPreferences(0).getString("config", "");

        LinearLayout quickBar = new LinearLayout(this);
        quickBar.setOrientation(LinearLayout.HORIZONTAL);
        List<View> quickBtns = new ArrayList<View>();
        quickBtns.add(
                makeActionButton(
                        "手机扫码配置",
                        sites.isEmpty(),
                        new Runnable() {
                            public void run() {
                                configure();
                            }
                        }));
        quickBtns.add(
                makeActionButton(
                        "输入配置地址",
                        false,
                        new Runnable() {
                            public void run() {
                                importUrlPage();
                            }
                        }));
        try {
            if (raw.length() > 0
                    && LiteCatalog.decodeConfig(raw)
                                    .optJSONArray(com.pilipala.source.Warehouse.DEPOTS)
                            != null) {
                quickBtns.add(
                        makeActionButton(
                                "切换子仓库",
                                false,
                                new Runnable() {
                                    public void run() {
                                        warehousePage();
                                    }
                                }));
            }
        } catch (Exception ignored) {
        }
        if (!sites.isEmpty()) {
            quickBtns.add(
                    makeActionButton(
                            "管理线路",
                            false,
                            new Runnable() {
                                public void run() {
                                    manageSites();
                                }
                            }));
            quickBtns.add(
                    makeActionButton(
                            "全站搜索",
                            false,
                            new Runnable() {
                                public void run() {
                                    search();
                                }
                            }));
        }
        int proxyMode = getPreferences(0).getInt("proxy_mode", LiteMediaProxy.MODE_AUTO);
        quickBtns.add(
                makeActionButton(
                        "HTTPS代理：" + proxyModeLabel(proxyMode),
                        false,
                        new Runnable() {
                            public void run() {
                                int next =
                                        (getPreferences(0)
                                                        .getInt(
                                                                "proxy_mode",
                                                                LiteMediaProxy.MODE_AUTO)
                                                + 1)
                                                % 3;
                                getPreferences(0).edit().putInt("proxy_mode", next).commit();
                                home();
                            }
                        }));
        if (PlayerFactory.hasCandidate()) {
            quickBtns.add(
                    makeActionButton(
                            getPreferences(0).getBoolean("experimental_decoder", false)
                                    ? "解码：IJK 实验版"
                                    : "解码：系统",
                            false,
                            new Runnable() {
                                public void run() {
                                    getPreferences(0)
                                            .edit()
                                            .putBoolean(
                                                    "experimental_decoder",
                                                    !getPreferences(0)
                                                            .getBoolean(
                                                                    "experimental_decoder", false))
                                            .commit();
                                    home();
                                }
                            }));
        }
        addGridViews(page, quickBtns, isTvOrLandscape() ? 3 : 2, 46);

        List<LiteStore.HistoryEntry> history = LiteStore.getHistory(this);
        if (!history.isEmpty()) {
            addSectionHeader("继续观看");
            List<View> histCards = new ArrayList<View>();
            for (int i = 0; i < Math.min(history.size(), 6); i++) {
                final LiteStore.HistoryEntry h = history.get(i);
                String progress =
                        h.epName
                                + (h.positionMs > 0 ? " · " + formatTime(h.positionMs) : "");
                String label = h.vodName + "\n" + progress + " (" + h.siteName + ")";
                final TextView card = text(label, 14);
                card.setMaxLines(2);
                card.setEllipsize(TextUtils.TruncateAt.END);
                card.setGravity(Gravity.CENTER_VERTICAL | Gravity.LEFT);
                card.setPadding(dp(12), dp(8), dp(12), dp(8));
                card.setFocusable(true);
                card.setClickable(true);
                styleCard(card, false);
                card.setOnFocusChangeListener(
                        new View.OnFocusChangeListener() {
                            public void onFocusChange(View v, boolean f) {
                                styleCard(card, f);
                            }
                        });
                card.setOnClickListener(
                        new View.OnClickListener() {
                            public void onClick(View v) {
                                openHistoryOrFavorite(h.siteKey, h.siteApi, h.siteName, h.vodId);
                            }
                        });
                histCards.add(card);
            }
            addGridViews(page, histCards, isTvOrLandscape() ? 3 : 1, 60);
        }

        String preferred = getPreferences(0).getString("preferred_site_identity", "");
        if (!sites.isEmpty()) {
            int supportedCount = 0;
            for (int i = 0; i < sites.size(); i++) {
                if (sites.get(i).supported) supportedCount++;
            }
            addSectionHeader(
                    "选择片源（共 "
                            + sites.size()
                            + " 个，可直接浏览 "
                            + supportedCount
                            + " 个）");
            List<View> siteButtons = new ArrayList<View>();
            for (int i = 0; i < sites.size(); i++) {
                final LiteCatalog.Site s = sites.get(i);
                boolean isPref = (s.key + "\n" + s.api).equals(preferred);
                String tag =
                        s.api.startsWith("emby://")
                                ? " [Emby]"
                                : s.type == 0 ? " [XML]" : s.supported ? "" : " · 尚未兼容";
                String title = (isPref ? "★ 默认 · " : "") + s.name + tag;
                final TextView b =
                        makeActionButton(
                                title,
                                isPref,
                                new Runnable() {
                                    public void run() {
                                        if (s.supported) {
                                            selected = s;
                                            categories.clear();
                                            getPreferences(0)
                                                    .edit()
                                                    .putString("selected_site", s.key)
                                                    .putString("loading_site", s.key)
                                                    .commit();
                                            catalog("", 1);
                                        } else {
                                            status.setText(
                                                    "此来源需要插件、JS 或网页解析，Android 4.0 轻量版仅支持标准 JSON/XML CMS 与 Emby 片源。");
                                        }
                                    }
                                });
                siteButtons.add(b);
            }
            addGridViews(page, siteButtons, sites.size() <= 3 ? 1 : siteColumns(), 48);
        }
    }

    void openHistoryOrFavorite(String siteKey, String siteApi, String siteName, String vodId) {
        loadConfiguredSites();
        LiteCatalog.Site match = null;
        for (int i = 0; i < sites.size(); i++) {
            LiteCatalog.Site s = sites.get(i);
            if (s.supported && (s.key.equals(siteKey) || s.api.equals(siteApi))) {
                match = s;
                break;
            }
        }
        if (match == null && siteApi != null && siteApi.length() > 0) {
            match = new LiteCatalog.Site();
            match.key = siteKey;
            match.name = siteName.length() > 0 ? siteName : "已存片源";
            match.api = siteApi;
            match.type = 1;
            match.supported = true;
        }
        if (match != null) {
            selected = match;
            detail(vodId);
        } else {
            status.setText("未找到该记录对应的片源配置，请先导入对应配置。");
        }
    }

    void historyPage() {
        base("观看历史");
        final List<LiteStore.HistoryEntry> list = LiteStore.getHistory(this);
        if (list.isEmpty()) {
            status.setText("暂无观看历史记录。");
            button(
                    "返回首页",
                    new Runnable() {
                        public void run() {
                            home();
                        }
                    });
            return;
        }
        status.setText("共 " + list.size() + " 条观看记录，点击即可断点续播：");
        button(
                "清空全部观看历史",
                new Runnable() {
                    public void run() {
                        LiteStore.clearHistory(LiteActivity.this);
                        getPreferences(0)
                                .edit()
                                .remove("resume_address")
                                .remove("resume_ms")
                                .commit();
                        historyPage();
                    }
                });
        List<View> cards = new ArrayList<View>();
        for (int i = 0; i < list.size(); i++) {
            final LiteStore.HistoryEntry h = list.get(i);
            String remark =
                    h.epName
                            + (h.positionMs > 0 ? " " + formatTime(h.positionMs) : "");
            cards.add(
                    createPosterCard(
                            h.vodName,
                            h.vodPic,
                            remark,
                            h.siteName,
                            Collections.<String, String>emptyMap(),
                            new Runnable() {
                                public void run() {
                                    openHistoryOrFavorite(
                                            h.siteKey, h.siteApi, h.siteName, h.vodId);
                                }
                            }));
        }
        addGridViews(page, cards, posterColumns(), -2);
    }

    void favoritesPage() {
        base("我的收藏");
        final List<LiteStore.FavoriteEntry> list = LiteStore.getFavorites(this);
        if (list.isEmpty()) {
            status.setText("暂无收藏影片，可在影片详情页点击“加入收藏”。");
            button(
                    "返回首页",
                    new Runnable() {
                        public void run() {
                            home();
                        }
                    });
            return;
        }
        status.setText("共收藏 " + list.size() + " 部影片：");
        button(
                "清空收藏夹",
                new Runnable() {
                    public void run() {
                        LiteStore.clearFavorites(LiteActivity.this);
                        favoritesPage();
                    }
                });
        List<View> cards = new ArrayList<View>();
        for (int i = 0; i < list.size(); i++) {
            final LiteStore.FavoriteEntry f = list.get(i);
            cards.add(
                    createPosterCard(
                            f.vodName,
                            f.vodPic,
                            f.vodRemarks,
                            f.siteName,
                            Collections.<String, String>emptyMap(),
                            new Runnable() {
                                public void run() {
                                    openHistoryOrFavorite(
                                            f.siteKey, f.siteApi, f.siteName, f.vodId);
                                }
                            }));
        }
        addGridViews(page, cards, posterColumns(), -2);
    }

    void livePage() {
        livePage(0, 0);
    }

    void livePage(final int sourceIdx, final int groupIdx) {
        base("电视直播");
        final int id = epoch;
        String raw = getPreferences(0).getString("config", "");
        String baseAddr = getPreferences(0).getString("address", "");
        final List<LiteCatalog.LiveSource> liveSources = LiteCatalog.parseLives(raw, baseAddr);
        String customLiveUrl = getPreferences(0).getString("custom_live_url", "").trim();
        if (customLiveUrl.length() > 0) {
            LiteCatalog.LiveSource custom = new LiteCatalog.LiveSource();
            custom.name = "自定义直播源";
            custom.url = customLiveUrl;
            liveSources.add(0, custom);
        }
        button(
                "输入/更新直播源地址 (M3U / TXT)",
                new Runnable() {
                    public void run() {
                        importLiveUrlPage();
                    }
                });
        if (liveSources.isEmpty()) {
            status.setText("当前配置未包含直播列表，可点击上方输入 M3U 或 TXT 直播源地址。");
            return;
        }
        final int safeSourceIdx = Math.max(0, Math.min(sourceIdx, liveSources.size() - 1));
        if (liveSources.size() > 1) {
            HorizontalScrollView srcScroll = new HorizontalScrollView(this);
            LinearLayout srcRow = new LinearLayout(this);
            srcRow.setOrientation(LinearLayout.HORIZONTAL);
            srcScroll.addView(srcRow);
            page.addView(srcScroll);
            for (int i = 0; i < liveSources.size(); i++) {
                final int idx = i;
                addInteractiveChip(
                        srcRow,
                        liveSources.get(i).name,
                        i == safeSourceIdx,
                        new Runnable() {
                            public void run() {
                                livePage(idx, 0);
                            }
                        });
            }
        }
        final LiteCatalog.LiveSource activeSource = liveSources.get(safeSourceIdx);
        work(
                new Job() {
                    public void run() throws Exception {
                        final List<LiteCatalog.LiveGroup> groups =
                                LiteCatalog.fetchLiveGroups(activeSource);
                        ui.post(
                                new Runnable() {
                                    public void run() {
                                        if (dead || id != epoch) return;
                                        if (groups.isEmpty()) {
                                            status.setText("未能解析出有效直播频道。");
                                            return;
                                        }
                                        int safeGrp =
                                                Math.max(0, Math.min(groupIdx, groups.size() - 1));
                                        HorizontalScrollView grpScroll =
                                                new HorizontalScrollView(LiteActivity.this);
                                        LinearLayout grpRow = new LinearLayout(LiteActivity.this);
                                        grpRow.setOrientation(LinearLayout.HORIZONTAL);
                                        grpScroll.addView(grpRow);
                                        page.addView(grpScroll);
                                        for (int i = 0; i < groups.size(); i++) {
                                            final int gIdx = i;
                                            LiteCatalog.LiveGroup g = groups.get(i);
                                            addInteractiveChip(
                                                    grpRow,
                                                    g.name + " (" + g.channels.size() + ")",
                                                    i == safeGrp,
                                                    new Runnable() {
                                                        public void run() {
                                                            livePage(safeSourceIdx, gIdx);
                                                        }
                                                    });
                                        }
                                        final LiteCatalog.LiveGroup currentGrp =
                                                groups.get(safeGrp);
                                        status.setText(
                                                activeSource.name
                                                        + " · "
                                                        + currentGrp.name
                                                        + "（共 "
                                                        + currentGrp.channels.size()
                                                        + " 个频道 · 播放中可按上下键换台）");
                                        List<View> chBtns = new ArrayList<View>();
                                        for (int i = 0; i < currentGrp.channels.size(); i++) {
                                            final int chIdx = i;
                                            final LiteCatalog.LiveChannel ch =
                                                    currentGrp.channels.get(i);
                                            String label =
                                                    (i + 1)
                                                            + ". "
                                                            + ch.name
                                                            + (ch.urls.size() > 1
                                                                    ? " [" + ch.urls.size() + "源]"
                                                                    : "");
                                            chBtns.add(
                                                    makeActionButton(
                                                            label,
                                                            false,
                                                            new Runnable() {
                                                                public void run() {
                                                                    playLiveChannel(
                                                                            currentGrp, chIdx, 0,
                                                                            activeSource.headers);
                                                                }
                                                            }));
                                        }
                                        addGridViews(
                                                page,
                                                chBtns,
                                                isTvOrLandscape() ? 4 : 2,
                                                46);
                                    }
                                });
                    }
                });
    }

    void importLiveUrlPage() {
        base("自定义直播源地址");
        status.setText("请输入合法获取的 HTTP(S) M3U 或 TXT 直播源地址：");
        final EditText input = new EditText(this);
        input.setSingleLine();
        input.setTextColor(0xffffffff);
        input.setHint("https://…/live.m3u 或 live.txt");
        input.setText(getPreferences(0).getString("custom_live_url", ""));
        page.addView(input);
        button(
                "保存并打开直播",
                new Runnable() {
                    public void run() {
                        String u = input.getText().toString().trim();
                        if (u.length() > 0) {
                            try {
                                u = LiteCatalog.http(u);
                            } catch (Exception e) {
                                status.setText("请输入有效的 HTTP(S) 直播地址");
                                return;
                            }
                        }
                        getPreferences(0).edit().putString("custom_live_url", u).commit();
                        livePage();
                    }
                });
        button(
                "返回直播列表",
                new Runnable() {
                    public void run() {
                        livePage();
                    }
                });
    }

    void playLiveChannel(
            LiteCatalog.LiveGroup group,
            int channelIndex,
            int urlIndex,
            Map<String, String> sourceHeaders) {
        if (group == null || group.channels.isEmpty()) return;
        int safeCh =
                ((channelIndex % group.channels.size()) + group.channels.size())
                        % group.channels.size();
        LiteCatalog.LiveChannel ch = group.channels.get(safeCh);
        if (ch.urls.isEmpty()) return;
        int safeUrl = ((urlIndex % ch.urls.size()) + ch.urls.size()) % ch.urls.size();
        String url = ch.urls.get(safeUrl);
        Map<String, String> mergedHeaders = new LinkedHashMap<String, String>();
        if (sourceHeaders != null) mergedHeaders.putAll(sourceHeaders);
        mergedHeaders.putAll(ch.headers);
        String title =
                ch.name
                        + (ch.urls.size() > 1
                                ? " (源 " + (safeUrl + 1) + "/" + ch.urls.size() + ")"
                                : "");
        playingLiveGroup = group;
        playingLiveChannelIndex = safeCh;
        playingLiveUrlIndex = safeUrl;
        playResolved(url, url, title, mergedHeaders, null);
        playingLiveGroup = group;
        playingLiveChannelIndex = safeCh;
        playingLiveUrlIndex = safeUrl;
    }

    String sitePrefsKey() {
        String address = getPreferences(0).getString("address", "");
        try {
            address =
                    LiteCatalog.decodeConfig(getPreferences(0).getString("config", ""))
                            .optString(com.pilipala.source.Warehouse.ORIGIN, address);
        } catch (Exception ignored) {
        }
        String key = "site_edits:" + address;
        String legacy = "site_edits:" + getPreferences(0).getString("address", "");
        if (!key.equals(legacy)
                && !getPreferences(0).contains(key)
                && getPreferences(0).contains(legacy)) {
            if (!getPreferences(0)
                    .edit()
                    .putString(key, getPreferences(0).getString(legacy, "{}"))
                    .remove(legacy)
                    .commit()) return legacy;
        }
        return key;
    }

    void applySiteEdits() {
        try {
            JSONObject saved = new JSONObject(getPreferences(0).getString(sitePrefsKey(), "{}"));
            Map<String, LiteCatalog.Site> pending = new LinkedHashMap<String, LiteCatalog.Site>();
            for (LiteCatalog.Site site : sites) pending.put(site.key, site);
            JSONArray hidden = saved.optJSONArray("hidden"), order = saved.optJSONArray("order");
            if (hidden != null)
                for (int i = 0; i < hidden.length(); i++) pending.remove(hidden.optString(i));
            List<LiteCatalog.Site> result = new ArrayList<LiteCatalog.Site>();
            if (order != null)
                for (int i = 0; i < order.length(); i++) {
                    LiteCatalog.Site site = pending.remove(order.optString(i));
                    if (site != null) result.add(site);
                }
            result.addAll(pending.values());
            sites = result;
        } catch (JSONException ignored) {
        }
    }

    void manageSites() {
        base("管理线路");
        status.setText("选择片源可设为默认偏好源、调整顺序或隐藏不需要的线路：");
        List<View> btns = new ArrayList<View>();
        for (final LiteCatalog.Site site : sites) {
            btns.add(
                    makeActionButton(
                            site.name,
                            false,
                            new Runnable() {
                                public void run() {
                                    editSite(site);
                                }
                            }));
        }
        addGridViews(page, btns, siteColumns(), 46);
        button(
                "完成",
                new Runnable() {
                    public void run() {
                        home();
                    }
                });
    }

    void editSite(final LiteCatalog.Site site) {
        base(site.name);
        if (site.supported)
            button(
                    "设为默认偏好源 / 取消",
                    new Runnable() {
                        public void run() {
                            String identity = site.key + "\n" + site.api;
                            getPreferences(0)
                                    .edit()
                                    .putString(
                                            "preferred_site_identity",
                                            identity.equals(
                                                            getPreferences(0)
                                                                    .getString(
                                                                            "preferred_site_identity",
                                                                            ""))
                                                    ? ""
                                                    : identity)
                                    .commit();
                            home();
                        }
                    });
        String[] titles = {"上移", "下移", "移到首位", "删除这条线路"};
        for (int i = 0; i < titles.length; i++) {
            final int action = i;
            button(
                    titles[i],
                    new Runnable() {
                        public void run() {
                            if (action == 3) {
                                base("删除「" + site.name + "」？");
                                button(
                                        "删除",
                                        new Runnable() {
                                            public void run() {
                                                saveSiteEdit(site, 3);
                                            }
                                        });
                                button(
                                        "取消",
                                        new Runnable() {
                                            public void run() {
                                                manageSites();
                                            }
                                        });
                            } else saveSiteEdit(site, action);
                        }
                    });
        }
    }

    void saveSiteEdit(LiteCatalog.Site site, int action) {
        try {
            JSONObject data = new JSONObject(getPreferences(0).getString(sitePrefsKey(), "{}"));
            List<LiteCatalog.Site> nextSites = new ArrayList<LiteCatalog.Site>(sites);
            int index = nextSites.indexOf(site);
            if (index < 0) return;
            nextSites.remove(index);
            if (action == 3) {
                JSONArray hidden = data.optJSONArray("hidden");
                if (hidden == null) hidden = new JSONArray();
                data.put("hidden", hidden.put(site.key));
            } else
                nextSites.add(
                        action == 2
                                ? 0
                                : Math.max(
                                        0,
                                        Math.min(nextSites.size(), index + (action == 0 ? -1 : 1))),
                        site);
            JSONArray order = new JSONArray();
            for (LiteCatalog.Site s : nextSites) order.put(s.key);
            data.put("order", order);
            if (!getPreferences(0).edit().putString(sitePrefsKey(), data.toString()).commit()) {
                status.setText("线路变更未能保存，请重试");
                return;
            }
            sites = nextSites;
            manageSites();
        } catch (JSONException failed) {
            status.setText("无法保存线路");
        }
    }

    void importUrlPage() {
        base("输入配置地址");
        button(
                "连接 Emby 媒体库",
                new Runnable() {
                    public void run() {
                        com.pilipala.emby.EmbyAccounts.connect(
                                LiteActivity.this,
                                new com.pilipala.emby.EmbyAccounts.OnConnected() {
                                    public void save(JSONObject site) throws Exception {
                                        JSONObject libraries =
                                                new JSONObject(
                                                        getPreferences(0)
                                                                .getString("emby_libraries", "{}"));
                                        libraries.put(site.getString("key"), site);
                                        if (!getPreferences(0)
                                                .edit()
                                                .putString("emby_libraries", libraries.toString())
                                                .commit())
                                            throw new java.io.IOException("无法保存 Emby 来源");
                                        home();
                                    }
                                });
                    }
                });
        status.setText("请输入合法获取的 HTTP(S) JSON / 多仓配置地址：");
        final EditText input = new EditText(this);
        input.setSingleLine();
        input.setTextColor(0xffffffff);
        input.setHint("https://…/config.json");
        input.setText(getPreferences(0).getString("address", ""));
        page.addView(input);
        button(
                "导入并保存配置",
                new Runnable() {
                    public void run() {
                        final String addr = input.getText().toString().trim();
                        if (addr.length() == 0) {
                            status.setText("请输入有效的 HTTP(S) 配置地址");
                            return;
                        }
                        work(
                                new Job() {
                                    public void run() throws Exception {
                                        if (com.pilipala.emby.CheckedScript.matches(addr)) {
                                            com.pilipala.emby.CheckedScript.read(addr);
                                            throw new java.io.IOException(
                                                    "脚本校验通过，轻量版需要标准版的脚本运行环境");
                                        }
                                        final String normalized = LiteCatalog.http(addr);
                                        final String raw =
                                                LiteCatalog.importConfig(
                                                        LiteCatalog.fetch(normalized, null),
                                                        normalized);
                                        LiteCatalog.parse(raw, normalized);
                                        synchronized (importLock) {
                                            getPreferences(0)
                                                    .edit()
                                                    .putString("address", normalized)
                                                    .putString("config", raw)
                                                    .commit();
                                        }
                                        ui.post(
                                                new Runnable() {
                                                    public void run() {
                                                        if (!dead) home();
                                                    }
                                                });
                                    }
                                });
                    }
                });
        button(
                "返回片库",
                new Runnable() {
                    public void run() {
                        home();
                    }
                });
    }

    void warehousePage() {
        base("切换子仓库");
        final String previous = getPreferences(0).getString("config", "");
        try {
            JSONArray rows =
                    LiteCatalog.decodeConfig(previous)
                            .getJSONArray(com.pilipala.source.Warehouse.DEPOTS);
            List<View> btns = new ArrayList<View>();
            for (int i = 0; i < rows.length(); i++) {
                JSONObject row = rows.getJSONObject(i);
                final String address = row.getString("url");
                btns.add(
                        makeActionButton(
                                row.optString("name"),
                                false,
                                new Runnable() {
                                    public void run() {
                                        work(
                                                new Job() {
                                                    public void run() throws Exception {
                                                        String selectedRaw =
                                                                LiteCatalog.importConfig(
                                                                        LiteCatalog.fetch(
                                                                                address, null),
                                                                        address);
                                                        String combined =
                                                                com.pilipala.source.Warehouse
                                                                        .retainDirectory(
                                                                                selectedRaw,
                                                                                address,
                                                                                previous,
                                                                                new com.pilipala
                                                                                        .source
                                                                                        .Warehouse
                                                                                        .Decoder() {
                                                                                    public JSONObject
                                                                                            decode(
                                                                                                    String
                                                                                                            text)
                                                                                                    throws Exception {
                                                                                        return LiteCatalog
                                                                                                .decodeConfig(
                                                                                                        text);
                                                                                    }
                                                                                });
                                                        LiteCatalog.parse(combined, address);
                                                        synchronized (importLock) {
                                                            if (!previous.equals(
                                                                    getPreferences(0)
                                                                            .getString(
                                                                                    "config", "")))
                                                                return;
                                                            if (!getPreferences(0)
                                                                    .edit()
                                                                    .putString("config", combined)
                                                                    .putString(
                                                                            "address",
                                                                            LiteCatalog.decodeConfig(
                                                                                            combined)
                                                                                    .optString(
                                                                                            com.pilipala
                                                                                                    .source
                                                                                                    .Warehouse
                                                                                                    .ROOT,
                                                                                            address))
                                                                    .commit())
                                                                throw new java.io.IOException(
                                                                        "保存失败");
                                                        }
                                                        ui.post(
                                                                new Runnable() {
                                                                    public void run() {
                                                                        if (!dead) home();
                                                                    }
                                                                });
                                                    }
                                                });
                                    }
                                }));
            }
            addGridViews(page, btns, siteColumns(), 46);
        } catch (Exception e) {
            status.setText("无法读取仓库目录，请重新导入");
        }
        button(
                "返回片库",
                new Runnable() {
                    public void run() {
                        home();
                    }
                });
    }

    void configure() {
        base("手机扫码配置");
        final int session = epoch;
        status.setText("手机与电视连接同一局域网扫码推送配置；配置只保存在本机。");
        try {
            pairing =
                    new ConfigServer(
                            new ConfigServer.Importer() {
                                public void apply(String address) throws Exception {
                                    String raw =
                                            LiteCatalog.importConfig(
                                                    LiteCatalog.fetch(address, null), address);
                                    LiteCatalog.parse(raw, address);
                                    synchronized (importLock) {
                                        if (dead || pairing == null || epoch != session)
                                            throw new java.io.IOException();
                                        if (!getPreferences(0)
                                                .edit()
                                                .putString("address", address)
                                                .putString("config", raw)
                                                .commit()) throw new java.io.IOException();
                                    }
                                    ui.post(
                                            new Runnable() {
                                                public void run() {
                                                    if (pairing != null)
                                                        status.setText("配置已保存，点击“返回片库”选择片源。");
                                                }
                                            });
                                }
                            });
            String host = null;
            Enumeration<NetworkInterface> nets = NetworkInterface.getNetworkInterfaces();
            while (nets.hasMoreElements()) {
                Enumeration<InetAddress> addresses = nets.nextElement().getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress a = addresses.nextElement();
                    if (a instanceof Inet4Address
                            && !a.isLoopbackAddress()
                            && a.isSiteLocalAddress()) host = a.getHostAddress();
                }
            }
            if (host == null) throw new java.io.IOException();
            String url = "http://" + host + ":" + pairing.port() + "/" + pairing.token;
            BitMatrix matrix =
                    new MultiFormatWriter().encode(url, BarcodeFormat.QR_CODE, 320, 320);
            Bitmap bitmap = Bitmap.createBitmap(320, 320, Bitmap.Config.RGB_565);
            for (int y = 0; y < 320; y++)
                for (int x = 0; x < 320; x++)
                    bitmap.setPixel(x, y, matrix.get(x, y) ? 0xff000000 : 0xffffffff);
            ImageView qr = new ImageView(this);
            qr.setImageBitmap(bitmap);
            page.addView(qr, new LinearLayout.LayoutParams(dp(220), dp(220)));
            page.addView(text(url, 14));
        } catch (Throwable failure) {
            closePairing();
            status.setText("请先连接局域网，或点击下方直接输入配置地址。");
        }
        button(
                "直接输入配置地址",
                new Runnable() {
                    public void run() {
                        importUrlPage();
                    }
                });
        button(
                "返回片库",
                new Runnable() {
                    public void run() {
                        home();
                    }
                });
    }

    void catalog(final String keyword, final int number) {
        catalog(keyword, "", number);
    }

    void catalog(final String keyword, final String categoryId, final int number) {
        inDetail = false;
        lastQuery = keyword;
        lastCategory = categoryId;
        lastPage = number;
        if (selected == null) {
            loadConfiguredSites();
            if (selected == null) {
                home();
                return;
            }
        }
        base(selected.name);
        final int id = epoch;
        final LiteCatalog.Site site = selected;

        LinearLayout actionRow = new LinearLayout(this);
        actionRow.setOrientation(LinearLayout.HORIZONTAL);
        List<View> topActions = new ArrayList<View>();
        topActions.add(
                makeActionButton(
                        "搜索此来源",
                        false,
                        new Runnable() {
                            public void run() {
                                search();
                            }
                        }));
        topActions.add(
                makeActionButton(
                        "切换片源",
                        false,
                        new Runnable() {
                            public void run() {
                                home();
                            }
                        }));
        if (keyword != null && keyword.length() > 0) {
            topActions.add(
                    makeActionButton(
                            "清除搜索：「" + truncate(keyword, 6) + "」",
                            true,
                            new Runnable() {
                                public void run() {
                                    catalog("", "", 1);
                                }
                            }));
        }
        addGridViews(page, topActions, topActions.size(), 42);

        showCategories(keyword, categoryId);
        work(
                new Job() {
                    public void run() throws Exception {
                        List<LiteCatalog.Category> loadedCategories = categories;
                        com.pilipala.emby.EmbyLibrary emby =
                                site.api.startsWith("emby://account/")
                                        ? com.pilipala.emby.EmbyAccounts.open(
                                                LiteActivity.this, site.api)
                                        : null;
                        if (categories.isEmpty()
                                && keyword.length() == 0
                                && categoryId.length() == 0
                                && number == 1) {
                            try {
                                String homeRaw =
                                        emby != null
                                                ? emby.home().toString()
                                                : LiteCatalog.fetch(
                                                        LiteCatalog.query(site.api, "ac", "list"),
                                                        site.headers);
                                List<LiteCatalog.Category> parsedCats =
                                        LiteCatalog.categories(homeRaw);
                                if (!parsedCats.isEmpty()) loadedCategories = parsedCats;
                            } catch (Throwable ignored) {
                            }
                        }
                        String url =
                                emby != null
                                        ? ""
                                        : categoryId.length() > 0
                                                ? LiteCatalog.query(
                                                        site.api,
                                                        "ac",
                                                        "detail",
                                                        "pg",
                                                        "" + number,
                                                        "t",
                                                        categoryId)
                                                : LiteCatalog.query(
                                                        site.api,
                                                        "ac",
                                                        "detail",
                                                        "pg",
                                                        "" + number,
                                                        "wd",
                                                        keyword);
                        final JSONObject response =
                                emby != null
                                        ? emby.list(categoryId, keyword, number)
                                        : LiteCatalog.parseCmsResponse(
                                                LiteCatalog.fetch(url, site.headers));
                        final List<LiteCatalog.Category> fetchedCategories = loadedCategories;
                        final JSONArray list = response.optJSONArray("list");
                        if (list == null) throw new java.io.IOException();
                        final int pageCount = Math.max(1, response.optInt("pagecount", 1));
                        ui.post(
                                new Runnable() {
                                    public void run() {
                                        getPreferences(0)
                                                .edit()
                                                .putString("loading_site", "")
                                                .commit();
                                        if (dead || id != epoch) return;
                                        categories = fetchedCategories;
                                        showCategories(keyword, categoryId);

                                        status.setText(
                                                list.length() == 0
                                                        ? "没有结果"
                                                        : "第 "
                                                                + number
                                                                + " / "
                                                                + pageCount
                                                                + " 页（共 "
                                                                + list.length()
                                                                + " 项）");
                                        List<View> cards = new ArrayList<View>();
                                        for (int i = 0; i < Math.min(list.length(), 60); i++) {
                                            final JSONObject video = list.optJSONObject(i);
                                            if (video == null) continue;
                                            final String vodId = video.optString("vod_id");
                                            String vodName = video.optString("vod_name", "未命名");
                                            String vodPic = video.optString("vod_pic", "");
                                            String vodRemarks = video.optString("vod_remarks", "");
                                            String vodYear = video.optString("vod_year", "");
                                            cards.add(
                                                    createPosterCard(
                                                            vodName,
                                                            vodPic,
                                                            vodRemarks,
                                                            vodYear,
                                                            site.headers,
                                                            new Runnable() {
                                                                public void run() {
                                                                    detail(vodId);
                                                                }
                                                            }));
                                        }
                                        addGridViews(page, cards, posterColumns(), -2);

                                        List<View> pagerBtns = new ArrayList<View>();
                                        if (number > 1) {
                                            pagerBtns.add(
                                                    makeActionButton(
                                                            "上一页",
                                                            false,
                                                            new Runnable() {
                                                                public void run() {
                                                                    catalog(
                                                                            keyword,
                                                                            categoryId,
                                                                            number - 1);
                                                                }
                                                            }));
                                        }
                                        if (number < pageCount) {
                                            pagerBtns.add(
                                                    makeActionButton(
                                                            "下一页",
                                                            true,
                                                            new Runnable() {
                                                                public void run() {
                                                                    catalog(
                                                                            keyword,
                                                                            categoryId,
                                                                            number + 1);
                                                                }
                                                            }));
                                        }
                                        if (cards.size() > 8) {
                                            pagerBtns.add(
                                                    makeActionButton(
                                                            "返回顶部",
                                                            false,
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (mainScroll != null)
                                                                        mainScroll.fullScroll(
                                                                                View.FOCUS_UP);
                                                                }
                                                            }));
                                        }
                                        if (!pagerBtns.isEmpty()) {
                                            addGridViews(page, pagerBtns, pagerBtns.size(), 46);
                                        }
                                    }
                                });
                    }
                });
    }

    @SuppressWarnings("deprecation")
    View createPosterCard(
            String title,
            String picUrl,
            String remarks,
            String subInfo,
            Map<String, String> headers,
            final Runnable onClick) {
        final LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setFocusable(true);
        card.setClickable(true);
        card.setPadding(dp(6), dp(6), dp(6), dp(8));
        styleCard(card, false);

        int cols = posterColumns();
        int cardWidthPx =
                Math.max(
                        dp(110),
                        (getResources().getDisplayMetrics().widthPixels - dp(64)) / cols);
        int posterHeightPx = (int) (cardWidthPx * 1.32f);

        FrameLayout posterFrame = new FrameLayout(this);
        GradientDrawable posterBg = new GradientDrawable();
        posterBg.setColor(COLOR_CARD_SUBTLE);
        posterBg.setCornerRadius(dp(8));
        posterFrame.setBackgroundDrawable(posterBg);

        TextView placeholder = text(truncate(title, 4), 13);
        placeholder.setTextColor(0xff525466);
        placeholder.setGravity(Gravity.CENTER);
        posterFrame.addView(placeholder, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        ImageView img = new ImageView(this);
        img.setScaleType(ImageView.ScaleType.CENTER_CROP);
        posterFrame.addView(img, new FrameLayout.LayoutParams(-1, -1));
        LiteImageLoader.load(this, img, picUrl, headers, cardWidthPx, posterHeightPx);

        if (remarks != null && remarks.trim().length() > 0) {
            TextView badge = text( truncate(remarks.trim(), 10), 11);
            badge.setPadding(dp(6), dp(2), dp(6), dp(2));
            badge.setTextColor(0xffffffff);
            GradientDrawable badgeBg = new GradientDrawable();
            badgeBg.setColor(0xcc101013);
            badgeBg.setCornerRadius(dp(6));
            badge.setBackgroundDrawable(badgeBg);
            FrameLayout.LayoutParams blp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.RIGHT);
            blp.setMargins(dp(4), dp(4), dp(4), dp(4));
            posterFrame.addView(badge, blp);
        }

        card.addView(posterFrame, new LinearLayout.LayoutParams(-1, posterHeightPx));

        TextView nameView = text(title, 15);
        nameView.setPadding(dp(4), dp(6), dp(4), dp(2));
        nameView.setSingleLine(true);
        nameView.setEllipsize(TextUtils.TruncateAt.END);
        nameView.setTypeface(null, Typeface.BOLD);
        card.addView(nameView, new LinearLayout.LayoutParams(-1, -2));

        if (subInfo != null && subInfo.trim().length() > 0) {
            TextView subView = text(subInfo.trim(), 12);
            subView.setPadding(dp(4), 0, dp(4), 0);
            subView.setTextColor(COLOR_MUTED);
            subView.setSingleLine(true);
            subView.setEllipsize(TextUtils.TruncateAt.END);
            card.addView(subView, new LinearLayout.LayoutParams(-1, -2));
        }

        card.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        styleCard(card, focus);
                    }
                });
        card.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        onClick.run();
                    }
                });
        return card;
    }

    void showCategories(String keyword, String categoryId) {
        if (!categories.isEmpty()
                && keyword.length() == 0
                && page.findViewWithTag("source-categories") == null) {
            HorizontalScrollView catScroll = new HorizontalScrollView(this);
            catScroll.setHorizontalScrollBarEnabled(false);
            LinearLayout catRow = new LinearLayout(this);
            catRow.setOrientation(LinearLayout.HORIZONTAL);
            catScroll.setTag("source-categories");
            catScroll.addView(catRow);
            page.addView(catScroll);
            addCategoryChip(catRow, "全部", "", categoryId.length() == 0);
            for (int i = 0; i < Math.min(categories.size(), 25); i++) {
                final LiteCatalog.Category c = categories.get(i);
                addCategoryChip(catRow, c.name, c.id, c.id.equals(categoryId));
            }
        }
    }

    void addCategoryChip(
            LinearLayout row, String label, final String catId, final boolean active) {
        addInteractiveChip(
                row,
                label,
                active,
                new Runnable() {
                    public void run() {
                        catalog("", catId, 1);
                    }
                });
    }

    void addInteractiveChip(
            LinearLayout row, String label, final boolean active, final Runnable action) {
        final TextView chip = text(label, 14);
        chip.setPadding(dp(12), dp(6), dp(12), dp(6));
        chip.setFocusable(true);
        chip.setClickable(true);
        chip.setSingleLine(true);
        styleChip(chip, active, false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(38));
        lp.setMargins(dp(4), dp(4), dp(4), dp(4));
        chip.setGravity(Gravity.CENTER);
        chip.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        styleChip(chip, active, focus);
                    }
                });
        chip.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        action.run();
                    }
                });
        row.addView(chip, lp);
    }

    void search() {
        loadConfiguredSites();
        String title = selected != null ? "搜索 · " + selected.name : "全站搜索";
        base(title);
        status.setText("支持遥控器点击屏幕字母/数字键输入，或点击输入框调起系统输入法：");

        final EditText input = new EditText(this);
        input.setSingleLine();
        input.setTextColor(0xffffffff);
        input.setHint("输入片名关键词或拼音首字母…");
        input.setText(lastQuery);
        page.addView(input);

        List<View> searchActions = new ArrayList<View>();
        if (selected != null && selected.supported) {
            searchActions.add(
                    makeActionButton(
                            "搜索当前源",
                            true,
                            new Runnable() {
                                public void run() {
                                    String kw = input.getText().toString().trim();
                                    if (kw.length() > 0) {
                                        LiteStore.addSearchKeyword(LiteActivity.this, kw);
                                    }
                                    catalog(kw, 1);
                                }
                            }));
        }
        searchActions.add(
                makeActionButton(
                        "全站聚合搜索",
                        selected == null,
                        new Runnable() {
                            public void run() {
                                String kw = input.getText().toString().trim();
                                if (kw.length() == 0) {
                                    status.setText("请输入搜索关键词");
                                    return;
                                }
                                LiteStore.addSearchKeyword(LiteActivity.this, kw);
                                globalSearch(kw);
                            }
                        }));
        searchActions.add(
                makeActionButton(
                        "退格 ⌫",
                        false,
                        new Runnable() {
                            public void run() {
                                String s = input.getText().toString();
                                if (s.length() > 0) {
                                    input.setText(s.substring(0, s.length() - 1));
                                    input.setSelection(input.getText().length());
                                }
                            }
                        }));
        searchActions.add(
                makeActionButton(
                        "清空",
                        false,
                        new Runnable() {
                            public void run() {
                                input.setText("");
                            }
                        }));
        addGridViews(page, searchActions, isTvOrLandscape() ? 4 : 2, 44);

        addSectionHeader("遥控器快捷键盘");
        String keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        List<View> keyBtns = new ArrayList<View>();
        for (int i = 0; i < keys.length(); i++) {
            final String ch = String.valueOf(keys.charAt(i));
            keyBtns.add(
                    makeActionButton(
                            ch,
                            false,
                            new Runnable() {
                                public void run() {
                                    input.setText(input.getText().toString() + ch);
                                    input.setSelection(input.getText().length());
                                }
                            }));
        }
        addGridViews(page, keyBtns, isTvOrLandscape() ? 9 : 6, 40);

        List<String> history = LiteStore.getSearchHistory(this);
        if (!history.isEmpty()) {
            addSectionHeader("历史搜索");
            HorizontalScrollView histScroll = new HorizontalScrollView(this);
            LinearLayout histRow = new LinearLayout(this);
            histRow.setOrientation(LinearLayout.HORIZONTAL);
            histScroll.addView(histRow);
            page.addView(histScroll);
            for (int i = 0; i < history.size(); i++) {
                final String kw = history.get(i);
                addInteractiveChip(
                        histRow,
                        kw,
                        false,
                        new Runnable() {
                            public void run() {
                                input.setText(kw);
                                if (selected != null && selected.supported) catalog(kw, 1);
                                else globalSearch(kw);
                            }
                        });
            }
            addInteractiveChip(
                    histRow,
                    "清空历史",
                    false,
                    new Runnable() {
                        public void run() {
                            LiteStore.clearSearchHistory(LiteActivity.this);
                            search();
                        }
                    });
        }
    }

    void globalSearch(final String keyword) {
        loadConfiguredSites();
        base("全站搜索 · " + keyword);
        final int id = epoch;
        final List<LiteCatalog.Site> searchableSites = new ArrayList<LiteCatalog.Site>();
        for (int i = 0; i < sites.size() && searchableSites.size() < 12; i++) {
            LiteCatalog.Site s = sites.get(i);
            if (s.supported && s.searchable && !s.api.startsWith("emby://")) {
                searchableSites.add(s);
            }
        }
        if (searchableSites.isEmpty()) {
            status.setText("没有可聚合检索的标准片源，请先导入配置。");
            return;
        }
        work(
                new Job() {
                    public void run() throws Exception {
                        final List<JSONObject> merged = new ArrayList<JSONObject>();
                        final List<LiteCatalog.Site> matchedSites =
                                new ArrayList<LiteCatalog.Site>();
                        for (int i = 0; i < searchableSites.size(); i++) {
                            if (dead || id != epoch || Thread.currentThread().isInterrupted())
                                return;
                            LiteCatalog.Site s = searchableSites.get(i);
                            try {
                                String u =
                                        LiteCatalog.query(
                                                s.api, "ac", "detail", "pg", "1", "wd", keyword);
                                JSONObject resp =
                                        LiteCatalog.parseCmsResponse(
                                                LiteCatalog.fetch(u, s.headers));
                                JSONArray arr = resp.optJSONArray("list");
                                if (arr != null) {
                                    for (int j = 0; j < Math.min(arr.length(), 8); j++) {
                                        JSONObject v = arr.optJSONObject(j);
                                        if (v != null && v.optString("vod_id").length() > 0) {
                                            merged.add(v);
                                            matchedSites.add(s);
                                        }
                                    }
                                }
                            } catch (Throwable ignored) {
                            }
                        }
                        ui.post(
                                new Runnable() {
                                    public void run() {
                                        if (dead || id != epoch) return;
                                        status.setText(
                                                merged.isEmpty()
                                                        ? "未检索到「" + keyword + "」相关结果"
                                                        : "检索了 "
                                                                + searchableSites.size()
                                                                + " 个片源，共找到 "
                                                                + merged.size()
                                                                + " 条结果：");
                                        List<View> cards = new ArrayList<View>();
                                        for (int i = 0; i < merged.size(); i++) {
                                            final JSONObject v = merged.get(i);
                                            final LiteCatalog.Site s = matchedSites.get(i);
                                            cards.add(
                                                    createPosterCard(
                                                            v.optString("vod_name", "未命名"),
                                                            v.optString("vod_pic", ""),
                                                            v.optString("vod_remarks", ""),
                                                            "来源：" + s.name,
                                                            s.headers,
                                                            new Runnable() {
                                                                public void run() {
                                                                    selected = s;
                                                                    detail(v.optString("vod_id"));
                                                                }
                                                            }));
                                        }
                                        addGridViews(page, cards, posterColumns(), -2);
                                    }
                                });
                    }
                });
    }

    void detail(final String videoId) {
        base("影片详情");
        final int id = epoch;
        final LiteCatalog.Site site = selected;
        work(
                new Job() {
                    public void run() throws Exception {
                        final JSONObject video =
                                site.api.startsWith("emby://account/")
                                        ? com.pilipala.emby.EmbyAccounts.open(
                                                        LiteActivity.this, site.api)
                                                .detail(videoId)
                                                .getJSONArray("list")
                                                .getJSONObject(0)
                                        : LiteCatalog.list(
                                                        LiteCatalog.fetch(
                                                                LiteCatalog.query(
                                                                        site.api,
                                                                        "ac",
                                                                        "detail",
                                                                        "ids",
                                                                        videoId),
                                                                site.headers))
                                                .getJSONObject(0);
                        ui.post(
                                new Runnable() {
                                    public void run() {
                                        if (!dead && epoch == id) {
                                            activeDetailLine = 0;
                                            activeEpisodeGroup = 0;
                                            episodeReversed = false;
                                            showDetail(video);
                                        }
                                    }
                                });
                    }
                });
    }

    @SuppressWarnings("deprecation")
    void showDetail(final JSONObject video) {
        inDetail = true;
        final String vodName = video.optString("vod_name", "影片详情");
        base(vodName);
        currentDetail = video;

        final String vodId = video.optString("vod_id", "");
        final String vodPic = video.optString("vod_pic", "");
        final String vodRemarks = video.optString("vod_remarks", "");
        final String siteKey = selected != null ? selected.key : "";
        final String siteName = selected != null ? selected.name : "";
        final String siteApi = selected != null ? selected.api : "";
        final String cleanDesc =
                android.text.Html.fromHtml(video.optString("vod_content", "暂无简介"))
                        .toString()
                        .trim();
        status.setText(cleanDesc.length() > 0 ? cleanDesc : "暂无简介");
        status.setMaxLines(3);
        status.setEllipsize(TextUtils.TruncateAt.END);

        String[] rawLines = video.optString("vod_play_url").split("\\$\\$\\$");
        String[] rawNames = video.optString("vod_play_from").split("\\$\\$\\$");
        final String[] lines = new String[rawLines.length];
        final String[] names = new String[rawLines.length];
        for (int i = 0; i < rawLines.length; i++) {
            lines[i] = rawLines[i];
            names[i] =
                    i < rawNames.length && rawNames[i].trim().length() > 0
                            ? rawNames[i].trim()
                            : ("线路 " + (i + 1));
        }

        String preferredLine = getPreferences(0).getString("preferred_line", "");
        for (int n = 0; n < lines.length; n++) {
            if (names[n].equals(preferredLine)) {
                String oldName = names[0], oldLine = lines[0];
                names[0] = names[n];
                lines[0] = lines[n];
                names[n] = oldName;
                lines[n] = oldLine;
                break;
            }
        }

        final LiteStore.HistoryEntry savedHist = LiteStore.findHistory(this, siteKey, vodId);
        if (savedHist != null && activeDetailLine == 0 && savedHist.lineName.length() > 0) {
            for (int n = 0; n < names.length; n++) {
                if (names[n].equals(savedHist.lineName)) {
                    activeDetailLine = n;
                    break;
                }
            }
        }
        if (activeDetailLine < 0 || activeDetailLine >= lines.length) activeDetailLine = 0;

        currentLineEpisodes = parseLineEpisodes(lines.length > 0 ? lines[activeDetailLine] : "");

        LinearLayout heroRow = new LinearLayout(this);
        heroRow.setOrientation(
                isTvOrLandscape() ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        heroRow.setPadding(0, dp(4), 0, dp(8));

        if (vodPic.length() > 0) {
            FrameLayout posterBox = new FrameLayout(this);
            GradientDrawable pBg = new GradientDrawable();
            pBg.setColor(COLOR_CARD);
            pBg.setCornerRadius(dp(10));
            pBg.setStroke(dp(1), COLOR_BORDER);
            posterBox.setBackgroundDrawable(pBg);
            ImageView posterImg = new ImageView(this);
            posterImg.setScaleType(ImageView.ScaleType.CENTER_CROP);
            posterBox.addView(posterImg, new FrameLayout.LayoutParams(-1, -1));
            int pw = dp(136), ph = dp(188);
            LiteImageLoader.load(
                    this,
                    posterImg,
                    vodPic,
                    selected != null ? selected.headers : Collections.<String, String>emptyMap(),
                    pw,
                    ph);
            LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(pw, ph);
            plp.setMargins(0, 0, dp(16), dp(8));
            heroRow.addView(posterBox, plp);
        }

        LinearLayout metaCol = new LinearLayout(this);
        metaCol.setOrientation(LinearLayout.VERTICAL);
        StringBuilder metaLine = new StringBuilder();
        appendMeta(metaLine, video.optString("vod_year", ""));
        appendMeta(metaLine, video.optString("vod_area", ""));
        appendMeta(metaLine, video.optString("type_name", video.optString("vod_class", "")));
        appendMeta(metaLine, vodRemarks);
        if (metaLine.length() > 0) {
            TextView metaView = text(metaLine.toString(), 14);
            metaView.setTextColor(0xff64d2ff);
            metaView.setPadding(dp(4), dp(2), dp(4), dp(2));
            metaCol.addView(metaView);
        }
        String actor = video.optString("vod_actor", "").trim();
        String director = video.optString("vod_director", "").trim();
        if (actor.length() > 0 || director.length() > 0) {
            String credits =
                    (director.length() > 0 ? "导演：" + director + "   " : "")
                            + (actor.length() > 0 ? "主演：" + actor : "");
            TextView creditView = text(credits, 13);
            creditView.setTextColor(COLOR_MUTED);
            creditView.setMaxLines(2);
            creditView.setEllipsize(TextUtils.TruncateAt.END);
            creditView.setPadding(dp(4), dp(2), dp(4), dp(4));
            metaCol.addView(creditView);
        }

        List<View> detailActions = new ArrayList<View>();
        if (!currentLineEpisodes.isEmpty()) {
            EpisodeItem targetEp = currentLineEpisodes.get(0);
            String playLabel = "▶ 立即播放 · " + targetEp.name;
            if (savedHist != null && savedHist.epUrl.length() > 0) {
                for (int i = 0; i < currentLineEpisodes.size(); i++) {
                    EpisodeItem cand = currentLineEpisodes.get(i);
                    if (cand.url.equals(savedHist.epUrl) || cand.name.equals(savedHist.epName)) {
                        targetEp = cand;
                        playLabel =
                                "▶ 续播 · "
                                        + cand.name
                                        + (savedHist.positionMs > 0
                                                ? " (" + formatTime(savedHist.positionMs) + ")"
                                                : "");
                        break;
                    }
                }
            }
            final EpisodeItem resumeEp = targetEp;
            detailActions.add(
                    makeActionButton(
                            playLabel,
                            true,
                            new Runnable() {
                                public void run() {
                                    playingEpisodeIndex = resumeEp.originalIndex;
                                    play(resumeEp.url, resumeEp.name);
                                }
                            }));
        }
        final boolean isFav = LiteStore.isFavorite(this, siteKey, vodId);
        detailActions.add(
                makeActionButton(
                        isFav ? "★ 已收藏" : "♡ 加入收藏",
                        isFav,
                        new Runnable() {
                            public void run() {
                                LiteStore.FavoriteEntry entry = new LiteStore.FavoriteEntry();
                                entry.siteKey = siteKey;
                                entry.siteName = siteName;
                                entry.siteApi = siteApi;
                                entry.vodId = vodId;
                                entry.vodName = vodName;
                                entry.vodPic = vodPic;
                                entry.vodRemarks = vodRemarks;
                                LiteStore.toggleFavorite(LiteActivity.this, entry);
                                showDetail(video);
                            }
                        }));
        detailActions.add(
                makeActionButton(
                        episodeReversed ? "⇅ 倒序排列" : "⇅ 正序排列",
                        false,
                        new Runnable() {
                            public void run() {
                                episodeReversed = !episodeReversed;
                                activeEpisodeGroup = 0;
                                showDetail(video);
                            }
                        }));
        detailActions.add(
                makeActionButton(
                        "默认播放线路",
                        false,
                        new Runnable() {
                            public void run() {
                                String[] options = new String[names.length + 1];
                                options[0] = "自动选择";
                                System.arraycopy(names, 0, options, 1, names.length);
                                new AlertDialog.Builder(LiteActivity.this)
                                        .setTitle("默认播放线路")
                                        .setItems(
                                                options,
                                                new DialogInterface.OnClickListener() {
                                                    public void onClick(
                                                            DialogInterface d, int which) {
                                                        getPreferences(0)
                                                                .edit()
                                                                .putString(
                                                                        "preferred_line",
                                                                        which == 0
                                                                                ? ""
                                                                                : names[which - 1])
                                                                .commit();
                                                        activeDetailLine = 0;
                                                        showDetail(video);
                                                    }
                                                })
                                        .show();
                            }
                        }));
        detailActions.add(
                makeActionButton(
                        "跨源换源",
                        false,
                        new Runnable() {
                            public void run() {
                                globalSearch(vodName);
                            }
                        }));
        addGridViews(metaCol, detailActions, isTvOrLandscape() ? 3 : 2, 44);
        heroRow.addView(metaCol, new LinearLayout.LayoutParams(-1, -2));
        page.addView(heroRow, new LinearLayout.LayoutParams(-1, -2));

        if (lines.length > 1) {
            addSectionHeader("播放线路（共 " + lines.length + " 条）");
            HorizontalScrollView lineScroll = new HorizontalScrollView(this);
            lineScroll.setHorizontalScrollBarEnabled(false);
            LinearLayout lineRow = new LinearLayout(this);
            lineRow.setOrientation(LinearLayout.HORIZONTAL);
            lineScroll.addView(lineRow);
            page.addView(lineScroll);
            for (int i = 0; i < lines.length; i++) {
                final int lineIdx = i;
                int epCount = countEpisodes(lines[i]);
                addInteractiveChip(
                        lineRow,
                        names[i] + " (" + epCount + ")",
                        i == activeDetailLine,
                        new Runnable() {
                            public void run() {
                                activeDetailLine = lineIdx;
                                activeEpisodeGroup = 0;
                                showDetail(video);
                            }
                        });
            }
        } else if (lines.length == 1) {
            addSectionHeader(names[0] + "（共 " + currentLineEpisodes.size() + " 集）");
        }

        List<EpisodeItem> ordered = new ArrayList<EpisodeItem>(currentLineEpisodes);
        if (episodeReversed) {
            Collections.reverse(ordered);
        }

        int totalEps = ordered.size();
        int groupCount =
                totalEps == 0
                        ? 0
                        : (totalEps + EPISODE_GROUP_SIZE - 1) / EPISODE_GROUP_SIZE;
        if (activeEpisodeGroup < 0 || activeEpisodeGroup >= groupCount) activeEpisodeGroup = 0;

        if (groupCount > 1) {
            HorizontalScrollView grpScroll = new HorizontalScrollView(this);
            grpScroll.setHorizontalScrollBarEnabled(false);
            LinearLayout grpRow = new LinearLayout(this);
            grpRow.setOrientation(LinearLayout.HORIZONTAL);
            grpScroll.addView(grpRow);
            page.addView(grpScroll);
            for (int g = 0; g < groupCount; g++) {
                final int grpIdx = g;
                int start = g * EPISODE_GROUP_SIZE + 1;
                int end = Math.min(totalEps, (g + 1) * EPISODE_GROUP_SIZE);
                String rangeLabel = start + "-" + end + "集";
                addInteractiveChip(
                        grpRow,
                        rangeLabel,
                        g == activeEpisodeGroup,
                        new Runnable() {
                            public void run() {
                                activeEpisodeGroup = grpIdx;
                                showDetail(video);
                            }
                        });
            }
        }

        int startIdx = activeEpisodeGroup * EPISODE_GROUP_SIZE;
        int endIdx = Math.min(totalEps, startIdx + EPISODE_GROUP_SIZE);
        List<EpisodeItem> visibleSlice =
                totalEps > 0 ? ordered.subList(startIdx, endIdx) : Collections.<EpisodeItem>emptyList();
        List<View> epButtons = new ArrayList<View>();
        for (int i = 0; i < visibleSlice.size(); i++) {
            final EpisodeItem ep = visibleSlice.get(i);
            boolean watched =
                    savedHist != null
                            && (ep.url.equals(savedHist.epUrl)
                                    || ep.name.equals(savedHist.epName));
            String btnText = (watched ? "▶ " : "") + ep.name;
            epButtons.add(
                    makeActionButton(
                            btnText,
                            watched,
                            new Runnable() {
                                public void run() {
                                    playingEpisodeIndex = ep.originalIndex;
                                    play(ep.url, ep.name);
                                }
                            }));
        }
        addGridViews(page, epButtons, episodeColumns(visibleSlice), 46);
    }

    static void appendMeta(StringBuilder sb, String value) {
        if (value == null) return;
        String t = value.trim();
        if (t.length() == 0) return;
        if (sb.length() > 0) sb.append(" · ");
        sb.append(t);
    }

    static int countEpisodes(String rawLine) {
        if (rawLine == null || rawLine.length() == 0) return 0;
        int n = 0;
        for (String entry : rawLine.split("#")) {
            if (entry.indexOf('$') >= 0) n++;
        }
        return n;
    }

    public static List<EpisodeItem> parseLineEpisodes(String rawLine) {
        List<EpisodeItem> out = new ArrayList<EpisodeItem>();
        if (rawLine == null || rawLine.length() == 0) return out;
        String[] entries = rawLine.split("#");
        for (int i = 0; i < entries.length; i++) {
            String entry = entries[i].trim();
            if (entry.length() == 0) continue;
            int sep = entry.indexOf('$');
            if (sep < 0) {
                if (entry.startsWith("http://") || entry.startsWith("https://")) {
                    out.add(new EpisodeItem("第" + (out.size() + 1) + "集", entry, out.size()));
                }
                continue;
            }
            String name = entry.substring(0, sep).trim();
            String url = entry.substring(sep + 1).trim();
            int trailingDollar = url.indexOf('$');
            if (trailingDollar > 0) url = url.substring(0, trailingDollar).trim();
            if (url.length() > 0) {
                out.add(
                        new EpisodeItem(
                                name.length() > 0 ? name : ("第" + (out.size() + 1) + "集"),
                                url,
                                out.size()));
            }
        }
        return out;
    }

    void play(final String address, final String name) {
        final LiteCatalog.Site source = selected;
        String finalAddress = address;
        if (source != null
                && source.playUrl != null
                && (source.playUrl.startsWith("http://") || source.playUrl.startsWith("https://"))
                && !address.startsWith(source.playUrl)) {
            finalAddress = source.playUrl + address;
        }
        if (source == null || !source.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)) {
            playResolved(
                    finalAddress,
                    address,
                    name,
                    source == null ? Collections.<String, String>emptyMap() : source.headers,
                    null);
            return;
        }
        base(name);
        inDetail = true;
        final int ticket = epoch;
        work(
                new Job() {
                    public void run() throws Exception {
                        final com.pilipala.emby.EmbyLibrary library =
                                com.pilipala.emby.EmbyAccounts.open(LiteActivity.this, source.api);
                        final JSONObject resolved = library.resolve(address, true);
                        final com.pilipala.emby.EmbyLibrary.Reporter reporter =
                                library.track(resolved.getJSONObject("embySession"));
                        final String stream = resolved.getString("url");
                        final Map<String, String> headers = library.headersFor(stream);
                        ui.post(
                                new Runnable() {
                                    public void run() {
                                        if (dead || ticket != epoch || selected != source) {
                                            reporter.stop(0);
                                            return;
                                        }
                                        playResolved(stream, address, name, headers, reporter);
                                    }
                                });
                    }
                });
    }

    void playResolved(
            final String address,
            final String identity,
            final String name,
            final Map<String, String> headers,
            com.pilipala.emby.EmbyLibrary.Reporter reporter) {
        base(name);
        embyReporter = reporter;
        playbackTitle = name;
        playbackAddress = identity;
        inPlayback = true;
        videoWidth = 0;
        videoHeight = 0;
        final int id = epoch;

        playback = new FrameLayout(this);
        playback.setBackgroundColor(0xff000000);
        setContentView(playback);

        surface = new SurfaceView(this);
        surface.setFocusable(false);
        playback.addView(surface, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        playerTopBar = new LinearLayout(this);
        playerTopBar.setOrientation(LinearLayout.HORIZONTAL);
        playerTopBar.setGravity(Gravity.CENTER_VERTICAL);
        com.pilipala.glass.GlassworkSurface.attach(
                playerTopBar,
                playback,
                0,
                new com.pilipala.glass.GlassworkSurface.Options() {
                    public boolean reduceTransparency() {
                        return true;
                    }
                });
        TextView backBtn = text("← 返回", 16);
        backBtn.setClickable(true);
        backBtn.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        onBackPressed();
                    }
                });
        playerTopBar.addView(backBtn, new LinearLayout.LayoutParams(-2, -2));

        String fullHeading =
                currentDetail != null
                        ? (currentDetail.optString("vod_name", "") + " · " + name)
                        : name;
        TextView heading = text(fullHeading, 19);
        heading.setSingleLine(true);
        heading.setEllipsize(TextUtils.TruncateAt.END);
        playerTopBar.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        playback.addView(playerTopBar, new FrameLayout.LayoutParams(-1, dp(54), Gravity.TOP));

        playerBottomPanel = new LinearLayout(this);
        playerBottomPanel.setOrientation(LinearLayout.VERTICAL);
        com.pilipala.glass.GlassworkSurface.attach(
                playerBottomPanel,
                playback,
                0,
                new com.pilipala.glass.GlassworkSurface.Options() {
                    public boolean reduceTransparency() {
                        return true;
                    }
                });
        playerBottomPanel.setPadding(dp(16), dp(8), dp(16), dp(10));

        LinearLayout progressRow = new LinearLayout(this);
        progressRow.setOrientation(LinearLayout.HORIZONTAL);
        progressRow.setGravity(Gravity.CENTER_VERTICAL);
        timeline = new SeekBar(this);
        timeline.setFocusable(false);
        clockView = text("00:00 / 00:00", 13);
        progressRow.addView(timeline, new LinearLayout.LayoutParams(0, -2, 1));
        progressRow.addView(clockView, new LinearLayout.LayoutParams(-2, -2));
        playerBottomPanel.addView(progressRow, new LinearLayout.LayoutParams(-1, -2));

        timeline.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                        if (fromUser && clockView != null && player != null)
                            clockView.setText(
                                    formatTime(progress)
                                            + " / "
                                            + formatTime(player.getDuration()));
                    }

                    public void onStartTrackingTouch(SeekBar s) {
                        sliderSeeking = true;
                        scheduleOsdHide();
                    }

                    public void onStopTrackingTouch(SeekBar s) {
                        int target = s.getProgress();
                        sliderSeeking = false;
                        scheduleOsdHide();
                        if (player != null && ready) {
                            lastUserSeekMs = target;
                            lastUserSeekAt = SystemClock.uptimeMillis();
                            try {
                                player.seekTo(target);
                            } catch (Exception ignored) {
                            }
                        }
                    }
                });

        playerControlRow = new LinearLayout(this);
        playerControlRow.setOrientation(LinearLayout.HORIZONTAL);
        playerControlRow.setGravity(Gravity.CENTER_VERTICAL);
        playerControlRow.setPadding(0, dp(4), 0, dp(2));
        buildPlayerControlButtons(address, identity, name, headers);
        playerBottomPanel.addView(playerControlRow, new LinearLayout.LayoutParams(-1, -2));

        status = text("正在准备播放…", 14);
        status.setTextColor(COLOR_MUTED);
        playerBottomPanel.addView(status, new LinearLayout.LayoutParams(-1, -2));
        playback.addView(playerBottomPanel, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        bindTouchSeekGesture(playerTopBar, playerBottomPanel);
        surface.getHolder()
                .addCallback(
                        new SurfaceHolder.Callback() {
                            public void surfaceCreated(SurfaceHolder holder) {
                                if (id != epoch || dead) return;
                                try {
                                    LiteCatalog.http(address);
                                    boolean useCandidate =
                                            getPreferences(0)
                                                    .getBoolean("experimental_decoder", false);
                                    int proxyMode =
                                            getPreferences(0)
                                                    .getInt("proxy_mode", LiteMediaProxy.MODE_AUTO);
                                    player = PlayerFactory.create(useCandidate);
                                    final LitePlayer expected = player;
                                    boolean isIjk = expected.name().contains("IJK");
                                    String streamUrl =
                                            LiteMediaProxy.wrapIfNeeded(
                                                    address, headers, proxyMode, isIjk);
                                    Map<String, String> openHeaders =
                                            streamUrl.startsWith("http://127.0.0.1:")
                                                    ? Collections.<String, String>emptyMap()
                                                    : headers;
                                    player.open(
                                            LiteActivity.this,
                                            streamUrl,
                                            openHeaders,
                                            holder,
                                            new LitePlayer.Listener() {
                                                public void prepared() {
                                                    if (expected != player) return;
                                                    ready = true;
                                                    int resumeMs = findSavedResumeMs(identity);
                                                    if (resumeMs > 0
                                                            && expected.getDuration() > 0
                                                            && resumeMs
                                                                    < expected.getDuration()
                                                                            - 2000) {
                                                        expected.seekTo(resumeMs);
                                                    }
                                                    expected.start();
                                                    updatePauseResumeLabel();
                                                    status.setText(
                                                            expected.name()
                                                                    + " · 确认键暂停/播放 · 左右键快进快退(长按加速) · 上下/菜单键呼出工具栏");
                                                    ui.removeCallbacks(clockTick);
                                                    ui.post(clockTick);
                                                    scheduleOsdHide();
                                                }

                                                public void error(int what, int extra) {
                                                    if (expected != player) return;
                                                    ready = false;
                                                    stopEmbySession();
                                                    setOsdVisibility(View.VISIBLE);
                                                    status.setText(
                                                            expected.name()
                                                                    + "无法播放（"
                                                                    + what
                                                                    + "/"
                                                                    + extra
                                                                    + "），可按上下键切换线路/代理或返回选择其他资源。");
                                                }

                                                public void size(final int w, final int h) {
                                                    ui.post(
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (expected != player
                                                                            || w <= 0
                                                                            || h <= 0) return;
                                                                    videoWidth = w;
                                                                    videoHeight = h;
                                                                    applyVideoSize();
                                                                }
                                                            });
                                                }

                                                public void completed() {
                                                    if (expected == player) {
                                                        stopEmbySession();
                                                        if (playNextEpisodeIfAvailable()) return;
                                                        setOsdVisibility(View.VISIBLE);
                                                        status.setText("播放结束 · 返回选集");
                                                    }
                                                }
                                            });
                                    ui.postDelayed(
                                            new Runnable() {
                                                public void run() {
                                                    if (player == expected && !ready)
                                                        status.setText(
                                                                "播放准备较慢，可按上下键切换线路或按返回选择其他资源。");
                                                }
                                            },
                                            15000);
                                } catch (Exception failure) {
                                    release();
                                    status.setText("无法打开播放地址，请返回选择其他资源。");
                                } catch (LinkageError unavailable) {
                                    release();
                                    status.setText("此设备无法加载实验解码器，请使用系统解码。");
                                }
                            }

                            public void surfaceChanged(
                                    SurfaceHolder h, int f, int w, int height) {}

                            public void surfaceDestroyed(SurfaceHolder h) {
                                if (id == epoch) release();
                            }
                        });
    }

    void buildPlayerControlButtons(
            final String address,
            final String identity,
            final String name,
            final Map<String, String> headers) {
        playerControlRow.removeAllViews();
        pauseResumeBtnView =
                addPlayerToolbarButton(
                        "暂停/播放",
                        new Runnable() {
                            public void run() {
                                togglePlayPause();
                            }
                        });
        if (playingLiveGroup != null && !playingLiveGroup.channels.isEmpty()) {
            addPlayerToolbarButton(
                    "上一台",
                    new Runnable() {
                        public void run() {
                            playLiveChannel(
                                    playingLiveGroup,
                                    playingLiveChannelIndex - 1,
                                    0,
                                    headers);
                        }
                    });
            addPlayerToolbarButton(
                    "下一台",
                    new Runnable() {
                        public void run() {
                            playLiveChannel(
                                    playingLiveGroup,
                                    playingLiveChannelIndex + 1,
                                    0,
                                    headers);
                        }
                    });
            final LiteCatalog.LiveChannel ch =
                    playingLiveGroup.channels.get(playingLiveChannelIndex);
            if (ch.urls.size() > 1) {
                addPlayerToolbarButton(
                        "换源 (" + (playingLiveUrlIndex + 1) + "/" + ch.urls.size() + ")",
                        new Runnable() {
                            public void run() {
                                playLiveChannel(
                                        playingLiveGroup,
                                        playingLiveChannelIndex,
                                        playingLiveUrlIndex + 1,
                                        headers);
                            }
                        });
            }
        } else if (currentDetail != null && !currentLineEpisodes.isEmpty()) {
            if (playingEpisodeIndex >= 0
                    && playingEpisodeIndex + 1 < currentLineEpisodes.size()) {
                addPlayerToolbarButton(
                        "下一集",
                        new Runnable() {
                            public void run() {
                                playNextEpisodeIfAvailable();
                            }
                        });
            }
            addPlayerToolbarButton(
                    "选集",
                    new Runnable() {
                        public void run() {
                            showInPlayerEpisodeDialog();
                        }
                    });
            final String[] rawLines = currentDetail.optString("vod_play_url").split("\\$\\$\\$");
            final String[] rawNames = currentDetail.optString("vod_play_from").split("\\$\\$\\$");
            if (rawLines.length > 1) {
                addPlayerToolbarButton(
                        "换线路",
                        new Runnable() {
                            public void run() {
                                showInPlayerLineDialog(rawLines, rawNames);
                            }
                        });
            }
        }
        aspectBtnView =
                addPlayerToolbarButton(
                        "比例：" + aspectLabel(aspectMode),
                        new Runnable() {
                            public void run() {
                                aspectMode = (aspectMode + 1) % 4;
                                getPreferences(0).edit().putInt("aspect_mode", aspectMode).commit();
                                if (aspectBtnView != null) {
                                    aspectBtnView.setText("比例：" + aspectLabel(aspectMode));
                                }
                                applyVideoSize();
                                scheduleOsdHide();
                            }
                        });
        int proxyMode = getPreferences(0).getInt("proxy_mode", LiteMediaProxy.MODE_AUTO);
        proxyBtnView =
                addPlayerToolbarButton(
                        "代理：" + proxyModeLabel(proxyMode),
                        new Runnable() {
                            public void run() {
                                int next =
                                        (getPreferences(0)
                                                        .getInt(
                                                                "proxy_mode",
                                                                LiteMediaProxy.MODE_AUTO)
                                                + 1)
                                                % 3;
                                getPreferences(0).edit().putInt("proxy_mode", next).commit();
                                playResolved(address, identity, name, headers, embyReporter);
                            }
                        });
    }

    TextView addPlayerToolbarButton(String label, final Runnable action) {
        final TextView b = text(label, 14);
        b.setPadding(dp(12), dp(6), dp(12), dp(6));
        b.setGravity(Gravity.CENTER);
        b.setSingleLine(true);
        b.setFocusable(false);
        b.setClickable(true);
        styleChip(b, false, false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(36));
        lp.setMargins(dp(4), dp(2), dp(4), dp(2));
        b.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    public void onFocusChange(View v, boolean focus) {
                        styleChip(b, false, focus);
                        if (focus) scheduleOsdHide();
                    }
                });
        b.setOnClickListener(
                new View.OnClickListener() {
                    public void onClick(View v) {
                        scheduleOsdHide();
                        action.run();
                    }
                });
        playerControlRow.addView(b, lp);
        return b;
    }

    void enableToolbarFocusAndSelectFirst() {
        if (playerControlRow == null || playerControlRow.getChildCount() == 0) return;
        for (int i = 0; i < playerControlRow.getChildCount(); i++) {
            View child = playerControlRow.getChildAt(i);
            child.setFocusable(true);
        }
        playerControlRow.getChildAt(0).requestFocus();
    }

    void disableToolbarFocus() {
        if (playerControlRow == null) return;
        for (int i = 0; i < playerControlRow.getChildCount(); i++) {
            View child = playerControlRow.getChildAt(i);
            child.clearFocus();
            child.setFocusable(false);
        }
    }

    boolean isToolbarButtonFocused() {
        if (playerControlRow == null) return false;
        for (int i = 0; i < playerControlRow.getChildCount(); i++) {
            if (playerControlRow.getChildAt(i).hasFocus()) return true;
        }
        return false;
    }

    void setOsdVisibility(int visibility) {
        if (playerTopBar != null) playerTopBar.setVisibility(visibility);
        if (playerBottomPanel != null) playerBottomPanel.setVisibility(visibility);
        if (visibility != View.VISIBLE) {
            disableToolbarFocus();
        }
    }

    void scheduleOsdHide() {
        ui.removeCallbacks(hideOsdTask);
        if (inPlayback && ready) {
            ui.postDelayed(hideOsdTask, OSD_AUTO_HIDE_MS);
        }
    }

    void applyVideoSize() {
        if (playback == null || surface == null) return;
        int width = playback.getWidth(), height = playback.getHeight();
        if (width <= 0 || height <= 0) return;
        int[] dims =
                computeAspectDimensions(width, height, videoWidth, videoHeight, aspectMode);
        surface.setLayoutParams(new FrameLayout.LayoutParams(dims[0], dims[1], Gravity.CENTER));
    }

    void togglePlayPause() {
        if (player == null || !ready) return;
        try {
            if (player.isPlaying()) player.pause();
            else if (embyReporter == null
                    && selected != null
                    && selected.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)) {
                play(playbackAddress, playbackTitle);
                return;
            } else player.start();
            updatePauseResumeLabel();
            if (embyReporter != null && player != null) {
                embyReporter.update(player.getCurrentPosition(), !player.isPlaying());
            }
            setOsdVisibility(View.VISIBLE);
            scheduleOsdHide();
        } catch (IllegalStateException ignored) {
        }
    }

    void updatePauseResumeLabel() {
        if (pauseResumeBtnView == null || player == null) return;
        try {
            pauseResumeBtnView.setText(player.isPlaying() ? "⏸ 暂停" : "▶ 继续");
        } catch (Exception ignored) {
        }
    }

    int findSavedResumeMs(String identity) {
        if (identity != null
                && identity.equals(getPreferences(0).getString("resume_address", ""))) {
            int ms = getPreferences(0).getInt("resume_ms", 0);
            if (ms > 0) return ms;
        }
        if (selected != null && currentDetail != null) {
            LiteStore.HistoryEntry h =
                    LiteStore.findHistory(
                            this, selected.key, currentDetail.optString("vod_id", ""));
            if (h != null
                    && (identity.equals(h.epUrl) || playbackTitle.equals(h.epName))
                    && h.positionMs > 0) {
                return h.positionMs;
            }
        }
        return 0;
    }

    boolean playNextEpisodeIfAvailable() {
        if (currentDetail == null || currentLineEpisodes.isEmpty()) return false;
        int nextIdx = playingEpisodeIndex + 1;
        if (nextIdx >= 0 && nextIdx < currentLineEpisodes.size()) {
            EpisodeItem nextEp = currentLineEpisodes.get(nextIdx);
            playingEpisodeIndex = nextEp.originalIndex;
            play(nextEp.url, nextEp.name);
            return true;
        }
        return false;
    }

    void showInPlayerEpisodeDialog() {
        if (currentLineEpisodes.isEmpty()) return;
        String[] labels = new String[currentLineEpisodes.size()];
        for (int i = 0; i < currentLineEpisodes.size(); i++) {
            EpisodeItem ep = currentLineEpisodes.get(i);
            labels[i] = (i == playingEpisodeIndex ? "▶ " : "") + ep.name;
        }
        new AlertDialog.Builder(this)
                .setTitle("选择剧集")
                .setItems(
                        labels,
                        new DialogInterface.OnClickListener() {
                            public void onClick(DialogInterface dialog, int which) {
                                if (which >= 0 && which < currentLineEpisodes.size()) {
                                    EpisodeItem ep = currentLineEpisodes.get(which);
                                    playingEpisodeIndex = ep.originalIndex;
                                    play(ep.url, ep.name);
                                }
                            }
                        })
                .show();
    }

    void showInPlayerLineDialog(final String[] rawLines, final String[] rawNames) {
        String[] labels = new String[rawLines.length];
        for (int i = 0; i < rawLines.length; i++) {
            String n =
                    i < rawNames.length && rawNames[i].trim().length() > 0
                            ? rawNames[i].trim()
                            : ("线路 " + (i + 1));
            labels[i] = (i == activeDetailLine ? "★ " : "") + n;
        }
        new AlertDialog.Builder(this)
                .setTitle("切换播放线路")
                .setItems(
                        labels,
                        new DialogInterface.OnClickListener() {
                            public void onClick(DialogInterface dialog, int which) {
                                if (which >= 0 && which < rawLines.length) {
                                    activeDetailLine = which;
                                    currentLineEpisodes = parseLineEpisodes(rawLines[which]);
                                    if (!currentLineEpisodes.isEmpty()) {
                                        int targetIdx =
                                                Math.max(
                                                        0,
                                                        Math.min(
                                                                playingEpisodeIndex,
                                                                currentLineEpisodes.size() - 1));
                                        EpisodeItem ep = currentLineEpisodes.get(targetIdx);
                                        playingEpisodeIndex = ep.originalIndex;
                                        play(ep.url, ep.name);
                                    }
                                }
                            }
                        })
                .show();
    }

    void bindTouchSeekGesture(final View topBar, final View bottomPanel) {
        final float[] downXY = new float[2];
        final int[] startPos = new int[1], targetPos = new int[1];
        final boolean[] dragging = new boolean[1];
        final int slop = ViewConfiguration.get(this).getScaledTouchSlop();
        playback.setOnTouchListener(
                new View.OnTouchListener() {
                    public boolean onTouch(View v, MotionEvent ev) {
                        int act = ev.getActionMasked();
                        if (act == MotionEvent.ACTION_DOWN) {
                            downXY[0] = ev.getRawX();
                            downXY[1] = ev.getRawY();
                            dragging[0] = false;
                            startPos[0] =
                                    player != null && ready
                                            ? Math.max(0, player.getCurrentPosition())
                                            : 0;
                            targetPos[0] = startPos[0];
                            return true;
                        }
                        if (act == MotionEvent.ACTION_MOVE) {
                            float dx = ev.getRawX() - downXY[0], dy = ev.getRawY() - downXY[1];
                            if (!dragging[0]
                                    && Math.abs(dx) > slop
                                    && Math.abs(dx) > Math.abs(dy) * 1.2f
                                    && player != null
                                    && ready
                                    && player.getDuration() > 0) {
                                dragging[0] = true;
                                touchSeeking = true;
                                setOsdVisibility(View.VISIBLE);
                            }
                            if (dragging[0] && player != null && ready) {
                                int dur = player.getDuration();
                                int width = Math.max(1, playback.getWidth());
                                int delta = (int) ((dx / width) * Math.min(dur, 180000));
                                targetPos[0] = Math.max(0, Math.min(dur, startPos[0] + delta));
                                if (timeline != null) {
                                    timeline.setMax(dur);
                                    timeline.setProgress(targetPos[0]);
                                }
                                if (clockView != null)
                                    clockView.setText(
                                            formatTime(targetPos[0]) + " / " + formatTime(dur));
                                status.setText(
                                        (delta >= 0 ? "快进至 " : "快退至 ") + formatTime(targetPos[0]));
                            }
                            return true;
                        }
                        if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                            if (dragging[0]) {
                                dragging[0] = false;
                                touchSeeking = false;
                                if (player != null && ready && player.getDuration() > 0) {
                                    lastUserSeekMs = targetPos[0];
                                    lastUserSeekAt = SystemClock.uptimeMillis();
                                    try {
                                        player.seekTo(targetPos[0]);
                                        status.setText("已跳转至 " + formatTime(targetPos[0]));
                                    } catch (Exception ignored) {
                                    }
                                }
                                scheduleOsdHide();
                            } else if (act == MotionEvent.ACTION_UP) {
                                int vis =
                                        topBar.getVisibility() == View.VISIBLE
                                                ? View.GONE
                                                : View.VISIBLE;
                                setOsdVisibility(vis);
                                if (vis == View.VISIBLE) scheduleOsdHide();
                            }
                            return true;
                        }
                        return false;
                    }
                });
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int k = e.getKeyCode();
        if (inPlayback && player != null && ready) {
            if (isToolbarButtonFocused()) {
                scheduleOsdHide();
                if (k == KeyEvent.KEYCODE_DPAD_UP && e.getAction() == KeyEvent.ACTION_DOWN) {
                    disableToolbarFocus();
                    return true;
                }
                return super.dispatchKeyEvent(e);
            }
            if (k == KeyEvent.KEYCODE_DPAD_UP
                    || k == KeyEvent.KEYCODE_DPAD_DOWN
                    || k == KeyEvent.KEYCODE_MENU) {
                if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) {
                    if (playingLiveGroup != null
                            && playerTopBar != null
                            && playerTopBar.getVisibility() != View.VISIBLE
                            && (k == KeyEvent.KEYCODE_DPAD_UP
                                    || k == KeyEvent.KEYCODE_DPAD_DOWN)) {
                        int delta = k == KeyEvent.KEYCODE_DPAD_UP ? -1 : 1;
                        playLiveChannel(
                                playingLiveGroup,
                                playingLiveChannelIndex + delta,
                                0,
                                selected != null
                                        ? selected.headers
                                        : Collections.<String, String>emptyMap());
                        return true;
                    }
                    setOsdVisibility(View.VISIBLE);
                    enableToolbarFocusAndSelectFirst();
                    scheduleOsdHide();
                }
                return true;
            }
            if (k == KeyEvent.KEYCODE_DPAD_CENTER
                    || k == KeyEvent.KEYCODE_ENTER
                    || k == KeyEvent.KEYCODE_DPAD_LEFT
                    || k == KeyEvent.KEYCODE_DPAD_RIGHT) {
                if (e.getAction() == KeyEvent.ACTION_DOWN) {
                    try {
                        if (k == KeyEvent.KEYCODE_DPAD_LEFT || k == KeyEvent.KEYCODE_DPAD_RIGHT) {
                            int dur = player.getDuration();
                            if (dur > 0) {
                                int step = computeLongPressSeekStepMs(e.getRepeatCount());
                                int basePos =
                                        lastUserSeekMs >= 0
                                                        && SystemClock.uptimeMillis()
                                                                        - lastUserSeekAt
                                                                < 1200
                                                ? lastUserSeekMs
                                                : player.getCurrentPosition();
                                int target =
                                        Math.max(
                                                0,
                                                Math.min(
                                                        dur,
                                                        basePos
                                                                + (k == KeyEvent.KEYCODE_DPAD_LEFT
                                                                        ? -step
                                                                        : step)));
                                lastUserSeekMs = target;
                                lastUserSeekAt = SystemClock.uptimeMillis();
                                if (timeline != null) {
                                    timeline.setMax(dur);
                                    timeline.setProgress(target);
                                }
                                if (clockView != null) {
                                    clockView.setText(formatTime(target) + " / " + formatTime(dur));
                                }
                                setOsdVisibility(View.VISIBLE);
                                scheduleOsdHide();
                                player.seekTo(target);
                            }
                        } else if (e.getRepeatCount() == 0) {
                            togglePlayPause();
                        }
                    } catch (IllegalStateException ignored) {
                    }
                }
                return true;
            }
        } else if (!inPlayback && e.getAction() == KeyEvent.ACTION_DOWN) {
            if (k == KeyEvent.KEYCODE_MENU && e.getRepeatCount() == 0) {
                home();
                return true;
            }
            if (k == KeyEvent.KEYCODE_SEARCH && e.getRepeatCount() == 0) {
                search();
                return true;
            }
            if (k == KeyEvent.KEYCODE_DPAD_UP && e.getRepeatCount() == 0) {
                long now = SystemClock.uptimeMillis();
                if (now - lastUpKeyAt < 500) {
                    upKeyStreak++;
                    if (upKeyStreak >= 2 && mainScroll != null) {
                        mainScroll.fullScroll(View.FOCUS_UP);
                        upKeyStreak = 0;
                    }
                } else {
                    upKeyStreak = 0;
                }
                lastUpKeyAt = now;
            }
        }
        return super.dispatchKeyEvent(e);
    }

    void saveResume() {
        if (player == null || !ready || playbackAddress.isEmpty()) return;
        try {
            int pos = player.getCurrentPosition(), dur = player.getDuration();
            if (dur > 0 && pos >= dur * 0.95) pos = 0;
            int safePos = Math.max(0, pos);
            getPreferences(0)
                    .edit()
                    .putString("resume_address", playbackAddress)
                    .putInt("resume_ms", safePos)
                    .apply();
            if (selected != null && currentDetail != null && playingLiveGroup == null) {
                LiteStore.HistoryEntry entry = new LiteStore.HistoryEntry();
                entry.siteKey = selected.key;
                entry.siteName = selected.name;
                entry.siteApi = selected.api;
                entry.vodId = currentDetail.optString("vod_id", "");
                entry.vodName = currentDetail.optString("vod_name", playbackTitle);
                entry.vodPic = currentDetail.optString("vod_pic", "");
                String[] rawNames =
                        currentDetail.optString("vod_play_from").split("\\$\\$\\$");
                entry.lineName =
                        activeDetailLine >= 0 && activeDetailLine < rawNames.length
                                ? rawNames[activeDetailLine]
                                : "";
                entry.lineIndex = activeDetailLine;
                entry.epName = playbackTitle;
                entry.epUrl = playbackAddress;
                entry.epIndex = Math.max(0, playingEpisodeIndex);
                entry.positionMs = safePos;
                entry.durationMs = Math.max(0, dur);
                entry.updatedAt = System.currentTimeMillis();
                LiteStore.saveHistory(this, entry);
            }
        } catch (Exception ignored) {
        }
    }

    void stopEmbySession() {
        if (embyReporter == null) return;
        int position = 0;
        try {
            if (player != null) position = player.getCurrentPosition();
        } catch (Exception ignored) {
        }
        embyReporter.stop(position);
        embyReporter = null;
    }

    void release() {
        saveResume();
        stopEmbySession();
        ready = false;
        touchSeeking = false;
        sliderSeeking = false;
        ui.removeCallbacks(clockTick);
        ui.removeCallbacks(hideOsdTask);
        if (player != null) {
            player.release();
            player = null;
        }
    }

    void closePairing() {
        synchronized (importLock) {
            if (pairing != null) {
                pairing.close();
                pairing = null;
            }
        }
    }

    @Override
    public void onBackPressed() {
        if (homeVisible) {
            finish();
            return;
        }
        if (inPlayback && playingLiveGroup != null) {
            livePage();
            return;
        }
        if (inPlayback && currentDetail != null) {
            showDetail(currentDetail);
            return;
        }
        if (inDetail && selected != null) {
            catalog(lastQuery, lastCategory, lastPage);
            return;
        }
        home();
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (backgrounded) {
            backgrounded = false;
            if (inPlayback && currentDetail != null) showDetail(currentDetail);
            else home();
        }
    }

    @Override
    protected void onStop() {
        super.onStop();
        backgrounded = true;
        epoch++;
        cancelWork();
        closePairing();
        release();
    }

    @Override
    protected void onDestroy() {
        dead = true;
        epoch++;
        cancelWork();
        closePairing();
        release();
        io.shutdownNow();
        super.onDestroy();
    }
}
