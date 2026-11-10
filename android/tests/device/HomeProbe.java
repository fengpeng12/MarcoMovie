package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.graphics.*;
import java.io.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic source with a separate preference file; never writes user playback records. */
public final class HomeProbe extends Instrumentation {
    MainActivity a;
    volatile boolean failAnimeCategory;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();
    final java.util.concurrent.atomic.AtomicInteger homeRequests =
            new java.util.concurrent.atomic.AtomicInteger();
    final java.util.concurrent.atomic.AtomicInteger categoryRequests =
            new java.util.concurrent.atomic.AtomicInteger();
    volatile java.util.Map<String, String> receivedFilters = new java.util.LinkedHashMap<>();

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

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    boolean ui(Callable<Boolean> call) {
        boolean[] out = {false};
        runOnMainSync(
                () -> {
                    try {
                        out[0] = call.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return out[0];
    }

    void check(String name, boolean value) throws Exception {
        result.put(name, value);
        if (!value) throw new AssertionError(name);
    }

    View tag(String name) {
        return a.root.findViewWithTag(name);
    }

    void await(Callable<Boolean> condition) throws Exception {
        long end = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(condition)) return;
            SystemClock.sleep(80);
        }
        throw new AssertionError("Wait timed out");
    }

    void click(String name) {
        runOnMainSync(
                () -> {
                    View v = tag(name);
                    if (v == null) throw new AssertionError(name);
                    v.requestFocus();
                    v.performClick();
                });
        SystemClock.sleep(200);
    }

    void key(int code) {
        long end = SystemClock.elapsedRealtime() + 5000;
        while (SystemClock.elapsedRealtime() < end
                && !ui(
                        () ->
                                a.hasWindowFocus()
                                        || a.appDialog != null
                                        || a.sourceDialog != null
                                                && a.sourceDialog
                                                        .getWindow()
                                                        .getDecorView()
                                                        .hasWindowFocus())) SystemClock.sleep(100);
        if (!ui(
                () ->
                        a.hasWindowFocus()
                                || a.appDialog != null
                                || a.sourceDialog != null
                                        && a.sourceDialog
                                                .getWindow()
                                                .getDecorView()
                                                .hasWindowFocus()))
            throw new AssertionError("Application lost window focus");
        sendKeyDownUpSync(code);
        SystemClock.sleep(300);
    }

    void pacedUp() {
        key(KeyEvent.KEYCODE_DPAD_UP);
        SystemClock.sleep(300);
    }

    void fastUp() {
        sendKeyDownUpSync(KeyEvent.KEYCODE_DPAD_UP);
        SystemClock.sleep(70);
    }

    boolean noNav() {
        return tag("nav-home") == null && tag("nav-settings") == null && tag("nav-search") == null;
    }

    void frame(String name) {
        runOnMainSync(
                () -> {
                    Bitmap b =
                            Bitmap.createBitmap(
                                    a.root.getWidth(), a.root.getHeight(), Bitmap.Config.ARGB_8888);
                    a.root.draw(new Canvas(b));
                    try (FileOutputStream out =
                            new FileOutputStream(
                                    new File(
                                            a.getExternalFilesDir(null),
                                            "home-" + name + ".png"))) {
                        b.compress(Bitmap.CompressFormat.PNG, 100, out);
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    } finally {
                        b.recycle();
                    }
                });
    }

    String listing(String prefix, int count, int page) throws Exception {
        JSONArray list = new JSONArray();
        for (int i = 0; i < count; i++)
            list.put(
                    new JSONObject()
                            .put("vod_id", prefix + "-" + page + "-" + i)
                            .put("vod_name", prefix + " · " + (i + 1))
                            .put("vod_pic", "https://fixture.test/poster.png")
                            .put("vod_remarks", "合成样本"));
        return new JSONObject().put("page", page).put("pagecount", 2).put("list", list).toString();
    }

    boolean fullLabel(TextView label) {
        android.text.Layout layout = label.getLayout();
        if (layout == null || layout.getLineCount() == 0) return false;
        for (int i = 0; i < layout.getLineCount(); i++)
            if (layout.getEllipsisCount(i) != 0) return false;
        return layout.getLineEnd(layout.getLineCount() - 1) == label.getText().length()
                && layout.getHeight()
                        <= label.getHeight()
                                - label.getCompoundPaddingTop()
                                - label.getCompoundPaddingBottom();
    }

    @Override
    public void onStart() {
        Cms.Config original = null;
        String history = null, selected = null;
        Integer columns = null;
        boolean hadHistory = false, hadSelected = false;
        try {
            Context context = getTargetContext();
            SharedPreferences before = context.getSharedPreferences("movie", 0);
            Bundle inspection = new Bundle();
            inspection.putInt(
                    "history_entries_before",
                    WatchHistory.read(before.getString("watch_history", "[]")).size());
            inspection.putBoolean(
                    "synthetic_selected_before",
                    before.getString("selected_site", "").equals("home-fixture"));
            sendStatus(1, inspection);
            // Exercise a separate preference file; a process crash cannot overwrite user records.
            SharedPreferences fixture = context.getSharedPreferences("home_probe_fixture", 0);
            SharedPreferences.Editor copy = fixture.edit().clear();
            for (java.util.Map.Entry<String, ?> e : before.getAll().entrySet()) {
                Object value = e.getValue();
                if (value instanceof String) copy.putString(e.getKey(), (String) value);
                else if (value instanceof Integer) copy.putInt(e.getKey(), (Integer) value);
                else if (value instanceof Boolean) copy.putBoolean(e.getKey(), (Boolean) value);
                else if (value instanceof Long) copy.putLong(e.getKey(), (Long) value);
                else if (value instanceof Float) copy.putFloat(e.getKey(), (Float) value);
            }
            copy.commit();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        if (a.startupIntro != null) a.startupIntro.cancel();
                    });
            original = a.config;
            history = a.prefs.getString("watch_history", "[]");
            selected = a.prefs.getString("selected_site", "");
            hadHistory = a.prefs.contains("watch_history");
            hadSelected = a.prefs.contains("selected_site");
            if (a.prefs.contains("home_columns")) columns = a.prefs.getInt("home_columns", 5);
            Cms.Site site = new Cms.Site();
            site.key = "home-fixture";
            site.name = "测试片库";
            site.api = "https://fixture.test/api";
            site.type = 1;
            Bitmap art = Bitmap.createBitmap(300, 450, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(art);
            Paint p = new Paint(3);
            p.setShader(
                    new LinearGradient(
                            0, 0, 300, 450, 0xff42636a, 0xff272b35, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, 300, 450, p);
            p.setShader(null);
            p.setColor(0xffd4d2c4);
            canvas.drawCircle(150, 130, 72, p);
            p.setColor(Color.WHITE);
            p.setTextSize(28);
            p.setTextAlign(Paint.Align.CENTER);
            canvas.drawText("山海之间", 150, 340, p);
            a.images.put("https://fixture.test/poster.png", art);
            JSONArray records = new JSONArray();
            for (int i = 0; i < 4; i++) {
                WatchHistory.Entry e = new WatchHistory.Entry();
                e.site = site.key;
                e.id = "history-" + i;
                e.title = "继续观看 · " + (i + 1);
                e.poster = "https://fixture.test/poster.png";
                e.episode = "第 6 集";
                e.line = "样本";
                e.position = 1200000;
                e.duration = 2400000;
                e.updated = System.currentTimeMillis();
                records.put(e.json());
            }
            final String savedRecords = records.toString();
            runOnMainSync(
                    () -> {
                        Cms.Config config = new Cms.Config();
                        config.raw = "{}";
                        config.sites.add(site);
                        a.config = config;
                        a.prefs
                                .edit()
                                .putBoolean("wallpaper_enabled", false)
                                .putBoolean("home_ambient", true)
                                .putString("selected_site", site.key)
                                .putString("watch_history", savedRecords)
                                .remove("home_columns")
                                .commit();
                        a.engines.put(
                                site.key,
                                new SourceEngine() {
                                    public String home() throws Exception {
                                        homeRequests.incrementAndGet();
                                        JSONObject o = new JSONObject(listing("推荐", 12, 1));
                                        JSONObject schemas = new JSONObject();
                                        JSONArray dimensions = new JSONArray();
                                        for (String[] item :
                                                new String[][] {
                                                    {"class", "类型", "剧情"},
                                                    {"area", "地区", "美国"},
                                                    {"year", "年份", "2026"}
                                                }) {
                                            dimensions.put(
                                                    new JSONObject()
                                                            .put("key", item[0])
                                                            .put("name", item[1])
                                                            .put(
                                                                    "value",
                                                                    new JSONArray()
                                                                            .put(
                                                                                    new JSONObject()
                                                                                            .put(
                                                                                                    "n",
                                                                                                    item[
                                                                                                            2])
                                                                                            .put(
                                                                                                    "v",
                                                                                                    item[
                                                                                                            2]))));
                                        }
                                        o.put("filters", schemas.put("c2", dimensions));
                                        JSONArray cats = new JSONArray();
                                        for (int i = 1; i <= 7; i++)
                                            cats.put(
                                                    new JSONObject()
                                                            .put("type_id", "c" + i)
                                                            .put(
                                                                    "type_name",
                                                                    new String[] {
                                                                                "豆瓣电影Top250",
                                                                                "电视剧",
                                                                                "动漫",
                                                                                "纪录片：自然地理、科学探索、人文历史与世界各地的真实故事，还有更多值得细看的精彩内容，分类名称完整展示验证，超长分类应自动增加高度并显示全部文字，不能通过省略号隐藏后半部分，也不能横向溢出或遮住右侧导航",
                                                                                "综艺",
                                                                                "其他",
                                                                                "空分类：这个分类的名称很长，用来验证更多分类弹窗与选中后的完整标题展示，不应隐藏任何文字"
                                                                            }
                                                                            [i - 1]));
                                        return o.put("class", cats).toString();
                                    }

                                    public String category(
                                            String id,
                                            int page,
                                            java.util.Map<String, String> filters)
                                            throws Exception {
                                        receivedFilters = new java.util.LinkedHashMap<>(filters);
                                        return category(id, page);
                                    }

                                    public String category(String id, int page) throws Exception {
                                        categoryRequests.incrementAndGet();
                                        if (id.equals("c1")) SystemClock.sleep(850);
                                        if (id.equals("c3") && failAnimeCategory) {
                                            failAnimeCategory = false;
                                            throw new IOException("fixture failure");
                                        }
                                        return listing(
                                                id, id.equals("c7") ? 0 : page == 1 ? 12 : 3, page);
                                    }

                                    public String search(String q, int page) throws Exception {
                                        return listing(q, 2, 1);
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
                                                                                .put("vod_id", id)
                                                                                .put(
                                                                                        "vod_name",
                                                                                        "详情样本")
                                                                                .put(
                                                                                        "vod_pic",
                                                                                        "https://fixture.test/poster.png")
                                                                                .put(
                                                                                        "vod_content",
                                                                                        "用于检查返回后分类、焦点与位置恢复。")
                                                                                .put(
                                                                                        "vod_play_from",
                                                                                        "样本")
                                                                                .put(
                                                                                        "vod_play_url",
                                                                                        "第 1 集$https://fixture.test/sample.mp4")))
                                                .toString();
                                    }
                                });
                        a.back.clear();
                        a.open(new MainActivity.Screen(a::home), false);
                    });
            await(() -> tag("home-video:11") != null);
            SystemClock.sleep(300);
            check(
                    "initial_category_is_recommended",
                    ui(
                            () ->
                                    a.current.homeState.category.isEmpty()
                                            && tag("home-tab:0").isSelected()));
            check("initial_focus_on_recommended", ui(() -> tag("home-tab:0").hasFocus()));
            // Dispatch through the Activity: home navigation consumes these keys before
            // any tab OnKeyListener. No confirmation key should be needed to switch.
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            await(() -> a.current.homeState.category.equals("c1"));
            check("right_focus_selects_movie", ui(() -> tag("home-tab:1").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            check(
                    "right_focus_selects_series_content",
                    ui(
                            () ->
                                    tag("home-tab:2").hasFocus()
                                            && a.current
                                                    .homeState
                                                    .videos
                                                    .get(0)
                                                    .title
                                                    .startsWith("c2")));
            SystemClock.sleep(900);
            check(
                    "focus_switch_rejects_late_movie_content",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c2")
                                            && a.current
                                                    .homeState
                                                    .videos
                                                    .get(0)
                                                    .title
                                                    .startsWith("c2")));
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c1"));
            check("left_focus_selects_movie", ui(() -> tag("home-tab:1").hasFocus()));
            SystemClock.sleep(400);
            runOnMainSync(() -> tag("home-tab:2").requestFocus());
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            check(
                    "focus_without_recent_key_selects_category",
                    ui(() -> tag("home-tab:2").hasFocus()));
            int requestsAfterFocus = categoryRequests.get();
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "confirm_after_focus_does_not_reload",
                    categoryRequests.get() == requestsAfterFocus);
            runOnMainSync(
                    () -> {
                        tag("home-tab:1").requestFocus();
                        tag("source-switcher").requestFocus();
                    });
            SystemClock.sleep(250);
            check(
                    "leaving_category_cancels_pending_selection",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c2")
                                            && tag("source-switcher").hasFocus()));
            runOnMainSync(() -> tag("home-filters").requestFocus());
            SystemClock.sleep(250);
            check(
                    "filter_focus_does_not_open_or_switch",
                    ui(() -> a.appDialog == null && a.current.homeState.category.equals("c2")));
            runOnMainSync(() -> tag("home-tab:0").requestFocus());
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.category.isEmpty()
                                    && tag("home-video:11") != null);
            check(
                    "history_has_four_cards_in_one_list",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-history-list")).getChildCount() == 4
                                            && tag("home-history:3") != null
                                            && tag("home-history:4") == null));
            check(
                    "newest_history_is_first_and_resumable",
                    ui(
                            () -> {
                                ViewGroup historyRow = (ViewGroup) tag("home-history-list");
                                return historyRow.getChildAt(0) == tag("home-history:0")
                                        && historyRow.getChildAt(0).hasOnClickListeners()
                                        && ((TextView) tag("home-history-title"))
                                                .getText()
                                                .toString()
                                                .equals("历史记录")
                                        && ((ViewGroup) tag("home-history-section")).getChildCount()
                                                == 3;
                            }));
            check(
                    "history_does_not_duplicate_latest",
                    ui(
                            () ->
                                    tag("home-history:0")
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("继续观看 · 1")
                                            && tag("home-history:1")
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("继续观看 · 2")));
            check("home_has_navigation", ui(() -> tag("nav-home") != null));
            check(
                    "history_compact_landscape",
                    ui(
                            () ->
                                    tag("home-history:0").getWidth()
                                            > tag("home-history:0").getHeight() * 2));
            check(
                    "five_columns",
                    ui(() -> ((ViewGroup) tag("home-video:0").getParent()).getChildCount() == 5));
            check(
                    "portrait_ratio",
                    ui(
                            () -> {
                                View image = ((ViewGroup) tag("home-video:0")).getChildAt(0);
                                return Math.abs(image.getHeight() / (float) image.getWidth() - 1.5)
                                        < .02;
                            }));
            check(
                    "larger_posters",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-video:0")).getChildAt(0).getWidth()
                                            >= a.dp(145)));
            check("dock_fixed_outside_scroll", ui(() -> tag("home-dock").getParent() == a.root));
            check(
                    "dock_right_and_compact",
                    ui(
                            () ->
                                    tag("home-dock").getWidth() <= a.dp(50)
                                            && tag("home-dock").getRight()
                                                    <= a.root.getWidth() - a.dp(19)));
            check(
                    "dock_does_not_overlap_posters",
                    ui(
                            () -> {
                                int[] card = {0, 0}, dock = {0, 0};
                                tag("home-video:4").getLocationOnScreen(card);
                                tag("home-dock").getLocationOnScreen(dock);
                                return card[0] + tag("home-video:4").getWidth() + a.dp(12)
                                        < dock[0];
                            }));
            check(
                    "icon_labels_accessible",
                    ui(
                            () ->
                                    tag("nav-search")
                                                    .getContentDescription()
                                                    .toString()
                                                    .equals("搜索")
                                            && !(tag("nav-search") instanceof TextView)));
            runOnMainSync(() -> tag("home-video:4").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check("row_right_enters_dock", ui(() -> tag("nav-home").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check("dock_down_moves_to_search", ui(() -> tag("nav-search").hasFocus()));
            check(
                    "focus_label_visible",
                    ui(
                            () ->
                                    tag("home-dock-label").getVisibility() == View.VISIBLE
                                            && ((TextView) tag("home-dock-label"))
                                                    .getText()
                                                    .toString()
                                                    .equals("搜索")));
            check(
                    "page_marker_independent_of_focus",
                    ui(() -> tag("nav-home").isSelected() && !tag("nav-search").isSelected()));
            check(
                    "label_compact_and_aligned",
                    ui(
                            () -> {
                                View label = tag("home-dock-label"), icon = tag("nav-search");
                                int[] l = {0, 0}, i = {0, 0};
                                label.getLocationOnScreen(l);
                                icon.getLocationOnScreen(i);
                                return label.getHeight() <= a.dp(28)
                                        && Math.abs(
                                                        l[1]
                                                                + label.getHeight() / 2
                                                                - i[1]
                                                                - icon.getHeight() / 2)
                                                <= 2
                                        && l[0] + label.getWidth() < i[0];
                            }));
            frame("dock-focus");
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check("dock_left_restores_exact_card", ui(() -> tag("home-video:4").hasFocus()));
            check(
                    "focus_label_hides_in_content",
                    ui(() -> tag("home-dock-label").getVisibility() != View.VISIBLE));
            runOnMainSync(() -> tag("home-video:11").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check("partial_row_enters_dock", ui(() -> tag("nav-home").hasFocus()));
            click("nav-settings");
            check("dock_hidden_on_secondary", ui(() -> tag("home-dock") == null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-settings") != null);
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check(
                    "secondary_back_then_left_restores_card",
                    ui(() -> tag("home-video:11").hasFocus()));
            click("nav-accounts");
            SystemClock.sleep(350);
            check(
                    "account_panel_inside_screen",
                    ui(
                            () -> {
                                View v = a.accountDialog.findViewById(android.R.id.content);
                                int[] xy = {0, 0};
                                v.getLocationOnScreen(xy);
                                return xy[0] >= 0
                                        && xy[1] >= 0
                                        && xy[0] + v.getWidth() <= a.root.getWidth()
                                        && xy[1] + v.getHeight() <= a.root.getHeight();
                            }));
            frame("accounts");
            runOnMainSync(() -> a.accountDialog.dismiss());
            check("account_dismiss_restores_icon", ui(() -> tag("nav-accounts").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check("account_left_restores_card", ui(() -> tag("home-video:11").hasFocus()));
            runOnMainSync(
                    () -> {
                        a.scroll.scrollTo(0, 0);
                        tag("home-history:0").requestFocus();
                    });
            check(
                    "source_beside_discover",
                    ui(
                            () -> {
                                View v = tag("source-switcher");
                                return v.getLeft() < a.dp(100) && v.getWidth() <= a.dp(220);
                            }));
            check(
                    "category_long_title_complete",
                    ui(
                            () ->
                                    fullLabel((TextView) tag("home-tab:1"))
                                            && ((TextView) tag("home-tab:1"))
                                                    .getText()
                                                    .toString()
                                                    .equals("豆瓣电影Top250")));
            check(
                    "category_oversized_title_wraps",
                    ui(
                            () ->
                                    fullLabel((TextView) tag("home-tab:4"))
                                            && ((TextView) tag("home-tab:4")).getLineCount() > 1));
            check(
                    "category_flow_uses_multiple_rows",
                    ui(() -> tag("home-tab:4").getTop() > tag("home-tab:0").getTop()));
            runOnMainSync(() -> tag("home-tab:4").requestFocus());
            pacedUp();
            check(
                    "wrapped_category_up_stays_in_categories",
                    ui(() -> String.valueOf(a.getCurrentFocus().getTag()).startsWith("home-tab:")));
            await(
                    () ->
                            a.current.homeState.category.equals(
                                    a.current.retainedHome.tabIds.get(a.getCurrentFocus())));
            check(
                    "wrapped_category_up_selects_focused_category",
                    ui(() -> a.getCurrentFocus().isSelected()));
            runOnMainSync(() -> tag("home-tab:0").requestFocus());
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.category.isEmpty()
                                    && tag("home-video:11") != null);
            check(
                    "source_has_visible_dropdown",
                    ui(
                            () ->
                                    ((TextView) tag("source-switcher")).getCompoundDrawables()[2]
                                            != null));
            check(
                    "ambient_home_only",
                    ui(() -> a.homeAmbient != null && tag("home-ambient") != null));
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            await(() -> a.homeAmbient.applied > 0);
            check(
                    "ambient_uses_loaded_poster",
                    ui(
                            () ->
                                    a.homeAmbient.wanted
                                            == ((ViewGroup) tag("home-video:0")).getChildAt(0)));
            final int[] warm = {0}, cool = {0};
            runOnMainSync(
                    () -> {
                        Bitmap red = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
                        red.eraseColor(0xffc05030);
                        Bitmap blue = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
                        blue.eraseColor(0xff3060c0);
                        warm[0] = HomeAmbient.sample(red, 0);
                        cool[0] = HomeAmbient.sample(blue, 0);
                        red.recycle();
                        blue.recycle();
                    });
            check(
                    "ambient_colors_follow_art_and_stay_dim",
                    warm[0] != cool[0] && Color.red(warm[0]) <= 64 && Color.blue(cool[0]) <= 64);
            check(
                    "ambient_reduced_motion_is_static",
                    ui(
                            () -> {
                                a.reduced = true;
                                a.homeAmbient.transition(warm[0], cool[0]);
                                // Check the requested colors in the same UI task: a queued
                                // posterReady may legitimately choose new colors afterwards.
                                return a.homeAmbient.animation == null
                                        && a.homeAmbient.fraction == 1
                                        && a.homeAmbient.left == warm[0]
                                        && a.homeAmbient.right == cool[0];
                            }));
            SystemClock.sleep(250);
            check(
                    "ambient_pending_poster_remains_static",
                    ui(() -> a.homeAmbient.animation == null && a.homeAmbient.fraction == 1));
            runOnMainSync(() -> a.reduced = a.prefs.getBoolean("reduced", false));
            frame("overview");
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            String source = ((TextView) tag("source-switcher")).getText().toString();
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check(
                    "source_label_stable",
                    ui(
                            () ->
                                    source.equals(
                                            ((TextView) tag("source-switcher"))
                                                    .getText()
                                                    .toString())));
            pacedUp();
            check("poster_up_to_category", ui(() -> tag("home-tab:0").hasFocus()));
            pacedUp();
            check("category_up_to_source", ui(() -> tag("source-switcher").hasFocus()));
            pacedUp();
            check("source_up_to_history", ui(() -> tag("home-history:0").hasFocus()));
            runOnMainSync(() -> a.current.homeState.categoryCache.remove("c1"));
            click("home-tab:1");
            click("home-tab:2");
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            SystemClock.sleep(1000);
            check(
                    "late_category_cannot_overwrite",
                    ui(() -> a.current.homeState.videos.get(0).id.startsWith("c2")));
            View beforeAppend = tag("home-video:0");
            click("home-load-more");
            await(() -> tag("home-video:14") != null);
            check("pagination_keeps_existing_cards", ui(() -> tag("home-video:0") == beforeAppend));
            check(
                    "pagination_appends",
                    ui(
                            () ->
                                    a.current.homeState.videos.size() == 15
                                            && a.current.homeState.page == 2));
            check("page_end_hides_more", ui(() -> !tag("home-load-more").isShown()));
            runOnMainSync(() -> tag("home-video:14").requestFocus());
            SystemClock.sleep(300);
            check("scrolled_down_before_return", ui(() -> a.scroll.getScrollY() > a.dp(100)));
            for (int i = 0; i < 5; i++) pacedUp();
            SystemClock.sleep(500);
            check("up_from_deep_grid_reaches_history", ui(() -> tag("home-history:0").hasFocus()));
            check("up_restores_absolute_top", ui(() -> a.scroll.getScrollY() == 0));
            check(
                    "logo_and_history_visible_after_up",
                    ui(
                            () -> {
                                android.graphics.Rect logo = new android.graphics.Rect(),
                                        historyBox = new android.graphics.Rect();
                                return tag("home-brand").getGlobalVisibleRect(logo)
                                        && logo.height() == tag("home-brand").getHeight()
                                        && tag("home-history:0").getGlobalVisibleRect(historyBox)
                                        && historyBox.height()
                                                >= tag("home-history:0").getHeight() - 2;
                            }));
            pacedUp();
            SystemClock.sleep(300);
            check("top_up_keeps_logo_visible", ui(() -> a.scroll.getScrollY() == 0));
            frame("history-top");
            runOnMainSync(
                    () -> {
                        tag("home-video:14").requestFocus();
                        a.homeKeys.reset();
                    });
            SystemClock.sleep(350);
            fastUp();
            fastUp();
            fastUp();
            await(() -> a.scroll.getScrollY() == 0);
            check(
                    "triple_up_returns_to_absolute_top",
                    ui(() -> a.scroll.getScrollY() == 0 && tag("home-history:0").hasFocus()));
            runOnMainSync(() -> tag("nav-settings").requestFocus());
            fastUp();
            fastUp();
            fastUp();
            await(() -> a.scroll.getScrollY() == 0);
            check(
                    "triple_up_also_works_from_dock",
                    ui(() -> a.scroll.getScrollY() == 0 && tag("home-history:0").hasFocus()));
            key(KeyEvent.KEYCODE_MENU);
            check(
                    "menu_opens_source_chooser",
                    ui(
                            () ->
                                    a.sourceDialog != null
                                            && a.sourceDialog.isShowing()
                                            && a.sourceDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag(
                                                                    "source-choice:home-fixture")
                                                    != null));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "source_menu_back_preserves_home",
                    ui(() -> a.sourceDialog == null && a.current.home));

            View retainedHome = a.root;
            int homeCount = homeRequests.get(), categoryCount = categoryRequests.get();
            click("home-video:11");
            await(() -> tag("detail-favorite") != null);
            check("details_hide_nav", ui(this::noNav));
            check("ambient_not_on_detail", ui(() -> tag("home-ambient") == null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-video:14") != null);
            check(
                    "back_restores_category_and_pages",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c2")
                                            && a.current.homeState.page == 2));
            check("back_restores_card_focus", ui(() -> tag("home-video:11").hasFocus()));
            check("back_reattaches_same_home_tree", ui(() -> a.root == retainedHome));
            check(
                    "detail_return_sends_no_catalogue_requests",
                    homeRequests.get() == homeCount && categoryRequests.get() == categoryCount);
            for (int dimension = 0; dimension < 3; dimension++) {
                final int choice = dimension;
                click("home-filters");
                runOnMainSync(
                        () ->
                                a.appDialog
                                        .findViewById(android.R.id.content)
                                        .findViewWithTag("dialog-option:" + choice)
                                        .performClick());
                await(() -> a.appDialog != null);
                runOnMainSync(
                        () ->
                                a.appDialog
                                        .findViewById(android.R.id.content)
                                        .findViewWithTag("dialog-option:1")
                                        .performClick());
                await(
                        () ->
                                a.current.homeState.ready
                                        && a.current.homeState.selectedFilters.size() == choice + 1
                                        && tag("home-video:2") != null);
            }
            check(
                    "all_three_tv_filters_reach_engine",
                    receivedFilters.size() == 3 && receivedFilters.get("year").equals("2026"));
            View filteredHome = a.root;
            int filteredCount = categoryRequests.get();
            click("home-video:2");
            await(() -> tag("detail-favorite") != null);
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-video:2") != null);
            check(
                    "filtered_home_stays_resident",
                    ui(
                            () ->
                                    a.root == filteredHome
                                            && a.current.homeState.selectedFilters.size() == 3
                                            && tag("home-video:2").hasFocus()));
            check("filtered_return_does_not_reload", categoryRequests.get() == filteredCount);

            runOnMainSync(
                    () -> {
                        failAnimeCategory = true;
                        a.current.homeState.categoryCache.remove("c3");
                    });
            click("home-tab:3");
            await(() -> tag("home-load-more").isShown());
            check(
                    "failure_has_retry",
                    ui(
                            () ->
                                    ((TextView) tag("home-load-more"))
                                            .getText()
                                            .toString()
                                            .equals("重新加载")));
            click("home-load-more");
            await(() -> a.current.homeState.ready);
            check(
                    "retry_recovers",
                    ui(() -> a.current.homeState.videos.get(0).id.startsWith("c3")));
            click("home-category-more");
            check(
                    "overflow_custom_dialog",
                    ui(
                            () ->
                                    a.appDialog != null
                                            && a.appDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag("app-dialog")
                                                    != null));
            check(
                    "category_dialog_long_title_complete",
                    ui(
                            () ->
                                    fullLabel(
                                            (TextView)
                                                    a.appDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag("dialog-option:6"))));
            runOnMainSync(
                    () ->
                            a.appDialog
                                    .findViewById(android.R.id.content)
                                    .findViewWithTag("dialog-option:6")
                                    .performClick());
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c7"));
            check("empty_category_no_stale_posters", ui(() -> tag("home-video:0") == null));
            check(
                    "selected_overflow_title_complete",
                    ui(() -> fullLabel((TextView) tag("home-category-more"))));
            click("home-tab:0");
            await(() -> tag("home-video:0") != null);
            click("nav-search");
            check("search_hides_nav", ui(this::noNav));
            check("search_has_focus", ui(() -> a.getCurrentFocus() != null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-favorites");
            check("favorites_hide_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-live");
            check("live_hides_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-settings");
            check("settings_hide_nav", ui(this::noNav));
            check("settings_has_focus", ui(() -> a.getCurrentFocus() != null));
            frame("settings");
            click("settings-appearance");
            check("nested_settings_hide_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            check("back_to_settings_no_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            check("home_restores_nav_focus", ui(() -> tag("nav-settings").hasFocus()));
            click("home-history-all");
            check("history_hides_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-history:0") != null);
            final String singleRecord = new JSONArray().put(records.getJSONObject(0)).toString();
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putString("watch_history", singleRecord).commit();
                        a.refresh();
                    });
            await(() -> tag("home-video:11") != null);
            check(
                    "one_history_entry_has_no_empty_continuation_area",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-history-list")).getChildCount() == 1
                                            && tag("home-history:0") != null
                                            && tag("home-history:1") == null
                                            && ((ViewGroup) tag("home-history-section"))
                                                            .getChildCount()
                                                    == 3));
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putString("watch_history", "[]").commit();
                        a.refresh();
                    });
            await(() -> tag("home-video:11") != null);
            check("no_history_no_blank_section", ui(() -> tag("home-history:0") == null));
            runOnMainSync(() -> tag("home-video:11").requestFocus());
            SystemClock.sleep(250);
            for (int i = 0; i < 5; i++) pacedUp();
            SystemClock.sleep(400);
            check("no_history_up_reveals_logo", ui(() -> a.scroll.getScrollY() == 0));
            runOnMainSync(
                    () -> {
                        tag("home-video:11").requestFocus();
                        a.homeKeys.reset();
                    });
            fastUp();
            fastUp();
            fastUp();
            await(() -> a.scroll.getScrollY() == 0);
            check(
                    "triple_up_without_history_targets_recommended",
                    ui(() -> tag("home-tab:0").hasFocus() && a.scroll.getScrollY() == 0));
            frame("no-history");
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putBoolean("wallpaper_enabled", true).commit();
                        a.refresh();
                    });
            check("custom_wallpaper_takes_priority", ui(() -> tag("home-ambient") == null));
            runOnMainSync(
                    () -> {
                        a.prefs
                                .edit()
                                .putBoolean("wallpaper_enabled", false)
                                .putBoolean("home_ambient", false)
                                .commit();
                        a.refresh();
                    });
            check("ambient_can_be_disabled", ui(() -> tag("home-ambient") == null));
            SourceEngine originalFixture = a.engines.get(site.key);
            for (int round = 0; round < 10; round++) {
                CountDownLatch requested = new CountDownLatch(1), deliver = new CountDownLatch(1);
                runOnMainSync(
                        () -> {
                            a.engines.put(
                                    site.key,
                                    new SourceEngine() {
                                        public String home() throws Exception {
                                            requested.countDown();
                                            if (!deliver.await(5, TimeUnit.SECONDS))
                                                throw new IOException("fixture delivery timeout");
                                            return listing("迟到推荐", 12, 1);
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
                                            return false;
                                        }
                                    });
                            a.homeData.remove(site.key);
                            a.open(new MainActivity.Screen(a::home), false);
                        });
                try {
                    if (!requested.await(5, TimeUnit.SECONDS))
                        throw new AssertionError("home request not started");
                    runOnMainSync(() -> tag("nav-accounts").requestFocus());
                    deliver.countDown();
                    await(() -> tag("home-video:11") != null);
                    SystemClock.sleep(100);
                    check(
                            "late_home_preserves_user_dock_focus_" + round,
                            ui(() -> tag("nav-accounts").hasFocus()));
                } finally {
                    deliver.countDown();
                }
            }
            runOnMainSync(
                    () -> {
                        a.engines.put(site.key, originalFixture);
                        a.homeData.remove(site.key);
                    });
            result.put("passed", true);
        } catch (Throwable e) {
            try {
                result.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null && history != null) {
                String h = history, s = selected;
                boolean hh = hadHistory, hs = hadSelected;
                Integer c = columns;
                Cms.Config cfg = original;
                runOnMainSync(
                        () -> {
                            if (a.sourceDialog != null) a.sourceDialog.dismiss();
                            if (a.appDialog != null) a.appDialog.dismiss();
                            SharedPreferences.Editor edit = a.prefs.edit();
                            if (hh) edit.putString("watch_history", h);
                            else edit.remove("watch_history");
                            if (hs) edit.putString("selected_site", s);
                            else edit.remove("selected_site");
                            if (c != null) edit.putInt("home_columns", c);
                            else edit.remove("home_columns");
                            edit.commit();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.prefs = getTargetContext().getSharedPreferences("movie", 0);
                            a.config = cfg;
                            a.engines.remove("home-fixture");
                            a.homeData.remove("home-fixture");
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
        }
        Bundle report = new Bundle();
        report.putString("result", result.toString());
        sendStatus(0, report);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
