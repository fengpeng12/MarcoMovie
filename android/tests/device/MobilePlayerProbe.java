package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.content.pm.ActivityInfo;
import android.graphics.*;
import android.os.*;
import android.view.*;
import java.io.*;
import java.util.concurrent.*;
import org.json.*;

/** Runs the production player page with local media, including rotation and touch seeking. */
public final class MobilePlayerProbe extends Instrumentation {
    volatile MainActivity a;
    final JSONObject result = new JSONObject();
    final CountDownLatch launched = new CountDownLatch(1);

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

    boolean ui(Callable<Boolean> check) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = check.call();
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    }
                });
        return value[0];
    }

    void await(String name, Callable<Boolean> check) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 15000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (ui(check)) {
                result.put(name, true);
                return;
            }
            SystemClock.sleep(100);
        }
        throw new AssertionError(name);
    }

    void capture(String name) throws Exception {
        Bitmap screen = getUiAutomation().takeScreenshot();
        if (screen == null) return;
        try (FileOutputStream output =
                new FileOutputStream(new File(a.getExternalFilesDir(null), name + ".png"))) {
            screen.compress(Bitmap.CompressFormat.PNG, 100, output);
        } finally {
            screen.recycle();
        }
    }

    void verifyOrientation(String name, int orientation, boolean landscape) throws Exception {
        runOnMainSync(() -> a.setRequestedOrientation(orientation));
        await(
                name + "_rotated",
                () ->
                        (a.root.getWidth() > a.root.getHeight()) == landscape
                                && a.getWindowManager().getDefaultDisplay().getRotation()
                                        == (orientation
                                                        == ActivityInfo
                                                                .SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                                                ? Surface.ROTATION_270
                                                : landscape
                                                        ? Surface.ROTATION_90
                                                        : Surface.ROTATION_0));
        SystemClock.sleep(600);
        verifyBoundsAndSeek(name);
    }

    void verifyBoundsAndSeek(String name) throws Exception {
        runOnMainSync(() -> a.showControls(true));
        waitForIdleSync();
        SystemClock.sleep(250);
        capture(name);
        await(
                name + "_timeline_visible",
                () -> {
                    View timeline = a.playbackControls.timeline;
                    Rect bounds = new Rect();
                    Rect root = new Rect();
                    a.root.getGlobalVisibleRect(root);
                    return timeline.isShown()
                            && timeline.getWidth() > a.dp(100)
                            && timeline.getGlobalVisibleRect(bounds)
                            && bounds.width() >= timeline.getWidth() - 1
                            && bounds.height() >= timeline.getHeight() - 1
                            && root.contains(bounds)
                            && !a.isLive();
                });
        await(
                name + "_inside_safe_area",
                () -> {
                    View overlay = a.playerChrome.overlay;
                    int[] location = new int[2];
                    overlay.getLocationOnScreen(location);
                    Rect safe =
                            new Rect(
                                    location[0] + overlay.getPaddingLeft(),
                                    location[1] + overlay.getPaddingTop(),
                                    location[0] + overlay.getWidth() - overlay.getPaddingRight(),
                                    location[1] + overlay.getHeight() - overlay.getPaddingBottom());
                    Rect timeline = new Rect(), dock = new Rect(), progress = new Rect();
                    a.playbackControls.timeline.getGlobalVisibleRect(timeline);
                    a.playerChrome.dock.getGlobalVisibleRect(dock);
                    a.playerChrome.progress.getGlobalVisibleRect(progress);
                    return safe.contains(timeline)
                            && safe.contains(dock)
                            && safe.contains(progress)
                            && dock.width() == a.playerChrome.dock.getWidth()
                            && dock.height() == a.playerChrome.dock.getHeight()
                            && !Rect.intersects(timeline, dock);
                });
        await(
                name + "_heading_clear_of_controls",
                () -> {
                    Rect heading = new Rect(), center = new Rect();
                    return a.playerChrome.heading.getGlobalVisibleRect(heading)
                            && a.playerChrome.centerRow.getGlobalVisibleRect(center)
                            && !Rect.intersects(heading, center);
                });
        float[] point = new float[2];
        runOnMainSync(
                () -> {
                    View timeline = a.playbackControls.timeline;
                    int[] location = new int[2];
                    timeline.getLocationOnScreen(location);
                    point[0] = location[0] + timeline.getWidth() * .55f;
                    point[1] = location[1] + timeline.getHeight() * .5f;
                });
        long now = SystemClock.uptimeMillis();
        MotionEvent down =
                MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, point[0], point[1], 0);
        MotionEvent up =
                MotionEvent.obtain(now, now + 100, MotionEvent.ACTION_UP, point[0], point[1], 0);
        try {
            sendPointerSync(down);
            sendPointerSync(up);
        } finally {
            down.recycle();
            up.recycle();
        }
        await(
                name + "_touch_seek",
                () ->
                        a.player.getCurrentPosition() > 25000
                                && a.player.getCurrentPosition() < 45000);
        runOnMainSync(() -> a.player.seekTo(0));
    }

    void verifySmallerViewport() throws Exception {
        runOnMainSync(
                () -> {
                    // Reproduce a parent viewport smaller than cached activity/display metrics.
                    // This is controlled layout coverage, not a claim about any OEM firmware.
                    a.playbackLayer.setLayoutParams(
                            new android.widget.FrameLayout.LayoutParams(
                                    Math.round(a.root.getWidth() * .70f),
                                    Math.round(a.root.getHeight() * .75f),
                                    Gravity.CENTER));
                });
        await(
                "smaller_viewport_measured",
                () -> a.playerChrome.overlay.getWidth() < a.root.getWidth() * .75f);
        SystemClock.sleep(500);
        verifyBoundsAndSeek("smaller_viewport");
        runOnMainSync(
                () ->
                        a.playbackLayer.setLayoutParams(
                                new android.widget.FrameLayout.LayoutParams(-1, -1)));
        await(
                "full_viewport_restored",
                () -> a.playerChrome.overlay.getWidth() == a.root.getWidth());
        SystemClock.sleep(500);
        verifyBoundsAndSeek("restored_viewport");
    }

    @Override
    public void onStart() {
        try {
            Context context = getTargetContext();
            context.getSharedPreferences("movie", 0)
                    .edit()
                    .putBoolean("startup_animation", false)
                    .commit();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            await("layout_ready", () -> a.layoutReady);
            File media = new File(context.getCacheDir(), "timeline.wav");
            try (InputStream input = getContext().getAssets().open("timeline.wav");
                    FileOutputStream output = new FileOutputStream(media)) {
                byte[] bytes = new byte[8192];
                int count;
                while ((count = input.read(bytes)) != -1) output.write(bytes, 0, count);
            }
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.prefs.edit().putInt(Prefs.PLAYER_ENGINE, 1).commit();
                        a.liveSession =
                                new LiveSession(
                                        new LiveCatalog.Source(), new LiveCatalog.Catalog());
                        Cms.Site site = new Cms.Site();
                        site.key = "local-layout-fixture";
                        site.name = "Local layout fixture";
                        site.api = "";
                        site.playUrl = "";
                        Cms.Video video = new Cms.Video();
                        video.title = "Local timeline fixture";
                        Cms.Episode episode = new Cms.Episode();
                        episode.name = "Local media";
                        episode.url = android.net.Uri.fromFile(media).toString();
                        MainActivity.Screen page =
                                new MainActivity.Screen(() -> a.playerPage(site, video, episode));
                        page.player = true;
                        a.open(page, false);
                    });
            await(
                    "media_prepared",
                    () -> a.prepared && a.player != null && a.player.getDuration() >= 59000);
            verifyOrientation("landscape", ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, true);
            verifySmallerViewport();
            verifyOrientation(
                    "reverse_landscape", ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE, true);
            verifyOrientation("portrait", ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, false);
            result.put("passed", true);
        } catch (Throwable error) {
            try {
                result.put("passed", false).put("error", error.toString());
                capture("failure");
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null)
                runOnMainSync(
                        () -> {
                            a.releasePlayer();
                            a.finish();
                        });
        }
        Bundle summary = new Bundle();
        summary.putString("result", result.toString());
        sendStatus(0, summary);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
