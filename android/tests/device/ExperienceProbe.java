package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Isolated synthetic search bursts, input responsiveness and manual history playback. */
public final class ExperienceProbe extends Instrumentation {
    MainActivity a;
    Bundle args;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject report = new JSONObject();
    final AtomicInteger searches = new AtomicInteger();

    @Override
    public void onCreate(Bundle input) {
        super.onCreate(input);
        args = input;
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
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = fn.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return value[0];
    }

    void check(String name, boolean value) throws Exception {
        report.put(name, value);
        if (!value) throw new AssertionError(name);
    }

    boolean within(Callable<Boolean> fn, int ms) {
        long end = SystemClock.elapsedRealtime() + ms;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(fn)) return true;
            SystemClock.sleep(30);
        }
        return ui(fn);
    }

    void await(Callable<Boolean> fn, int ms) throws Exception {
        long end = SystemClock.elapsedRealtime() + ms;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(fn)) return;
            SystemClock.sleep(30);
        }
        throw new AssertionError("timeout");
    }

    GlobalSearchScreen screen() {
        return a.searchScreen;
    }

    View tag(String value) {
        return a.root.findViewWithTag(value);
    }

    String listing(String prefix) throws Exception {
        JSONArray list = new JSONArray();
        for (int i = 0; i < 12; i++)
            list.put(
                    new JSONObject()
                            .put("vod_id", prefix + "-" + i)
                            .put("vod_name", prefix + " · " + i)
                            .put("vod_pic", ""));
        return new JSONObject().put("list", list).toString();
    }

    @Override
    public void onStart() {
        SharedPreferences original = null;
        Cms.Config old = null;
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            original = a.prefs;
            old = a.config;
            SharedPreferences fixture = context.getSharedPreferences("experience_probe_fixture", 0);
            fixture.edit()
                    .clear()
                    .putBoolean("startup_animation", false)
                    .putInt("search_threads", 6)
                    .commit();
            final Cms.Site[] first = {null};
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.back.clear();
                        Cms.Config config = new Cms.Config();
                        config.raw = "{}";
                        for (int i = 0; i < 40; i++) {
                            final int number = i;
                            Cms.Site site = new Cms.Site();
                            site.key = "experience-" + i;
                            site.name = "体验样本 " + i;
                            site.type = 1;
                            site.api = "https://fixture.test/api";
                            site.searchable = true;
                            config.sites.add(site);
                            if (i == 0) first[0] = site;
                            a.engines.put(
                                    site.key,
                                    new SourceEngine() {
                                        public String home() throws Exception {
                                            return listing("首页");
                                        }

                                        public String category(String id, int page)
                                                throws Exception {
                                            return listing("分类");
                                        }

                                        public String search(String query, int page)
                                                throws Exception {
                                            searches.incrementAndGet();
                                            Thread.sleep(number < 6 ? number * 10 : 20);
                                            return listing(query + "-" + number);
                                        }

                                        public boolean requiresExternalRuntime() {
                                            return false;
                                        }

                                        public String detail(String id) throws Exception {
                                            return new JSONObject()
                                                    .put(
                                                            "list",
                                                            new JSONArray()
                                                                    .put(
                                                                            new JSONObject()
                                                                                    .put(
                                                                                            "vod_id",
                                                                                            id)
                                                                                    .put(
                                                                                            "vod_name",
                                                                                            "体验验证")
                                                                                    .put(
                                                                                            "vod_pic",
                                                                                            "")
                                                                                    .put(
                                                                                            "vod_content",
                                                                                            "合成样本，不包含实际影视资源")
                                                                                    .put(
                                                                                            "vod_play_from",
                                                                                            "线路A$$$线路B")
                                                                                    .put(
                                                                                            "vod_play_url",
                                                                                            "第1集$"
                                                                                                    + args
                                                                                                            .getString(
                                                                                                                    "base")
                                                                                                    + "h264-aac.mp4$$$第1集$"
                                                                                                    + args
                                                                                                            .getString(
                                                                                                                    "base")
                                                                                                    + "h264-aac.mp4#第2集$"
                                                                                                    + args
                                                                                                            .getString(
                                                                                                                    "base")
                                                                                                    + "h264-aac.mp4")))
                                                    .toString();
                                        }
                                    });
                        }
                        a.config = config;
                        a.globalSearchDialog();
                    });
            await(() -> a.phonetic != null, 15000);
            GlobalSearchScreen search = screen();
            runOnMainSync(
                    () -> {
                        search.keyboard.set("体验");
                        search.changed();
                        search.submit(false);
                    });
            await(() -> search.displayed.size() >= 4, 10000);
            final View[] firstCard = {null};
            runOnMainSync(
                    () -> {
                        firstCard[0] = search.posterCards.get(search.displayed.iterator().next());
                        firstCard[0].requestFocus();
                    });
            await(() -> search.finished == 40 && search.displayed.size() == 24, 15000);
            check(
                    "all_40_sources_participate",
                    search.results.size() == 40 && search.busy == 0 && search.failed == 0);
            check(
                    "initial_batch_is_24",
                    search.displayed.size() == 24 && search.posterCards.size() == 24);
            check("more_available", ui(() -> search.moreResults.isShown()));
            check(
                    "result_focus_stable_during_arrivals",
                    ui(() -> a.getCurrentFocus() == firstCard[0]));
            check("existing_card_not_recreated", search.posterCards.containsValue(firstCard[0]));
            check("all_filter_buttons_present", search.filterButtons.size() == 41);
            Button allFilter = search.filterButtons.get("");
            Button sourceFilter = search.filterButtons.get("experience-0");
            check(
                    "source_buttons_have_visible_idle_fill",
                    ui(() -> FocusMotion.state(sourceFilter).targetColor == 0xff272f3a));
            check(
                    "selected_source_is_persistent",
                    ui(
                            () ->
                                    allFilter.isSelected()
                                            && !sourceFilter.isSelected()
                                            && FocusMotion.state(allFilter).targetColor
                                                    == 0xff465c76));
            check(
                    "source_text_centered",
                    ui(
                            () ->
                                    sourceFilter.getGravity() == Gravity.CENTER
                                            && !sourceFilter.getIncludeFontPadding()));
            check(
                    "source_button_fits_strip",
                    ui(
                            () ->
                                    sourceFilter.getHeight() == a.dp(34)
                                            && sourceFilter.getTop() >= a.dp(4)
                                            && sourceFilter.getBottom()
                                                    <= search.sourceFilters.getHeight() - a.dp(4)));
            runOnMainSync(() -> sourceFilter.requestFocus());
            SystemClock.sleep(120);
            check(
                    "source_focus_animating_midway",
                    ui(() -> sourceFilter.getScaleX() > 1f && sourceFilter.getScaleX() < 1.04f));
            check(
                    "source_focus_is_white_and_animated",
                    within(
                            () ->
                                    FocusMotion.state(sourceFilter).color == MainActivity.WHITE
                                            && sourceFilter.getScaleX() > 1.025f,
                            800));
            check(
                    "focus_does_not_change_selection",
                    ui(
                            () ->
                                    allFilter.isSelected()
                                            && !sourceFilter.isSelected()
                                            && search.activeFilter.isEmpty()));
            runOnMainSync(() -> sourceFilter.performClick());
            await(() -> search.displayed.size() == 12, 5000);
            check(
                    "confirm_changes_selected_source",
                    ui(
                            () ->
                                    sourceFilter.isSelected()
                                            && !allFilter.isSelected()
                                            && search.activeFilter.equals("experience-0")));
            runOnMainSync(() -> allFilter.requestFocus());
            check(
                    "selected_source_stays_blue_when_unfocused",
                    within(
                            () ->
                                    FocusMotion.state(sourceFilter).color == 0xff465c76
                                            && sourceFilter.isSelected(),
                            800));
            runOnMainSync(() -> search.filterButtons.get("experience-39").requestFocus());
            SystemClock.sleep(400);
            check(
                    "focused_late_source_scrolls_into_view",
                    ui(
                            () -> {
                                View late = search.filterButtons.get("experience-39");
                                android.graphics.Rect bounds = new android.graphics.Rect();
                                return late.getGlobalVisibleRect(bounds)
                                        && bounds.width() >= late.getWidth() - a.dp(3);
                            }));
            runOnMainSync(() -> allFilter.performClick());
            await(() -> search.displayed.size() == 24, 5000);
            runOnMainSync(
                    () -> {
                        android.graphics.Bitmap image =
                                android.graphics.Bitmap.createBitmap(
                                        a.root.getWidth(),
                                        a.root.getHeight(),
                                        android.graphics.Bitmap.Config.ARGB_8888);
                        a.root.draw(new android.graphics.Canvas(image));
                        try (java.io.FileOutputStream out =
                                new java.io.FileOutputStream(
                                        new java.io.File(
                                                a.getExternalFilesDir(null),
                                                "search-source-buttons.png"))) {
                            image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out);
                        } catch (Exception error) {
                            throw new RuntimeException(error);
                        } finally {
                            image.recycle();
                        }
                    });
            runOnMainSync(() -> search.moreResults.performClick());
            await(() -> search.displayed.size() == 48, 5000);
            check("load_more_appends_24", search.displayed.size() == 48);
            check(
                    "load_more_preserves_existing_card",
                    search.posterCards.containsValue(firstCard[0]));
            check(
                    "load_more_focuses_new_card",
                    ui(
                            () ->
                                    a.getCurrentFocus() != firstCard[0]
                                            && String.valueOf(a.getCurrentFocus().getTag())
                                                    .startsWith("global-result:")));
            for (int limit = 72; limit <= 120; limit += 24) {
                final int expected = limit;
                runOnMainSync(() -> search.moreResults.performClick());
                await(() -> search.displayed.size() == expected, 5000);
            }
            check("all_view_is_bounded_at_120", search.displayed.size() == 120);
            check(
                    "result_limit_has_clear_hint",
                    ui(() -> search.resultHint.isShown() && !search.moreResults.isShown()));
            runOnMainSync(() -> search.filterButtons.get("experience-39").performClick());
            await(() -> search.displayed.size() == 12, 5000);
            check(
                    "late_source_filter_works",
                    ui(() -> search.displayed.iterator().next().startsWith("experience-39:")));
            runOnMainSync(() -> search.filterButtons.get("").performClick());
            await(() -> search.displayed.size() == 24, 5000);
            final View[] selected = {null};
            final int beforeDetail = searches.get();
            runOnMainSync(
                    () -> {
                        selected[0] = search.posterCards.get(search.displayed.iterator().next());
                        selected[0].requestFocus();
                        selected[0].performClick();
                    });
            await(() -> tag("detail-play") != null, 5000);
            check(
                    "search_result_opens_details_without_playback",
                    ui(() -> a.player == null && !a.current.player));
            runOnMainSync(() -> a.onBackPressed());
            await(() -> screen() == search && search.displayed.size() == 24, 5000);
            check(
                    "back_reuses_search_results",
                    searches.get() == beforeDetail && search.results.size() == 40);
            check(
                    "back_restores_result_focus",
                    ui(
                            () ->
                                    String.valueOf(a.getCurrentFocus().getTag())
                                            .equals(String.valueOf(selected[0].getTag()))));
            CountDownLatch locked = new CountDownLatch(1);
            Thread holder =
                    new Thread(
                            () -> {
                                synchronized (a.phonetic) {
                                    locked.countDown();
                                    SystemClock.sleep(400);
                                }
                            });
            holder.start();
            if (!locked.await(2, TimeUnit.SECONDS)) throw new AssertionError("index lock");
            final long[] submitMs = {0};
            runOnMainSync(
                    () -> {
                        long start = SystemClock.elapsedRealtime();
                        search.keyboard.set("santi");
                        search.changed();
                        search.submit(false);
                        submitMs[0] = SystemClock.elapsedRealtime() - start;
                    });
            report.put("input_and_submit_with_busy_index_ms", submitMs[0]);
            check("busy_phonetic_index_does_not_block_ui", submitMs[0] < 180);
            holder.join();
            await(() -> search.finished == 40 && search.displayed.size() == 24, 15000);
            long[] candidateEdits = new long[30];
            runOnMainSync(
                    () -> {
                        search.keyboard.clear();
                        search.keyboard.mode(PinyinKeyboardModel.Mode.PINYIN);
                        for (int i = 0; i < candidateEdits.length; i++) {
                            if (i % 5 == 0) search.keyboard.clear();
                            long start = SystemClock.elapsedRealtimeNanos();
                            search.keyboard.input(i % 2 == 0 ? "s" : "a");
                            search.changed();
                            candidateEdits[i] =
                                    (SystemClock.elapsedRealtimeNanos() - start) / 1000000;
                        }
                    });
            Arrays.sort(candidateEdits);
            report.put("pinyin_edit_p95_ms", candidateEdits[28])
                    .put("pinyin_edit_max_ms", candidateEdits[29]);
            check("candidate_input_stays_responsive", candidateEdits[29] < 180);
            long[] edits = new long[30];
            runOnMainSync(
                    () -> {
                        for (int i = 0; i < edits.length; i++) {
                            long start = SystemClock.elapsedRealtimeNanos();
                            search.keyboard.set("体验" + i);
                            search.changed();
                            edits[i] = (SystemClock.elapsedRealtimeNanos() - start) / 1000000;
                        }
                    });
            Arrays.sort(edits);
            report.put("rapid_edit_p95_ms", edits[28]).put("rapid_edit_max_ms", edits[29]);
            check("rapid_input_stays_responsive", edits[29] < 180);
            check("old_cards_retained_while_typing", search.displayed.size() == 24);
            int callsBefore = searches.get();
            SystemClock.sleep(200);
            check("typing_debounce_prevents_immediate_requests", searches.get() == callsBefore);
            await(
                    () ->
                            search.finished == 40
                                    && search.submitted.equals("体验29")
                                    && search.displayed.size() == 24,
                    15000);
            check(
                    "latest_query_owns_results",
                    ui(
                            () ->
                                    search.results
                                            .values()
                                            .iterator()
                                            .next()
                                            .videos
                                            .get(0)
                                            .title
                                            .startsWith("体验29")));
            runOnMainSync(
                    () -> {
                        search.keyboard.clear();
                        search.changed();
                    });
            check(
                    "clear_removes_stale_results",
                    ui(
                            () ->
                                    search.results.isEmpty()
                                            && search.posterCards.isEmpty()
                                            && search.resultBody.getChildCount() > 0));
            WatchHistory.Entry bookmark = new WatchHistory.Entry();
            bookmark.site = first[0].key;
            bookmark.id = "remembered";
            bookmark.title = "历史样本";
            bookmark.poster = "";
            bookmark.line = "线路B";
            bookmark.episode = "第2集";
            bookmark.index = 1;
            bookmark.position = 5000;
            bookmark.duration = 30000;
            bookmark.updated = System.currentTimeMillis();
            fixture.edit().putString("watch_history", WatchHistory.upsert("[]", bookmark)).commit();
            runOnMainSync(() -> a.resumeHistory(bookmark));
            await(() -> tag("detail-play") != null, 5000);
            SystemClock.sleep(350);
            check(
                    "continue_opens_details_not_fullscreen",
                    ui(() -> a.player == null && !a.current.player && tag("detail-cover") != null));
            check(
                    "details_show_saved_progress",
                    ui(
                            () ->
                                    tag("detail-history") != null
                                            && ((TextView) tag("detail-history"))
                                                    .getText()
                                                    .toString()
                                                    .contains("00:05")));
            check(
                    "details_show_saved_line",
                    ui(() -> tag("episode:线路B:1") != null && tag("episode:线路A:0") == null));
            check("manual_continue_focused", ui(() -> tag("detail-play").hasFocus()));
            runOnMainSync(() -> tag("detail-play").performClick());
            await(() -> a.prepared, 20000);
            check(
                    "manual_continue_enters_fullscreen",
                    ui(() -> a.current.player && !a.miniMode && a.player != null));
            check(
                    "manual_continue_uses_saved_episode",
                    ui(
                            () ->
                                    a.activeLine.name.equals("线路B")
                                            && a.activeEpisode.name.equals("第2集")));
            await(() -> a.player.getCurrentPosition() >= 4500, 5000);
            check(
                    "manual_continue_restores_position",
                    ui(() -> a.player.getCurrentPosition() >= 4500));
            report.put("passed", true);
        } catch (Throwable error) {
            try {
                report.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                SharedPreferences saved = original;
                Cms.Config config = old;
                runOnMainSync(
                        () -> {
                            if (a.searchScreen != null) a.searchScreen.close();
                            a.releasePlayer();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.prefs = saved;
                            a.config = config;
                            a.engines.keySet().removeIf(key -> key.startsWith("experience-"));
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
