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

/** Synthetic layouts and source outcomes measured against the actual usable app window. */
public final class ResponsiveProbe extends Instrumentation {
    MainActivity a;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        start();
    }

    @Override
    public void callActivityOnCreate(Activity x, Bundle b) {
        if (x instanceof MainActivity) {
            try {
                android.content.Context base = x.getBaseContext();
                java.lang.reflect.Field field =
                        android.content.ContextWrapper.class.getDeclaredField("mBase");
                field.setAccessible(true);
                field.set(
                        x,
                        new ContextWrapper(base) {
                            public SharedPreferences getSharedPreferences(String name, int mode) {
                                return super.getSharedPreferences(
                                        name.equals("movie") ? "responsive_bootstrap" : name, mode);
                            }

                            public java.io.File getFilesDir() {
                                java.io.File f =
                                        new java.io.File(
                                                super.getCacheDir(), "responsive-empty-files");
                                f.mkdirs();
                                return f;
                            }
                        });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
        super.callActivityOnCreate(x, b);
        if (x instanceof MainActivity) {
            a = (MainActivity) x;
            a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            launched.countDown();
        }
    }

    boolean ui(Callable<Boolean> f) {
        boolean[] b = {false};
        runOnMainSync(
                () -> {
                    try {
                        b[0] = f.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return b[0];
    }

    void check(String key, boolean v) throws Exception {
        result.put(key, v);
        if (!v) throw new AssertionError(key);
    }

    void await(Callable<Boolean> f) throws Exception {
        long end = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(f)) return;
            SystemClock.sleep(50);
        }
        runOnMainSync(
                () -> {
                    View v = a.root;
                    StringBuilder info = new StringBuilder();
                    while (v != null) {
                        info.append(v.getClass().getSimpleName())
                                .append(" ")
                                .append(v.getWidth())
                                .append("x")
                                .append(v.getHeight())
                                .append(" measured ")
                                .append(v.getMeasuredWidth())
                                .append("x")
                                .append(v.getMeasuredHeight())
                                .append(" req ")
                                .append(v.isLayoutRequested())
                                .append(" visible ")
                                .append(v.getVisibility())
                                .append("; ");
                        v = v.getParent() instanceof View ? (View) v.getParent() : null;
                    }
                    try {
                        result.put("layout_tree", info.toString());
                    } catch (Exception ignored) {
                    }
                });
        throw new AssertionError(
                "layout wait ready="
                        + a.layoutReady
                        + " root="
                        + a.root.getWidth()
                        + "x"
                        + a.root.getHeight()
                        + " attached="
                        + a.root.isAttachedToWindow()
                        + " decor="
                        + a.getWindow().getDecorView().getWidth()
                        + " current="
                        + (a.current != null));
    }

    boolean visible(View v) {
        Rect r = new Rect();
        return v != null
                && v.getGlobalVisibleRect(r)
                && r.width() >= v.getWidth() - 2
                && r.height() >= v.getHeight() - 2;
    }

    String listing(boolean folder) throws Exception {
        JSONArray list = new JSONArray();
        for (int i = 0; i < 24; i++)
            list.put(
                    new JSONObject()
                            .put("vod_id", "item-" + i)
                            .put("vod_name", "布局样本 " + i)
                            .put("vod_pic", "")
                            .put("vod_tag", folder ? "folder" : ""));
        return new JSONObject().put("page", 1).put("pagecount", 1).put("list", list).toString();
    }

    @Override
    public void onStart() {
        Cms.Config original = null;
        SharedPreferences originalPrefs = null;
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            await(() -> a.layoutReady);
            original = a.config;
            originalPrefs = a.prefs;
            SharedPreferences prefs = context.getSharedPreferences("responsive_probe", 0);
            prefs.edit()
                    .clear()
                    .putString("selected_site", "responsive-0")
                    .putInt("home_columns", 5)
                    .putBoolean("startup_animation", false)
                    .commit();
            Cms.Config cfg = new Cms.Config();
            cfg.raw = "{}";
            final int[] retryCalls = {0};
            for (int i = 0; i < 3; i++) {
                Cms.Site site = new Cms.Site();
                site.key = "responsive-" + i;
                site.name = i == 0 ? "目录搜索" : i == 1 ? "失败重试" : "空结果";
                site.api = "https://fixture.test/api";
                site.type = 1;
                cfg.sites.add(site);
                final int index = i;
                a.engines.put(
                        site.key,
                        new SourceEngine() {
                            public String home() throws Exception {
                                return listing(false);
                            }

                            public String category(String id, int page) throws Exception {
                                return listing(false);
                            }

                            public String detail(String id) throws Exception {
                                return listing(false);
                            }

                            public String search(String query, int page) throws Exception {
                                if (index == 1 && retryCalls[0]++ == 0)
                                    throw new java.io.IOException("fixture failure");
                                return index == 2 ? "{\"list\":[]}" : listing(true);
                            }

                            public boolean requiresExternalRuntime() {
                                return false;
                            }
                        });
            }
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.prefs = prefs;
                        a.config = cfg;
                        a.open(new MainActivity.Screen(a::home), false);
                    });
            await(
                    () ->
                            a.root.findViewWithTag("home-video:0") != null
                                    && a.root.getWidth() > 0
                                    && a.root.findViewWithTag("home-video:0").getWidth() > 0);
            SystemClock.sleep(300);
            int width = a.root.getWidth(),
                    height = a.root.getHeight(),
                    dpi = a.getResources().getDisplayMetrics().densityDpi;
            result.put("width", width)
                    .put("height", height)
                    .put("density_dpi", dpi)
                    .put("logical_width", width * 160f / dpi)
                    .put("logical_height", height * 160f / dpi);
            check(
                    "density_matches_usable_window",
                    Math.abs(dpi - TvLayoutPolicy.densityDpi(width, height, 100)) <= 1);
            check("logo_visible", ui(() -> visible(a.root.findViewWithTag("home-brand"))));
            check(
                    "source_button_visible",
                    ui(() -> visible(a.root.findViewWithTag("source-switcher"))));
            check(
                    "home_first_row_posters_fit",
                    ui(
                            () -> {
                                ViewGroup row =
                                        (ViewGroup)
                                                a.root.findViewWithTag("home-video:0").getParent();
                                for (int i = 0; i < row.getChildCount(); i++) {
                                    View card = row.getChildAt(i);
                                    if (card instanceof ViewGroup) {
                                        View poster = ((ViewGroup) card).getChildAt(0);
                                        if (poster.getWidth() > card.getWidth()) return false;
                                    }
                                }
                                return true;
                            }));
            runOnMainSync(
                    () -> {
                        a.globalSearchDialog();
                        a.searchScreen.keyboard.set("样本");
                        a.searchScreen.changed();
                        a.searchScreen.submit(false);
                    });
            await(() -> a.searchScreen.finished == 3 && a.searchScreen.displayed.size() == 12);
            await(
                    () -> {
                        for (LinearLayout card : a.searchScreen.posterCards.values())
                            if (card.getParent() != null
                                    && (card.getWidth() == 0 || card.getChildAt(0).getWidth() == 0))
                                return false;
                        return true;
                    });
            check(
                    "failed_source_stays_visible",
                    ui(() -> a.searchScreen.filterButtons.containsKey("responsive-1")));
            check(
                    "empty_source_stays_visible",
                    ui(() -> a.searchScreen.filterButtons.containsKey("responsive-2")));
            check(
                    "search_posters_fit_cells",
                    ui(
                            () -> {
                                for (LinearLayout card : a.searchScreen.posterCards.values()) {
                                    if (card.getParent() != null
                                            && card.getChildAt(0).getWidth()
                                                            + card.getPaddingLeft()
                                                            + card.getPaddingRight()
                                                    > card.getWidth()) return false;
                                }
                                return true;
                            }));
            runOnMainSync(() -> a.root.findViewWithTag("search-submit").requestFocus());
            SystemClock.sleep(400);
            check(
                    "keyboard_submit_scrolls_into_view",
                    ui(() -> visible(a.root.findViewWithTag("search-submit"))));
            runOnMainSync(() -> a.searchScreen.filterButtons.get("responsive-1").performClick());
            await(() -> a.searchScreen.retrySource.isShown());
            check(
                    "failure_is_not_reported_empty",
                    ui(() -> a.searchScreen.emptyResult.getText().toString().contains("请求失败")));
            runOnMainSync(() -> a.searchScreen.retrySource.performClick());
            await(
                    () ->
                            a.searchScreen.results.get("responsive-1").outcome
                                            == SearchCoordinator.Outcome.RESULT
                                    && a.searchScreen.displayed.size() == 24);
            check("single_source_retry_recovers", true);
            check(
                    "other_source_results_preserved",
                    ui(() -> a.searchScreen.results.get("responsive-0").videos.size() == 24));
            runOnMainSync(() -> a.searchScreen.filterButtons.get("responsive-0").performClick());
            await(() -> a.searchScreen.displayed.size() == 24);
            runOnMainSync(
                    () ->
                            a.searchScreen
                                    .posterCards
                                    .get(a.searchScreen.displayed.iterator().next())
                                    .performClick());
            await(() -> a.root.findViewWithTag("primary") != null);
            check(
                    "folder_result_opens_source_category",
                    ui(
                            () ->
                                    a.searchScreen == null
                                            && a.root.findViewWithTag("detail-loading") == null));
            result.put("passed", true);
        } catch (Throwable e) {
            try {
                result.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                Cms.Config cfg = original;
                SharedPreferences prefs = originalPrefs;
                runOnMainSync(
                        () -> {
                            if (a.searchScreen != null) a.searchScreen.close();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.config = cfg;
                            if (prefs != null) a.prefs = prefs;
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
        }
        Bundle b = new Bundle();
        b.putString("result", result.toString());
        sendStatus(0, b);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
