package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.content.pm.ActivityInfo;
import android.graphics.Bitmap;
import android.os.*;
import android.view.*;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.*;
import java.util.List;
import java.util.concurrent.*;
import org.json.JSONObject;

/** API 23 regression against the real settings and player subtitle dialogs, using local media. */
public final class SubtitleProbe extends Instrumentation {
    volatile MainActivity a;
    final JSONObject result = new JSONObject();
    final CountDownLatch launched = new CountDownLatch(1);
    static final String TITLE = "全屏字幕实时预览与调节";

    // Isolated negative control: this is the exact unavailable callback type used before the fix.
    static final class LegacyCallback {
        static void invoke() {
            java.util.function.IntConsumer callback = value -> {};
            callback.accept(1);
        }
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    @Override
    public void callActivityOnCreate(Activity activity, Bundle state) {
        super.callActivityOnCreate(activity, state);
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            launched.countDown();
        }
    }

    boolean ui(Callable<Boolean> action) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = action.call();
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    }
                });
        return value[0];
    }

    void check(String name, boolean passed) throws Exception {
        result.put(name, passed);
        if (!passed) throw new AssertionError(name);
    }

    void await(String name, Callable<Boolean> predicate) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 15000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (predicate.call()) {
                result.put(name, true);
                return;
            }
            SystemClock.sleep(80);
        }
        throw new AssertionError(name);
    }

    boolean textVisible(String text) {
        AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
        if (root == null) return false;
        List<AccessibilityNodeInfo> matches = root.findAccessibilityNodeInfosByText(text);
        boolean visible = false;
        for (AccessibilityNodeInfo node : matches) {
            visible |= node.isVisibleToUser();
            node.recycle();
        }
        root.recycle();
        return visible;
    }

    boolean focusText(String text) {
        AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
        if (root == null) return false;
        List<AccessibilityNodeInfo> matches = root.findAccessibilityNodeInfosByText(text);
        boolean focused = false;
        for (AccessibilityNodeInfo node : matches) {
            if (!focused && node.isVisibleToUser() && node.isFocusable()) {
                focused =
                        node.isFocused() || node.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
            }
            node.recycle();
        }
        root.recycle();
        return focused;
    }

    boolean focusFirstSlider(AccessibilityNodeInfo node) {
        if ("android.widget.SeekBar".contentEquals(node.getClassName()) && node.isVisibleToUser()) {
            return node.isFocused() || node.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            boolean focused = focusFirstSlider(child);
            child.recycle();
            if (focused) return true;
        }
        return false;
    }

    boolean focusSizeSlider() {
        AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
        if (root == null) return false;
        boolean focused = focusFirstSlider(root);
        root.recycle();
        return focused;
    }

    void clickTag(String tag) {
        boolean clicked =
                ui(
                        () -> {
                            View control = a.root.findViewWithTag(tag);
                            if (control == null) return false;
                            control.requestFocus();
                            return control.performClick();
                        });
        if (!clicked) throw new AssertionError("Missing control or action: " + tag);
        waitForIdleSync();
    }

    void key(int code) {
        sendKeyDownUpSync(code);
        waitForIdleSync();
    }

    void capture(String name) throws Exception {
        Bitmap screen = getUiAutomation().takeScreenshot();
        if (screen == null) throw new AssertionError("Screenshot unavailable: " + name);
        try (FileOutputStream output =
                new FileOutputStream(new File(a.getExternalFilesDir(null), name + ".png"))) {
            screen.compress(Bitmap.CompressFormat.PNG, 100, output);
        } finally {
            screen.recycle();
        }
    }

    void adjust(String origin) throws Exception {
        await(origin + "_dialog_visible", () -> textVisible(TITLE));
        int size = a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45);
        int bottom = a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24);
        int style = a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0);
        // The fullscreen adjuster now has separate size, position and style controls.
        // Focus real controls, then use the remote keys to verify persisted changes.
        await(origin + "_size_control_focused", this::focusSizeSlider);
        key(KeyEvent.KEYCODE_DPAD_RIGHT);
        await(
                origin + "_size_changed",
                () -> ui(() -> a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45) == size + 2));
        await(origin + "_position_control_focused", () -> focusText("▲ 上移"));
        key(KeyEvent.KEYCODE_DPAD_CENTER);
        await(
                origin + "_position_changed",
                () -> ui(() -> a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24) == bottom + 6));
        await(origin + "_style_control_focused", () -> focusText("字幕颜色与样式"));
        key(KeyEvent.KEYCODE_DPAD_CENTER);
        await(origin + "_style_drawer_visible", () -> textVisible("字幕颜色与样式（抽屉菜单）"));
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        key(KeyEvent.KEYCODE_DPAD_CENTER);
        await(
                origin + "_style_changed",
                () ->
                        ui(
                                () ->
                                        a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0)
                                                == (style + 1)
                                                        % SubtitleOverlayView.STYLE_LABELS.length));
        check(origin + "_dialog_survives_changes", textVisible(TITLE));
        capture("subtitles-" + origin);
        key(KeyEvent.KEYCODE_BACK);
        await(origin + "_dismissed", () -> !textVisible(TITLE) && ui(a::hasWindowFocus));
    }

    void openPlayer(File media) {
        runOnMainSync(
                () -> {
                    a.prefs.edit().putInt(Prefs.PLAYER_ENGINE, 1).commit();
                    // Prevent background VOD resume lookup; the fixture is already a local file.
                    a.liveSession =
                            new LiveSession(new LiveCatalog.Source(), new LiveCatalog.Catalog());
                    Cms.Site site = new Cms.Site();
                    site.key = "api23-subtitle-fixture";
                    site.name = "Local subtitle fixture";
                    site.api = "";
                    site.playUrl = "";
                    Cms.Video video = new Cms.Video();
                    video.title = "Local subtitle preview";
                    Cms.Episode episode = new Cms.Episode();
                    episode.name = "Local audio timeline";
                    episode.url = android.net.Uri.fromFile(media).toString();
                    MainActivity.Screen page =
                            new MainActivity.Screen(() -> a.playerPage(site, video, episode));
                    page.player = true;
                    a.open(page, false);
                });
    }

    @Override
    public void onStart() {
        try {
            check("api23_runtime", Build.VERSION.SDK_INT == 23);
            check(
                    "emulator_runtime",
                    "goldfish".equals(Build.HARDWARE) || "ranchu".equals(Build.HARDWARE));
            check(
                    "television_runtime",
                    ((UiModeManager) getTargetContext().getSystemService(Context.UI_MODE_SERVICE))
                                    .getCurrentModeType()
                            == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION);
            boolean legacyRejected = false;
            try {
                LegacyCallback.invoke();
            } catch (LinkageError expected) {
                legacyRejected = true;
                result.put("legacy_callback_failure", expected.getClass().getSimpleName());
            }
            check("old_callback_rejected_on_api23", legacyRejected);
            Context context = getTargetContext();
            context.getSharedPreferences("movie", 0)
                    .edit()
                    .clear()
                    .putBoolean("startup_animation", false)
                    .putInt(Prefs.SUBTITLE_SIZE, 45)
                    .putInt(Prefs.SUBTITLE_BOTTOM, 24)
                    .putInt(Prefs.SUBTITLE_STYLE, 0)
                    .commit();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            await("layout_ready", () -> ui(() -> a.layoutReady));
            runOnMainSync(
                    () -> a.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE));
            await("landscape_ready", () -> ui(() -> a.root.getWidth() > a.root.getHeight()));
            check("tv_edition", ui(a::isTvDevice));
            runOnMainSync(() -> a.open(new MainActivity.Screen(a::settings), false));
            clickTag("settings-playback");
            clickTag("setting-" + Prefs.SUBTITLE_SIZE);
            adjust("settings");
            clickTag("setting-" + Prefs.SUBTITLE_SIZE);
            await("settings_reopens", () -> textVisible(TITLE));
            check(
                    "settings_values_persist",
                    a.prefs.getInt(Prefs.SUBTITLE_SIZE, 0) == 47
                            && a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 0) == 30
                            && a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0) == 1);
            key(KeyEvent.KEYCODE_BACK);
            await("settings_reopen_dismissed", () -> !textVisible(TITLE));
            File media = new File(context.getCacheDir(), "api23-timeline.wav");
            try (InputStream input = getContext().getAssets().open("timeline.wav");
                    FileOutputStream output = new FileOutputStream(media)) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            }
            openPlayer(media);
            await(
                    "local_media_prepared",
                    () ->
                            ui(
                                    () ->
                                            a.prepared
                                                    && a.player != null
                                                    && a.player.getDuration() >= 59000));
            runOnMainSync(() -> a.showControls(true));
            clickTag("more");
            await("player_more_menu_visible", () -> textVisible("字幕与显示"));
            await("player_subtitle_entry_focused", () -> focusText("字幕与显示"));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            await("player_subtitle_menu_visible", () -> textVisible("方向键直调字幕"));
            await("player_subtitle_adjuster_focused", () -> focusText("方向键直调字幕"));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            adjust("player");
            check("player_survives_subtitle_dialog", ui(() -> a.prepared && a.player != null));
            result.put("passed", true);
        } catch (Throwable error) {
            try {
                result.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
            try {
                if (a != null) capture("subtitles-failure");
            } catch (Throwable captureError) {
                try {
                    result.put("failure_capture_error", captureError.toString());
                } catch (Exception ignored) {
                }
            }
        } finally {
            try {
                if (a != null)
                    runOnMainSync(
                            () -> {
                                a.releasePlayer();
                                a.finish();
                            });
            } catch (Throwable cleanupError) {
                try {
                    result.put("passed", false).put("cleanup_error", cleanupError.toString());
                } catch (Exception ignored) {
                }
            }
        }
        Bundle summary = new Bundle();
        summary.putString("result", result.toString());
        sendStatus(0, summary);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
