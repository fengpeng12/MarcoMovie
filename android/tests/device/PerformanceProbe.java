package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.graphics.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic, warmed-poster TV rendering measurements. No real content or credentials. */
public final class PerformanceProbe extends Instrumentation {
    MainActivity a;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject report = new JSONObject();
    final ArrayList<Long> frames = new ArrayList<>();
    HandlerThread metricsThread;
    Window.OnFrameMetricsAvailableListener listener;

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        start();
    }

    @Override
    public void callActivityOnCreate(Activity activity, Bundle state) {
        // Do not initialize the user's external source while measuring synthetic rendering.
        SharedPreferences prefs = activity.getSharedPreferences("movie", 0);
        boolean had = prefs.contains("selected_site");
        String saved = prefs.getString("selected_site", "");
        prefs.edit().putString("selected_site", "performance-initializing").commit();
        try {
            super.callActivityOnCreate(activity, state);
        } finally {
            SharedPreferences.Editor edit = prefs.edit();
            if (had) edit.putString("selected_site", saved);
            else edit.remove("selected_site");
            edit.commit();
        }
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            launched.countDown();
        }
    }

    boolean ui(Callable<Boolean> call) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = call.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return value[0];
    }

    void check(String key, boolean value) throws Exception {
        report.put(key, value);
        if (!value) throw new AssertionError(key);
    }

    void await(Callable<Boolean> call) throws Exception {
        long end = SystemClock.elapsedRealtime() + 15000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(call)) return;
            SystemClock.sleep(30);
        }
        throw new AssertionError("timeout");
    }

    View tag(String key) {
        return a.root.findViewWithTag(key);
    }

    String listing(int count, int page) throws Exception {
        JSONArray items = new JSONArray();
        for (int i = 0; i < count; i++)
            items.put(
                    new JSONObject()
                            .put("vod_id", "v" + (i + (page - 1) * count))
                            .put("vod_name", "流畅度样本 " + (i + (page - 1) * count))
                            .put("vod_pic", "https://fixture.test/poster/" + (i % 8)));
        return new JSONObject().put("list", items).put("pagecount", 2).toString();
    }

    void startMetrics() {
        synchronized (frames) {
            frames.clear();
        }
        listener =
                (window, metrics, dropped) -> {
                    synchronized (frames) {
                        frames.add(metrics.getMetric(FrameMetrics.TOTAL_DURATION));
                    }
                };
        runOnMainSync(
                () ->
                        a.getWindow()
                                .addOnFrameMetricsAvailableListener(
                                        listener, new Handler(metricsThread.getLooper())));
    }

    JSONObject endMetrics() throws Exception {
        runOnMainSync(() -> a.getWindow().removeOnFrameMetricsAvailableListener(listener));
        listener = null;
        SystemClock.sleep(80);
        ArrayList<Long> copy;
        synchronized (frames) {
            copy = new ArrayList<>(frames);
        }
        Collections.sort(copy);
        int slow = 0, verySlow = 0;
        long total = 0;
        for (long ns : copy) {
            total += ns;
            if (ns > 16666667) slow++;
            if (ns > 33333334) verySlow++;
        }
        JSONObject value =
                new JSONObject()
                        .put("frames", copy.size())
                        .put("over_16_7ms", slow)
                        .put("over_33_3ms", verySlow);
        if (!copy.isEmpty())
            value.put("p95_ms", copy.get((int) ((copy.size() - 1) * .95)) / 1e6)
                    .put("max_ms", copy.get(copy.size() - 1) / 1e6)
                    .put("mean_ms", total / 1e6 / copy.size());
        return value;
    }

    void frame(String name) throws Exception {
        await(() -> a.root.getWidth() > 0 && a.root.getHeight() > 0);
        runOnMainSync(
                () -> {
                    Bitmap bitmap =
                            Bitmap.createBitmap(
                                    a.root.getWidth(), a.root.getHeight(), Bitmap.Config.ARGB_8888);
                    a.root.draw(new Canvas(bitmap));
                    try (java.io.FileOutputStream out =
                            new java.io.FileOutputStream(
                                    new java.io.File(a.getExternalFilesDir(null), name + ".png"))) {
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    } finally {
                        bitmap.recycle();
                    }
                });
    }

    boolean noClippedAncestor(View view) {
        float[] corners = {0, 0, view.getWidth(), view.getHeight()};
        view.getMatrix().mapPoints(corners);
        float l = corners[0] + view.getLeft(),
                t = corners[1] + view.getTop(),
                r = corners[2] + view.getLeft(),
                b = corners[3] + view.getTop();
        ViewParent parent = view.getParent();
        while (parent instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) parent;
            if (g.getClipChildren()
                    && (l < g.getScrollX() - 1
                            || t < g.getScrollY() - 1
                            || r > g.getScrollX() + g.getWidth() + 1
                            || b > g.getScrollY() + g.getHeight() + 1)) return false;
            l += g.getLeft() - g.getScrollX();
            r += g.getLeft() - g.getScrollX();
            t += g.getTop() - g.getScrollY();
            b += g.getTop() - g.getScrollY();
            parent = g.getParent();
        }
        return true;
    }

    @Override
    public void onStart() {
        SharedPreferences original = null;
        Cms.Config old = null;
        try {
            Context c = getTargetContext();
            c.startActivity(
                    new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            original = a.prefs;
            old = a.config;
            SharedPreferences fixture = c.getSharedPreferences("performance_probe_fixture", 0);
            fixture.edit()
                    .clear()
                    .putBoolean("startup_animation", false)
                    .putString("selected_site", "perf-fixture")
                    .commit();
            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = "perf-fixture";
            e.id = "v0";
            e.title = "仅一条观看记录";
            e.episode = "第 1 集";
            e.position = 5000;
            e.duration = 30000;
            e.updated = System.currentTimeMillis();
            fixture.edit().putString("watch_history", WatchHistory.upsert("[]", e)).commit();
            metricsThread = new HandlerThread("frame-metrics");
            metricsThread.start();
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.prefs = fixture;
                        a.reduced = false;
                        Cms.Config cfg = new Cms.Config();
                        cfg.raw = "{}";
                        Cms.Site site = new Cms.Site();
                        site.key = "perf-fixture";
                        site.name = "流畅度样本";
                        site.type = 1;
                        site.api = "https://fixture.test/api";
                        site.searchable = true;
                        cfg.sites.add(site);
                        a.config = cfg;
                        a.engines.put(
                                site.key,
                                new SourceEngine() {
                                    public String home() {
                                        return "{\"class\":[{\"type_id\":\"c1\",\"type_name\":\"样本\"}],\"list\":[]}";
                                    }

                                    public String category(String category, int page)
                                            throws Exception {
                                        return listing(30, page);
                                    }

                                    public String detail(String id) {
                                        return "{}";
                                    }

                                    public String search(String q, int page) throws Exception {
                                        return listing(12, 1);
                                    }

                                    public boolean requiresExternalRuntime() {
                                        return false;
                                    }
                                });
                        for (int i = 0; i < 8; i++) {
                            Bitmap b = Bitmap.createBitmap(240, 360, Bitmap.Config.ARGB_8888);
                            Canvas canvas = new Canvas(b);
                            Paint p = new Paint(3);
                            p.setShader(
                                    new LinearGradient(
                                            0,
                                            0,
                                            240,
                                            360,
                                            Color.HSVToColor(new float[] {i * 44, .7f, .8f}),
                                            0xff172439,
                                            Shader.TileMode.CLAMP));
                            canvas.drawRect(0, 0, 240, 360, p);
                            a.images.put("https://fixture.test/poster/" + i, b);
                        }
                        a.back.clear();
                        a.open(new MainActivity.Screen(a::home), false);
                    });
            await(() -> tag("home-video:29") != null);
            SystemClock.sleep(1200);
            runOnMainSync(
                    () -> {
                        tag("home-history:0").requestFocus();
                        a.scroll.scrollTo(0, 0);
                    });
            SystemClock.sleep(250);
            check(
                    "single_home_history_unclipped",
                    ui(() -> noClippedAncestor(tag("home-history:0"))));
            frame("performance-single-history");
            runOnMainSync(() -> a.open(new MainActivity.Screen(a::historyPage), true));
            SystemClock.sleep(250);
            runOnMainSync(() -> tag("history:" + e.key()).requestFocus());
            SystemClock.sleep(250);
            check(
                    "single_history_list_unclipped",
                    ui(() -> noClippedAncestor(tag("history:" + e.key()))));
            frame("performance-history-list");
            runOnMainSync(() -> a.onBackPressed());
            await(() -> tag("home-video:29") != null);
            SystemClock.sleep(1200);
            check(
                    "remote_scroll_uses_retargetable_motion",
                    ui(() -> a.scroll instanceof TvScrollView));
            int[] positions = new int[2];
            runOnMainSync(
                    () -> {
                        a.scroll.scrollTo(0, 0);
                        positions[0] = a.scroll.getScrollY();
                        tag("home-video:25").requestFocus();
                        positions[1] = a.scroll.getScrollY();
                    });
            check("remote_scroll_starts_without_jump", positions[0] == positions[1]);
            SystemClock.sleep(80);
            check(
                    "remote_scroll_has_intermediate_position",
                    ui(
                            () ->
                                    a.scroll.getScrollY() > 0
                                            && ((TvScrollView) a.scroll).motion != null));
            runOnMainSync(
                    () -> {
                        positions[0] = a.scroll.getScrollY();
                        tag("home-video:0").requestFocus();
                        positions[1] = a.scroll.getScrollY();
                    });
            check("rapid_scroll_retargets_without_jump", positions[0] == positions[1]);
            SystemClock.sleep(800);
            check(
                    "remote_scroll_finishes_at_target",
                    ui(() -> ((TvScrollView) a.scroll).motion == null));
            runOnMainSync(
                    () -> {
                        a.reduced = true;
                        tag("home-video:25").requestFocus();
                    });
            check(
                    "reduced_motion_scrolls_immediately",
                    ui(
                            () ->
                                    a.scroll.getScrollY() > 0
                                            && ((TvScrollView) a.scroll).motion == null));
            runOnMainSync(
                    () -> {
                        tag("home-video:0").requestFocus();
                        a.reduced = false;
                    });
            SystemClock.sleep(800);
            startMetrics();
            for (int i = 0; i < 40; i++) {
                final int index = i % 5;
                runOnMainSync(() -> tag("home-video:" + index).requestFocus());
                SystemClock.sleep(180);
            }
            SystemClock.sleep(900);
            report.put("focus", endMetrics());
            startMetrics();
            for (int i = 0; i < 5; i++) {
                final int index = i * 5;
                runOnMainSync(() -> tag("home-video:" + index).requestFocus());
                SystemClock.sleep(250);
            }
            for (int i = 4; i >= 0; i--) {
                final int index = i * 5;
                runOnMainSync(() -> tag("home-video:" + index).requestFocus());
                SystemClock.sleep(250);
            }
            SystemClock.sleep(300);
            report.put("scroll", endMetrics());
            View first = tag("home-video:0");
            startMetrics();
            long[] append = {0};
            runOnMainSync(
                    () -> {
                        tag("home-load-more").requestFocus();
                        long begin = SystemClock.elapsedRealtimeNanos();
                        tag("home-load-more").performClick();
                        append[0] = SystemClock.elapsedRealtimeNanos() - begin;
                    });
            await(() -> tag("home-video:59") != null);
            SystemClock.sleep(800);
            report.put("append", endMetrics());
            check("append_preserves_first_card", ui(() -> tag("home-video:0") == first));
            check("metrics_collected", report.getJSONObject("focus").getInt("frames") > 30);
            report.put("passed", true);
        } catch (Throwable error) {
            try {
                report.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                SharedPreferences prefs = original;
                Cms.Config cfg = old;
                runOnMainSync(
                        () -> {
                            if (listener != null)
                                a.getWindow().removeOnFrameMetricsAvailableListener(listener);
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            if (prefs != null) a.prefs = prefs;
                            a.config = cfg;
                            a.engines.remove("perf-fixture");
                            a.homeData.remove("perf-fixture");
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
            if (metricsThread != null) metricsThread.quitSafely();
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
