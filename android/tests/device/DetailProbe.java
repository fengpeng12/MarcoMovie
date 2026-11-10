package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.*;

/** Detail latency and lifecycle checks. Fixtures never alter user sources or history. */
public final class DetailProbe extends Instrumentation {
    MainActivity a;
    Bundle args;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject report = new JSONObject();

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        args = b;
        start();
    }

    @Override
    public void callActivityOnCreate(Activity activity, Bundle state) {
        if (activity instanceof MainActivity) {
            try {
                Context base = activity.getBaseContext();
                java.lang.reflect.Field field = ContextWrapper.class.getDeclaredField("mBase");
                field.setAccessible(true);
                field.set(
                        activity,
                        new ContextWrapper(base) {
                            public SharedPreferences getSharedPreferences(String name, int mode) {
                                return super.getSharedPreferences(
                                        name.equals("movie") ? "detail_layout_bootstrap" : name,
                                        mode);
                            }

                            public java.io.File getFilesDir() {
                                java.io.File file =
                                        new java.io.File(
                                                super.getCacheDir(), "detail-layout-empty");
                                file.mkdirs();
                                return file;
                            }
                        });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
        super.callActivityOnCreate(activity, state);
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            final MainActivity created = a;
            created.getWindow()
                    .addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            created.ui.post(
                    new Runnable() {
                        public void run() {
                            if (created.isDestroyed()) return;
                            if (created.layoutReady) launched.countDown();
                            else created.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    boolean ui(Callable<Boolean> fn) {
        boolean[] v = {false};
        runOnMainSync(
                () -> {
                    try {
                        v[0] = fn.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return v[0];
    }

    void await(Callable<Boolean> fn) throws Exception {
        long until = SystemClock.elapsedRealtime() + 15000;
        while (SystemClock.elapsedRealtime() < until) {
            if (ui(fn)) return;
            SystemClock.sleep(10);
        }
        throw new AssertionError("wait timeout");
    }

    void check(String key, boolean value) throws Exception {
        report.put(key, value);
        if (!value) throw new AssertionError(key);
    }

    View tag(String key) {
        return a.root.findViewWithTag(key);
    }

    long enter(Cms.Site site, Cms.Video video) throws Exception {
        long start = SystemClock.elapsedRealtime();
        runOnMainSync(() -> a.open(new MainActivity.Screen(() -> a.detail(site, video)), true));
        await(() -> tag("detail-play") != null);
        return SystemClock.elapsedRealtime() - start;
    }

    String response(String id) throws Exception {
        StringBuilder episodes = new StringBuilder();
        for (int i = 0; i < 200; i++) {
            if (i > 0) episodes.append('#');
            episodes.append(i == 0 ? "这是一个很长的完整剧集标题，需要在聚焦时展示全部文字而不省略 — 第 " : "第 ")
                    .append(i + 1)
                    .append(" 集$https://fixture.test/")
                    .append(i)
                    .append(".mp4");
        }
        return new JSONObject()
                .put(
                        "list",
                        new JSONArray()
                                .put(
                                        new JSONObject()
                                                .put("vod_id", id)
                                                .put("vod_name", "选集响应样本")
                                                .put("vod_play_from", "样本线路$$$备用线路")
                                                .put(
                                                        "vod_play_url",
                                                        episodes.toString()
                                                                + "$$$"
                                                                + episodes.toString())))
                .toString();
    }

    void cancelledEpisodeChange(Cms.Site site, Cms.Line line, Cms.Episode episode)
            throws Exception {
        Cms.Video complete = Cms.listing(response("sample")).videos.get(0);
        runOnMainSync(() -> a.changeEpisode(site, complete, line, episode, 0));
        check(
                "episode_change_renders_details_before_resolution",
                ui(
                        () ->
                                !a.current.player
                                        && a.player == null
                                        && tag("detail-cover") != null
                                        && tag("playback-loading") != null
                                        && tag("detail-play") != null));
        runOnMainSync(() -> a.onBackPressed());
        check(
                "episode_change_cancel_returns_to_operable_details",
                ui(
                        () ->
                                !a.current.player
                                        && tag("playback-loading") == null
                                        && tag("detail-play") != null));
        SystemClock.sleep(1400);
        check(
                "cancelled_episode_change_cannot_restore_old_player",
                ui(() -> a.player == null && !a.current.player && tag("detail-cover") != null));
    }

    @Override
    public void onStart() {
        SharedPreferences original = null;
        Cms.Config old = null;
        CountDownLatch release = new CountDownLatch(1);
        try {
            Context c = getTargetContext();
            c.startActivity(
                    new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            original = a.prefs;
            old = a.config;
            if ("true".equals(args.getString("live"))) {
                Cms.Site site = null;
                String key = a.prefs.getString("selected_site", "");
                for (Cms.Site s : a.config.sites) if (s.key.equals(key)) site = s;
                if (site == null) throw new AssertionError("selected source unavailable");
                long begin = SystemClock.elapsedRealtime();
                SourceEngine engine = a.engine(site);
                report.put("engine_ms", SystemClock.elapsedRealtime() - begin);
                Cms.Listing list = Cms.listing(engine.home());
                if (list.videos.isEmpty()) list = Cms.listing(engine.homeVideos());
                if (list.videos.isEmpty()) {
                    java.util.List<Cms.Category> cats = Cms.categories(engine.home());
                    if (!cats.isEmpty()) list = Cms.listing(engine.category(cats.get(0).id, 1));
                }
                if (list.videos.isEmpty()) throw new AssertionError("no sample");
                Cms.Video sample = list.videos.get(0);
                begin = SystemClock.elapsedRealtime();
                String raw = engine.detail(sample.id);
                report.put("source_detail_ms", SystemClock.elapsedRealtime() - begin);
                begin = SystemClock.elapsedRealtime();
                Cms.Listing parsed = Cms.listing(raw);
                report.put("parse_ms", SystemClock.elapsedRealtime() - begin);
                report.put(
                        "lines", parsed.videos.isEmpty() ? 0 : parsed.videos.get(0).lines.size());
                report.put("page_first_ms", enter(site, sample));
                report.put("page_repeat_ms", enter(site, sample));
                report.put("passed", true);
            } else {
                SharedPreferences fixture = c.getSharedPreferences("detail_probe_fixture", 0);
                fixture.edit().clear().commit();
                Cms.Site s = new Cms.Site();
                s.key = "detail-fixture";
                s.type = 1;
                s.api = "https://fixture.test/api";
                s.name = "详情样本";
                Cms.Video video = new Cms.Video();
                video.id = "sample";
                video.title = "选集响应样本";
                AtomicInteger calls = new AtomicInteger();
                AtomicInteger cancelled = new AtomicInteger();
                SourceEngine source =
                        new SourceEngine() {
                            public String home() {
                                return "{}";
                            }

                            public String category(String id, int page) {
                                return "{}";
                            }

                            public String search(String q, int page) {
                                return "{}";
                            }

                            public boolean requiresExternalRuntime() {
                                return false;
                            }

                            public String detail(String id) throws Exception {
                                calls.incrementAndGet();
                                try {
                                    Thread.sleep(id.equals("slow") ? 4000 : 600);
                                } catch (InterruptedException e) {
                                    cancelled.incrementAndGet();
                                    throw e;
                                }
                                return response(id);
                            }
                        };
                runOnMainSync(
                        () -> {
                            if (a.startupIntro != null) a.startupIntro.cancel();
                            a.prefs = fixture;
                            a.config = new Cms.Config();
                            a.engines.put(s.key, source);
                            a.back.clear();
                        });
                if (args.getString("poster") != null) video.poster = args.getString("poster");
                report.put("first_ms", enter(s, video));
                await(() -> tag("episode:样本线路:49") != null);
                if (args.getString("poster") != null) {
                    await(
                            () ->
                                    ((ImmersivePoster) tag("detail-cover")).image.getDrawable()
                                            instanceof android.graphics.drawable.BitmapDrawable);
                    check(
                            "detail_poster_decodes_enough_pixels",
                            ui(
                                    () -> {
                                        ImmersivePoster cover =
                                                (ImmersivePoster) tag("detail-cover");
                                        android.graphics.Bitmap bitmap =
                                                ((android.graphics.drawable.BitmapDrawable)
                                                                cover.image.getDrawable())
                                                        .getBitmap();
                                        return bitmap.getWidth() >= cover.image.getWidth()
                                                && bitmap.getWidth() <= 1200
                                                && bitmap.getHeight() <= 1800;
                                    }));
                }
                check(
                        "episodes_share_poster_info_column",
                        ui(() -> tag("episode-full-title").getParent().getParent() != a.body));
                check(
                        "title_is_above_fixed_poster",
                        ui(
                                () -> {
                                    View title = tag("detail-title"), cover = tag("detail-cover");
                                    int[] t = new int[2], p = new int[2];
                                    title.getLocationOnScreen(t);
                                    cover.getLocationOnScreen(p);
                                    return title.getParent() == cover.getParent()
                                            && t[1] + title.getHeight() <= p[1];
                                }));
                check(
                        "line_buttons_are_inline",
                        ui(
                                () ->
                                        tag("detail-line:0") != null
                                                && tag("detail-line:1") != null
                                                && tag("detail-lines") == null));
                runOnMainSync(() -> tag("episode:样本线路:0").requestFocus());
                check(
                        "focused_episode_full_title",
                        ui(
                                () ->
                                        ((android.widget.TextView) tag("episode-full-title"))
                                                .getText()
                                                .toString()
                                                .contains("全部文字而不省略")));
                SystemClock.sleep(300);
                android.graphics.Bitmap image = getUiAutomation().takeScreenshot();
                if (image != null) {
                    try (java.io.FileOutputStream output =
                            new java.io.FileOutputStream(
                                    new java.io.File(
                                            a.getExternalFilesDir(null), "detail-0415.png"))) {
                        image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
                    }
                    image.recycle();
                }
                runOnMainSync(() -> tag("detail-line:1").performClick());
                await(() -> tag("episode:备用线路:0") != null);
                check(
                        "inline_line_switch_selected",
                        ui(() -> tag("detail-line:1").isSelected() && a.appDialog == null));
                runOnMainSync(() -> tag("detail-line:0").performClick());
                await(() -> tag("episode:样本线路:49") != null);
                final int[] posterY = {0};
                runOnMainSync(
                        () -> {
                            int[] point = new int[2];
                            tag("detail-cover").getLocationOnScreen(point);
                            posterY[0] = point[1];
                            tag("episode:样本线路:49").requestFocus();
                        });
                await(() -> ((TvScrollView) a.scroll).motion == null);
                check(
                        "only_detail_column_scrolls",
                        ui(
                                () -> {
                                    int[] point = new int[2];
                                    tag("detail-cover").getLocationOnScreen(point);
                                    return point[1] == posterY[0]
                                            && a.scroll.getScrollY() > 0
                                            && a.scroll == tag("detail-scroll");
                                }));
                check(
                        "fixed_poster_remains_visible",
                        ui(
                                () -> {
                                    android.graphics.Rect rect = new android.graphics.Rect();
                                    View cover = tag("detail-cover");
                                    return cover.getGlobalVisibleRect(rect)
                                            && rect.height() >= cover.getHeight() - 2;
                                }));
                runOnMainSync(
                        () -> {
                            a.current.episodeFocus = -1;
                            tag("episodes-order").performClick();
                        });
                await(() -> tag("episode:样本线路:150") != null);
                check(
                        "descending_starts_with_latest_episode",
                        ui(
                                () ->
                                        a.prefs.getBoolean("episodes_descending", false)
                                                && tag("episode:样本线路:199") != null
                                                && ((ViewGroup) tag("episode:样本线路:199").getParent())
                                                                .getChildAt(0)
                                                        == tag("episode:样本线路:199")));
                runOnMainSync(() -> tag("episodes-next").performClick());
                await(() -> tag("episode:样本线路:100") != null);
                check(
                        "descending_next_group_has_correct_range",
                        ui(
                                () ->
                                        tag("episode:样本线路:149") != null
                                                && tag("episode:样本线路:150") == null));
                runOnMainSync(() -> tag("episode:样本线路:123").requestFocus());
                runOnMainSync(() -> tag("episodes-order").performClick());
                await(() -> tag("episode:样本线路:49") != null && tag("episodes-order").hasFocus());
                check(
                        "order_changes_list_without_following_old_episode",
                        ui(
                                () ->
                                        !a.prefs.getBoolean("episodes_descending", true)
                                                && tag("episode:样本线路:0") != null
                                                && tag("episode:样本线路:123") == null));
                check("sort_focus_stays_on_control", ui(() -> tag("episodes-order").hasFocus()));
                report.put("repeat_ms", enter(s, video));
                report.put("detail_calls_after_repeat", calls.get());
                if (!"true".equals(args.getString("baseline"))) {
                    check("repeat_uses_cache", calls.get() == 1);
                    check("repeat_under_300ms", report.getLong("repeat_ms") < 300);
                    await(() -> tag("episode:样本线路:49") != null);
                    runOnMainSync(
                            () -> {
                                tag("episode:样本线路:49").requestFocus();
                                a.open(
                                        new MainActivity.Screen(() -> a.renderPage("返回测试", "")),
                                        true);
                                a.onBackPressed();
                            });
                    await(
                            () ->
                                    tag("episode:样本线路:49") != null
                                            && tag("episode:样本线路:49").hasFocus());
                    check("return_restores_late_episode_focus", true);
                    check("return_does_not_refetch", calls.get() == 1);
                    runOnMainSync(
                            () -> {
                                tag("detail-line:1").performClick();
                                tag("episodes-next").performClick();
                            });
                    await(() -> tag("episode:备用线路:99") != null);
                    runOnMainSync(
                            () -> {
                                tag("episode:备用线路:75").requestFocus();
                                a.open(
                                        new MainActivity.Screen(() -> a.renderPage("跨页返回测试", "")),
                                        true);
                                a.onBackPressed();
                            });
                    await(
                            () ->
                                    tag("episode:备用线路:75") != null
                                            && tag("episode:备用线路:75").hasFocus());
                    check("return_preserves_alternate_line_and_page_without_playback", true);
                    runOnMainSync(() -> tag("detail-line:0").performClick());
                    await(() -> tag("episode:样本线路:49") != null);
                    runOnMainSync(
                            () -> {
                                tag("detail-play").requestFocus();
                                a.scroll.scrollTo(0, 0);
                                tag("episode:样本线路:49").requestFocus();
                            });
                    check(
                            "secondary_uses_spring_scroll",
                            ui(
                                    () ->
                                            a.scroll instanceof TvScrollView
                                                    && ((TvScrollView) a.scroll).motion != null));
                    SystemClock.sleep(800);
                    final int[] positions = new int[2];
                    runOnMainSync(
                            () -> {
                                positions[0] = a.scroll.getScrollY();
                                a.scroll.executeKeyEvent(
                                        new KeyEvent(
                                                KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_UP));
                                positions[1] = a.scroll.getScrollY();
                            });
                    check("secondary_key_has_no_position_jump", positions[0] == positions[1]);

                    CountDownLatch occupied = new CountDownLatch(3);
                    for (int i = 0; i < 3; i++)
                        a.worker.execute(
                                () -> {
                                    occupied.countDown();
                                    try {
                                        release.await();
                                    } catch (InterruptedException ignored) {
                                    }
                                });
                    if (!occupied.await(5, TimeUnit.SECONDS))
                        throw new AssertionError("worker fixture");
                    Cms.Video second = new Cms.Video();
                    second.id = "second";
                    second.title = "独立调度";
                    report.put("busy_worker_detail_ms", enter(s, second));
                    release.countDown();
                    check(
                            "detail_not_queued_behind_general_workers",
                            report.getLong("busy_worker_detail_ms") < 2000);
                    Cms.Site resolving = new Cms.Site();
                    resolving.key = "detail-resolve";
                    resolving.type = 3;
                    resolving.api = "csp_Fixture";
                    final AtomicInteger playerCalls = new AtomicInteger();
                    a.engines.put(
                            resolving.key,
                            new SourceEngine() {
                                public String home() {
                                    return "{}";
                                }

                                public String category(String id, int page) {
                                    return "{}";
                                }

                                public String search(String q, int page) {
                                    return "{}";
                                }

                                public String detail(String id) {
                                    return "{}";
                                }

                                public boolean requiresExternalRuntime() {
                                    return true;
                                }

                                public String player(String flag, String id) throws Exception {
                                    playerCalls.incrementAndGet();
                                    try {
                                        Thread.sleep(1200);
                                    } catch (InterruptedException ignored) {
                                    }
                                    return new JSONObject()
                                            .put(
                                                    "url",
                                                    args.getString("base")
                                                            + (id.equals("parser")
                                                                    ? "resolve.html"
                                                                    : "h264-aac.mp4"))
                                            .put("parse", id.equals("parser") ? 1 : 0)
                                            .toString();
                                }
                            });
                    Cms.Line line = new Cms.Line();
                    line.name = "等待样本";
                    Cms.Episode episode = new Cms.Episode();
                    episode.name = "第1集";
                    episode.url = "opaque";
                    line.episodes.add(episode);
                    final MainActivity.Screen[] owner = {null};
                    final int[] stack = {0};
                    runOnMainSync(
                            () -> {
                                owner[0] = a.current;
                                stack[0] = a.back.size();
                                a.resolvePlayer(resolving, video, line, episode);
                            });
                    check(
                            "loading_keeps_details_and_back_stack",
                            ui(
                                    () ->
                                            a.current == owner[0]
                                                    && a.back.size() == stack[0]
                                                    && tag("playback-loading") != null
                                                    && tag("detail-cover") != null));
                    await(() -> playerCalls.get() > 0);
                    runOnMainSync(() -> a.onBackPressed());
                    check(
                            "back_cancels_loading",
                            ui(() -> tag("playback-loading") == null && a.current == owner[0]));
                    SystemClock.sleep(1400);
                    check(
                            "cancelled_result_cannot_start_playback",
                            ui(() -> a.player == null && a.current == owner[0]));
                    runOnMainSync(() -> a.resolvePlayer(resolving, video, line, episode));
                    await(() -> a.prepared);
                    check(
                            "loading_success_opens_player_once",
                            ui(
                                    () ->
                                            a.current.player
                                                    && a.back.size() == stack[0] + 1
                                                    && tag("playback-loading") == null));
                    cancelledEpisodeChange(resolving, line, episode);
                    runOnMainSync(() -> a.resolvePlayer(resolving, video, line, episode));
                    await(() -> a.prepared);
                    runOnMainSync(() -> a.leavePlayback());
                    episode.url = "parser";
                    runOnMainSync(() -> a.resolvePlayer(resolving, video, line, episode));
                    check(
                            "web_resolution_stays_on_details",
                            ui(
                                    () ->
                                            tag("detail-cover") != null
                                                    && tag("playback-loading") != null));
                    await(() -> a.prepared);
                    check(
                            "web_resolution_opens_player",
                            ui(() -> a.current.player && tag("playback-loading") == null));
                    runOnMainSync(() -> a.leavePlayback());
                    a.engines.remove(resolving.key);
                    Cms.Video slow = new Cms.Video();
                    slow.id = "slow";
                    slow.title = "已离开的样本";
                    runOnMainSync(
                            () -> a.open(new MainActivity.Screen(() -> a.detail(s, slow)), true));
                    SystemClock.sleep(150);
                    runOnMainSync(
                            () ->
                                    a.open(
                                            new MainActivity.Screen(() -> a.renderPage("已离开", "")),
                                            true));
                    SystemClock.sleep(150);
                    check("leaving_cancels_detail", cancelled.get() > 0);
                    check(
                            "late_detail_does_not_replace_page",
                            ui(() -> tag("detail-play") == null));
                }
                report.put("passed", true);
            }
        } catch (Throwable error) {
            try {
                report.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            release.countDown();
            if (a != null) {
                SharedPreferences p = original;
                Cms.Config cfg = old;
                runOnMainSync(
                        () -> {
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            if (p != null) a.prefs = p;
                            a.config = cfg;
                            a.engines.remove("detail-fixture");
                            a.back.clear();
                            a.renderPage("验证完成", "");
                            a.finish();
                        });
            }
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
