package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

public final class SearchCaseProbe extends Instrumentation {
    MainActivity a;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject report = new JSONObject();
    final List<String> requests = Collections.synchronizedList(new ArrayList<>());

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        start();
    }

    @Override
    public void callActivityOnCreate(Activity activity, Bundle b) {
        super.callActivityOnCreate(activity, b);
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            launched.countDown();
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

    void check(String key, boolean ok) throws Exception {
        report.put(key, ok);
        if (!ok) throw new AssertionError(key);
    }

    void await(Callable<Boolean> fn) throws Exception {
        long end = SystemClock.elapsedRealtime() + 10000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(fn)) return;
            SystemClock.sleep(30);
        }
        throw new AssertionError("timeout");
    }

    String results(boolean chinese) throws Exception {
        JSONArray list = new JSONArray();
        if (chinese) {
            list.put(new JSONObject().put("vod_id", "one").put("vod_name", "斗罗大陆"));
            list.put(new JSONObject().put("vod_id", "two").put("vod_name", "【动漫】斗罗大陆 第二季"));
            list.put(new JSONObject().put("vod_id", "wrong").put("vod_name", "无关样本"));
        } else
            list.put(
                    new JSONObject()
                            .put("vod_id", "literal")
                            .put("vod_name", "Literal provider result"));
        return new JSONObject().put("list", list).toString();
    }

    @Override
    public void onStart() {
        SharedPreferences original = null;
        Cms.Config config = null;
        PhoneticSearchIndex previous = null;
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            original = a.prefs;
            config = a.config;
            previous = a.phonetic;
            PhoneticSearchIndex fresh =
                    new PhoneticSearchIndex(
                            context.getAssets().open("search/pinyin-characters.tsv"),
                            context.getAssets().open("search/pinyin-phrases.dict.yaml"),
                            context.getAssets().open("search/title-phrases.txt"));
            SharedPreferences fixture = context.getSharedPreferences("search_case_fixture", 0);
            fixture.edit().clear().commit();
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        a.phonetic = fresh;
                        a.phoneticReady.countDown();
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        Cms.Config cfg = new Cms.Config();
                        cfg.raw = "{}";
                        for (int i = 0; i < 2; i++) {
                            final boolean chinese = i == 0;
                            Cms.Site site = new Cms.Site();
                            site.key = "case-" + i;
                            site.name = chinese ? "中文检索样本" : "原词检索样本";
                            site.type = 1;
                            site.api = "https://fixture.test/api";
                            site.searchable = true;
                            cfg.sites.add(site);
                            a.engines.put(
                                    site.key,
                                    new SourceEngine() {
                                        public String home() {
                                            return "{}";
                                        }

                                        public String category(String id, int page) {
                                            return "{}";
                                        }

                                        public String detail(String id) {
                                            return "{}";
                                        }

                                        public boolean requiresExternalRuntime() {
                                            return false;
                                        }

                                        public String search(String q, int page) throws Exception {
                                            requests.add((chinese ? "cn:" : "literal:") + q);
                                            return chinese && q.equals("斗罗大陆")
                                                    ? results(true)
                                                    : !chinese && q.equalsIgnoreCase("dldl")
                                                            ? results(false)
                                                            : "{\"list\":[]}";
                                        }
                                    });
                        }
                        a.config = cfg;
                        a.globalSearchDialog();
                    });
            final GlobalSearchScreen screen = a.searchScreen;
            runOnMainSync(
                    () -> {
                        screen.keyboard.set("dldl");
                        screen.changed();
                    });
            await(
                    () ->
                            screen.submitted.equals("dldl")
                                    && screen.finished == 2
                                    && screen.displayed.size() >= 3);
            check("fresh_initials_auto_searches_chinese_title", requests.contains("cn:斗罗大陆"));
            check("literal_acronym_is_also_sent", requests.contains("literal:dldl"));
            check(
                    "initials_return_title_without_browsing",
                    ui(() -> screen.results.get("case-0").videos.size() == 2));
            check(
                    "decorated_title_survives_filter",
                    ui(() -> screen.results.get("case-0").videos.get(1).title.startsWith("【动漫】")));
            check(
                    "unrelated_expansion_result_rejected",
                    ui(
                            () ->
                                    screen.results.get("case-0").videos.stream()
                                            .noneMatch(v -> v.id.equals("wrong"))));
            check(
                    "literal_provider_result_preserved",
                    ui(() -> screen.results.get("case-1").videos.size() == 1));
            requests.clear();
            runOnMainSync(
                    () -> {
                        screen.keyboard.set("douluodalu");
                        screen.changed();
                        screen.submit(false);
                    });
            await(() -> screen.submitted.equals("douluodalu") && screen.finished == 2);
            check("full_pinyin_calls_same_chinese_query", requests.contains("cn:斗罗大陆"));
            check(
                    "full_pinyin_returns_both_title_variants",
                    ui(() -> screen.results.get("case-0").videos.size() == 2));
            requests.clear();
            runOnMainSync(
                    () -> {
                        screen.keyboard.set("斗罗大陆");
                        screen.changed();
                        screen.submit(false);
                    });
            await(() -> screen.submitted.equals("斗罗大陆") && screen.finished == 2);
            check(
                    "chinese_query_remains_literal",
                    requests.contains("cn:斗罗大陆") && requests.size() == 2);
            check("shortcuts_do_not_apply_on_search_page", ui(() -> !a.current.home));
            runOnMainSync(
                    () -> {
                        a.dispatchKeyEvent(
                                new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU));
                        a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU));
                    });
            check("menu_does_not_open_source_chooser_on_search", ui(() -> a.sourceDialog == null));
            report.put("passed", true);
        } catch (Throwable e) {
            try {
                report.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                SharedPreferences prefs = original;
                Cms.Config saved = config;
                PhoneticSearchIndex index = previous;
                runOnMainSync(
                        () -> {
                            if (a.searchScreen != null) a.searchScreen.close();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.prefs = prefs;
                            a.config = saved;
                            a.phonetic = index;
                            a.engines.keySet().removeIf(key -> key.startsWith("case-"));
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
