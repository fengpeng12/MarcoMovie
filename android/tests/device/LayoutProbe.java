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

/** Exercises the actual Activity resource context at every user-selectable scale; restores the original setting. */
public final class LayoutProbe extends Instrumentation {
    volatile MainActivity a;
    volatile CountDownLatch launch = new CountDownLatch(1);
    final JSONObject result = new JSONObject();

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    @Override
    public void callActivityOnCreate(Activity x, Bundle b) {
        super.callActivityOnCreate(x, b);
        if (x instanceof MainActivity) {
            a = (MainActivity) x;
            final MainActivity created = a;
            created.getWindow()
                    .addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            created.ui.post(
                    new Runnable() {
                        public void run() {
                            if (created.isDestroyed()) return;
                            if (created.layoutReady) launch.countDown();
                            else created.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    void check(String key, boolean value) throws Exception {
        result.put(key, value);
        if (!value) throw new AssertionError(key);
    }

    boolean inside(View v) {
        int[] pos = new int[2];
        v.getLocationOnScreen(pos);
        return pos[0] >= 0
                && pos[1] >= 0
                && pos[0] + v.getWidth() <= a.root.getWidth() + 1
                && pos[1] + v.getHeight() <= a.root.getHeight() + 1;
    }

    void ready() throws Exception {
        if (!launch.await(15, TimeUnit.SECONDS)) throw new AssertionError("recreate timeout");
        waitForIdleSync();
        SystemClock.sleep(400);
        runOnMainSync(
                () -> {
                    if (a.startupIntro != null) a.startupIntro.cancel();
                });
    }

    @Override
    public void onStart() {
        SharedPreferences prefs = getTargetContext().getSharedPreferences("movie", 0);
        boolean existed = prefs.contains("ui_scale_percent");
        int old = prefs.getInt("ui_scale_percent", 100);
        try {
            prefs.edit().putInt("ui_scale_percent", 100).commit();
            getTargetContext()
                    .startActivity(
                            new Intent(getTargetContext(), MainActivity.class)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            ready();
            for (int percent : new int[] {100, 110, 120}) {
                if (percent != 100) {
                    prefs.edit().putInt("ui_scale_percent", percent).commit();
                    launch = new CountDownLatch(1);
                    runOnMainSync(() -> a.recreate());
                    ready();
                }
                final int scale = percent;
                final int[] dimensions = new int[3];
                runOnMainSync(
                        () -> {
                            a.open(
                                    new MainActivity.Screen(
                                            () -> new SettingsScreen(a).appearance()),
                                    false);
                            dimensions[0] = a.dp(48);
                            dimensions[1] = a.getResources().getDisplayMetrics().densityDpi;
                            dimensions[2] = a.getResources().getDisplayMetrics().widthPixels;
                        });
                waitForIdleSync();
                SystemClock.sleep(200);
                check("button_size_" + scale, dimensions[0] == Math.round(96 * scale / 100f));
                check("density_" + scale, dimensions[1] == Math.round(320 * scale / 100f));
                final boolean[] fits = {false};
                runOnMainSync(
                        () -> {
                            View v = a.root.findViewWithTag("setting-ui_scale_percent");
                            fits[0] = v != null && inside(v) && v.isFocusable();
                        });
                check("size_setting_visible_" + scale, fits[0]);
                runOnMainSync(
                        () ->
                                new AppDialog.Builder(a)
                                        .setTitle("界面适配验证")
                                        .setMessage("按钮、文字与图标同步放大。关闭后返回原页面。")
                                        .setSingleChoiceItems(
                                                new String[] {
                                                    "标准 · 自动适配", "放大 · 110%", "更大 · 120%"
                                                },
                                                0,
                                                (d, n) -> {})
                                        .setNegativeButton("返回", null)
                                        .show());
                waitForIdleSync();
                SystemClock.sleep(250);
                runOnMainSync(() -> fits[0] = inside(a.appDialog.getWindow().getDecorView()));
                check("dialog_inside_screen_" + scale, fits[0]);
                runOnMainSync(() -> a.appDialog.dismiss());
                runOnMainSync(
                        () -> {
                            a.renderPage("", "");
                            a.playbackLayer = new FrameLayout(a);
                            a.root.addView(a.playbackLayer, new FrameLayout.LayoutParams(-1, -1));
                            Cms.Video v = new Cms.Video();
                            v.title = "适配验证 · 清晰可读的影片名称";
                            Cms.Episode e = new Cms.Episode();
                            e.name = "第 1 集";
                            // A previously browsed live list must not hide a VOD timeline.
                            a.liveSession =
                                    new LiveSession(
                                            new LiveCatalog.Source(), new LiveCatalog.Catalog());
                            PlayerChrome chrome = new PlayerChrome(a, v, e, false);
                            if (chrome.progress.getVisibility() != View.VISIBLE)
                                throw new AssertionError("VOD progress hidden after live browsing");
                            a.liveSession = null;
                            a.playerChrome = chrome;
                            Cms.Site site = new Cms.Site();
                            site.key = "layout-vod";
                            VideoOutput surface = new VideoOutput(a, true);
                            a.playbackControls =
                                    new PlaybackControls(
                                            a, chrome.dock, chrome.progress, surface, site, v, e);
                            chrome.relayout();
                        });
                waitForIdleSync();
                SystemClock.sleep(250);
                runOnMainSync(
                        () ->
                                fits[0] =
                                        inside(a.playerChrome.dock)
                                                && inside(a.playerChrome.heading)
                                                && inside(a.playerChrome.progress)
                                                && inside(a.playbackControls.timeline)
                                                && a.playbackControls.timeline.isShown()
                                                && a.playerChrome.dock.getWidth()
                                                        < a.root.getWidth());
                check("player_regions_fit_" + scale, fits[0]);
                Bitmap screen = getUiAutomation().takeScreenshot();
                if (screen != null) {
                    try (FileOutputStream out =
                            new FileOutputStream(
                                    new File(
                                            a.getExternalFilesDir(null),
                                            "layout-" + scale + ".png"))) {
                        screen.compress(Bitmap.CompressFormat.PNG, 100, out);
                    }
                    screen.recycle();
                }
                runOnMainSync(
                        () -> {
                            a.playbackControls.close();
                            a.playbackControls = null;
                            a.playerChrome = null;
                            a.playerOverlay = null;
                            a.playbackLayer = null;
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
            result.put("passed", true);
        } catch (Throwable e) {
            try {
                result.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            SharedPreferences.Editor edit = prefs.edit();
            if (existed) edit.putInt("ui_scale_percent", old);
            else edit.remove("ui_scale_percent");
            edit.commit();
            if (a != null) {
                launch = new CountDownLatch(1);
                runOnMainSync(
                        () -> {
                            if (a.appDialog != null) a.appDialog.dismiss();
                            a.recreate();
                        });
                try {
                    ready();
                } catch (Exception ignored) {
                }
            }
        }
        Bundle b = new Bundle();
        b.putString("result", result.toString());
        sendStatus(0, b);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
