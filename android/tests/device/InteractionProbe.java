package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.graphics.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic content only. Existing favorites and playback preferences are restored. */
public final class InteractionProbe extends Instrumentation {
    static final class SeekPlayer extends MoviePlayer {
        int position = 120000, calls;
        boolean running = true;

        SeekPlayer(Context c) {
            super(c, false);
        }

        @Override
        public int getDuration() {
            return 3600000;
        }

        @Override
        public int getCurrentPosition() {
            return position;
        }

        @Override
        public void seekTo(int value) {
            position = value;
            calls++;
        }

        @Override
        public boolean isPlaying() {
            return running;
        }

        @Override
        public void start() {
            running = true;
        }

        @Override
        public void pause() {
            running = false;
        }

        @Override
        public String videoResolution() {
            return "1920 × 1080";
        }

        @Override
        public void release() {}
    }

    void arrow(int action, int key, int repeats, long began) {
        runOnMainSync(
                () ->
                        a.dispatchKeyEvent(
                                new KeyEvent(
                                        began, SystemClock.uptimeMillis(), action, key, repeats)));
    }

    void seekChecks() throws Exception {
        MoviePlayer original = a.player;
        SeekPlayer fake = new SeekPlayer(a);
        String status = a.playStatus.getText().toString();
        try {
            runOnMainSync(
                    () -> {
                        original.pause();
                        a.player = fake;
                        a.prepared = true;
                        a.playing = true;
                        a.playbackControls.timeline.setMax(fake.getDuration());
                        a.showControls(false);
                    });
            long began = SystemClock.uptimeMillis();
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            arrow(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            check(
                    "hidden_right_tap_is_exactly_15s",
                    fake.position == 135000 && fake.calls == 1 && !a.seekGesture.active);
            began = SystemClock.uptimeMillis();
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT, 0, began);
            arrow(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_LEFT, 0, began);
            check("timeline_left_tap_is_exactly_15s", fake.position == 120000 && fake.calls == 2);
            final int before = fake.calls;
            began = SystemClock.uptimeMillis();
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            for (int repeat = 1; repeat <= 12; repeat++)
                arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT, repeat, began);
            final long pressStarted = began;
            check(
                    "native_repeats_do_not_stack_tap_steps",
                    ui(
                            () ->
                                    a.seekGesture.target >= 135000
                                            && a.seekGesture.target
                                                    <= 135000
                                                            + Math.max(
                                                                            0,
                                                                            SystemClock
                                                                                            .uptimeMillis()
                                                                                    - pressStarted
                                                                                    - 500)
                                                                    * 60
                                            && fake.calls == before));
            SystemClock.sleep(1100);
            check(
                    "held_seek_previews_without_network_seek",
                    ui(
                            () ->
                                    a.seekGesture.target > 135000
                                            && fake.calls == before
                                            && a.playbackControls.timeline.getProgress()
                                                    == a.seekGesture.target));
            SystemClock.sleep(2100);
            check(
                    "held_seek_accelerates_after_three_seconds",
                    ui(
                            () ->
                                    a.seekGesture.accelerated(SystemClock.uptimeMillis())
                                            && a.playStatus.getText().toString().contains("加速")));
            arrow(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            int committed = fake.position;
            check("release_commits_only_once", fake.calls == before + 1 && !a.seekGesture.active);
            SystemClock.sleep(350);
            check(
                    "release_stops_all_preview_updates",
                    fake.position == committed
                            && fake.calls == before + 1
                            && !a.seekGesture.active);
            began = SystemClock.uptimeMillis();
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT, 0, began);
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0, SystemClock.uptimeMillis());
            arrow(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0, SystemClock.uptimeMillis());
            check(
                    "back_cancels_preview_without_seek",
                    fake.calls == before + 1 && !a.seekGesture.active);
            runOnMainSync(
                    () -> {
                        a.showControls(true);
                        a.playbackControls.buttons.get("next-episode").requestFocus();
                    });
            began = SystemClock.uptimeMillis();
            arrow(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            arrow(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_RIGHT, 0, began);
            check(
                    "toolbar_arrows_keep_focus_navigation",
                    !a.seekGesture.active && fake.calls == before + 1);
        } finally {
            runOnMainSync(
                    () -> {
                        a.finishSeek(false);
                        a.player = original;
                        a.prepared = true;
                        a.playing = true;
                        a.playStatus.setText(status);
                        a.playbackControls.timeline.setMax(original.getDuration());
                        original.start();
                        a.showControls(false);
                    });
        }
    }

    Bundle args;
    MainActivity a;
    final CountDownLatch launched = new CountDownLatch(1);
    JSONObject result = new JSONObject();

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
    public void onCreate(Bundle input) {
        super.onCreate(input);
        args = input;
        start();
    }

    void check(String name, boolean pass) throws Exception {
        result.put(name, pass);
        if (!pass) throw new AssertionError(name);
    }

    boolean ui(java.util.concurrent.Callable<Boolean> action) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = action.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return value[0];
    }

    boolean within(Callable<Boolean> fn, int ms) {
        long end = SystemClock.elapsedRealtime() + ms;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(fn)) return true;
            SystemClock.sleep(30);
        }
        return ui(fn);
    }

    void key(int code) {
        long end = SystemClock.elapsedRealtime() + 4000;
        while (SystemClock.elapsedRealtime() < end
                && !ui(
                        () ->
                                a.hasWindowFocus()
                                        || (a.playbackControls != null
                                                && a.playbackControls.activeDialog != null
                                                && a.playbackControls
                                                        .activeDialog
                                                        .getWindow()
                                                        .getDecorView()
                                                        .hasWindowFocus())
                                        || (a.appDialog != null
                                                && a.appDialog
                                                        .getWindow()
                                                        .getDecorView()
                                                        .hasWindowFocus())
                                        || (a.accountDialog != null
                                                && a.accountDialog
                                                        .getWindow()
                                                        .getDecorView()
                                                        .hasWindowFocus()))) SystemClock.sleep(100);
        sendKeyDownUpSync(code);
        SystemClock.sleep(220);
    }

    void frame(String name) throws Exception {
        if ("false".equals(args.getString("screenshots"))) return;
        Bitmap bitmap = getUiAutomation().takeScreenshot();
        if (bitmap == null) throw new IOException("Screenshot unavailable");
        File file = new File(a.getExternalFilesDir(null), "test-" + name + ".png");
        try (OutputStream out = new FileOutputStream(file)) {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        }
        bitmap.recycle();
    }

    @Override
    public void onStart() {
        String favorites = null, history = null;
        boolean hadFavorites = false, hadHistory = false;
        Cms.Config original = null;
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new IOException("Launch timeout");
            SharedPreferences originalPrefs = a.prefs;
            SharedPreferences fixture =
                    getTargetContext().getSharedPreferences("interaction_probe_fixture", 0);
            SharedPreferences.Editor copy = fixture.edit().clear();
            for (java.util.Map.Entry<String, ?> entry : originalPrefs.getAll().entrySet()) {
                Object value = entry.getValue();
                if (value instanceof String) copy.putString(entry.getKey(), (String) value);
                else if (value instanceof Integer) copy.putInt(entry.getKey(), (Integer) value);
                else if (value instanceof Boolean) copy.putBoolean(entry.getKey(), (Boolean) value);
                else if (value instanceof Long) copy.putLong(entry.getKey(), (Long) value);
                else if (value instanceof Float) copy.putFloat(entry.getKey(), (Float) value);
            }
            copy.commit();
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        if (a.startupIntro != null) a.startupIntro.cancel();
                    });
            favorites = a.prefs.getString("favorites", "[]");
            hadFavorites = a.prefs.contains("favorites");
            history = a.prefs.getString("watch_history", "[]");
            hadHistory = a.prefs.contains("watch_history");
            original = a.config;
            Cms.Site site = new Cms.Site();
            site.key = "interaction-test";
            site.name = "Synthetic";
            site.type = 1;
            site.api = "https://fixture.test/api";
            Cms.Video video = new Cms.Video();
            video.id = "sample";
            video.title = "Marco Movie · 测试画面";
            video.poster = "https://fixture.test/poster.png";
            video.remarks = "本地合成样本";
            Bitmap poster = Bitmap.createBitmap(376, 564, Bitmap.Config.ARGB_8888);
            Canvas cover = new Canvas(poster);
            Paint pen = new Paint(3);
            pen.setShader(
                    new LinearGradient(
                            0, 0, 376, 564, 0xff244f68, 0xff9d8263, Shader.TileMode.CLAMP));
            cover.drawRect(0, 0, 376, 564, pen);
            pen.setShader(null);
            pen.setColor(0x55ffffff);
            cover.drawCircle(188, 205, 100, pen);
            pen.setColor(Color.WHITE);
            pen.setTextSize(26);
            pen.setTextAlign(Paint.Align.CENTER);
            cover.drawText("MARCO MOVIE", 188, 415, pen);
            pen.setTextSize(18);
            cover.drawText("SYNTHETIC POSTER", 188, 450, pen);
            a.images.put(video.poster, poster);
            Cms.Episode ep = new Cms.Episode();
            ep.name = "遥控体验";
            ep.url = args.getString("base") + "h264-aac.mp4";
            Cms.Line testLine = new Cms.Line();
            testLine.name = "测试线路";
            testLine.episodes.add(ep);
            Cms.Episode second = new Cms.Episode();
            second.name = "第 2 集";
            second.url = ep.url;
            testLine.episodes.add(second);
            video.lines.add(testLine);
            video.description = "合成画面用于检查返回选集页时，视频继续播放。";
            runOnMainSync(
                    () -> {
                        a.activeLine = testLine;
                        a.activeEpisode = ep;
                        a.openPlayer(site, video, ep);
                    });
            long until = SystemClock.elapsedRealtime() + 25000;
            while (SystemClock.elapsedRealtime() < until && !ui(() -> a.prepared))
                SystemClock.sleep(100);
            check("real_video_prepared", ui(() -> a.prepared));
            runOnMainSync(
                    () -> {
                        a.player.setRepeatOne(true);
                        a.showControls(false);
                    });
            SystemClock.sleep(250);
            check(
                    "next_is_first",
                    ui(
                            () ->
                                    a.playbackControls
                                            .buttons
                                            .keySet()
                                            .iterator()
                                            .next()
                                            .equals("next-episode")));
            check("no_pause_button", ui(() -> !a.playbackControls.buttons.containsKey("primary")));
            seekChecks();
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("confirm_pauses", ui(() -> !a.player.isPlaying() && a.controlsVisible));
            int pos = a.player.getCurrentPosition();
            SystemClock.sleep(450);
            check("paused_clock_stable", Math.abs(a.player.getCurrentPosition() - pos) < 120);
            frame("dock");
            check(
                    "three_separate_regions",
                    ui(
                            () ->
                                    a.playerChrome.dock.getParent() == a.playerOverlay
                                            && a.playerChrome.progress.getParent()
                                                    == a.playerOverlay
                                            && a.playerChrome.heading.getParent()
                                                    == a.playerOverlay));
            check(
                    "resolution_matches_media",
                    ui(
                            () ->
                                    a.playerChrome
                                                    .resolution
                                                    .getText()
                                                    .toString()
                                                    .equals(a.player.videoResolution())
                                            && !a.player.videoResolution().equals("分辨率未知")));
            check(
                    "dock_lower_margin",
                    ui(
                            () ->
                                    ((android.widget.FrameLayout.LayoutParams)
                                                            a.playerChrome.dock.getLayoutParams())
                                                    .bottomMargin
                                            == a.dp(16)));
            check(
                    "progress_lower_margin",
                    ui(
                            () ->
                                    ((android.widget.FrameLayout.LayoutParams)
                                                            a.playerChrome.progress
                                                                    .getLayoutParams())
                                                    .bottomMargin
                                            == a.dp(94)));
            check(
                    "compact_dock_width",
                    ui(() -> a.playerChrome.dock.getWidth() < a.root.getWidth() * .65f));
            check(
                    "title_at_top",
                    ui(() -> a.playerChrome.heading.getBottom() < a.root.getHeight() / 3));
            check(
                    "progress_above_dock",
                    ui(() -> a.playerChrome.progress.getBottom() < a.playerChrome.dock.getTop()));
            check(
                    "center_pause_state",
                    ui(
                            () ->
                                    a.playerChrome
                                                    .state
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("已暂停")
                                            && Math.abs(
                                                            a.playerChrome.state.getX()
                                                                    + a.playerChrome.state
                                                                                    .getWidth()
                                                                            / 2f
                                                                    - a.root.getWidth() / 2f)
                                                    < 2));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("confirm_resumes", ui(() -> a.player.isPlaying()));
            check(
                    "center_playing_state",
                    ui(
                            () ->
                                    a.playerChrome
                                            .state
                                            .getContentDescription()
                                            .toString()
                                            .startsWith("正在播放")));
            runOnMainSync(() -> a.showControls(false));
            key(KeyEvent.KEYCODE_DPAD_UP);
            check(
                    "up_opens_first_action",
                    ui(
                            () ->
                                    a.controlsVisible
                                            && a.getCurrentFocus()
                                                    == a.playbackControls.buttons.get(
                                                            "next-episode")));
            runOnMainSync(() -> a.showControls(false));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "down_opens_first_action",
                    ui(
                            () ->
                                    a.controlsVisible
                                            && a.getCurrentFocus()
                                                    == a.playbackControls.buttons.get(
                                                            "next-episode")));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "dock_buttons_reachable",
                    ui(
                            () ->
                                    a.getCurrentFocus()
                                            == a.playbackControls.buttons.get("next-episode")));
            for (boolean single : new boolean[] {false, true}) {
                String scenario = single ? "single_movie" : "last_episode";
                runOnMainSync(
                        () -> {
                            a.prefs.edit().putInt("repeat_mode", 0).apply();
                            if (single) testLine.episodes.remove(second);
                            a.activeEpisode = single ? ep : second;
                            a.playbackControls.prepared();
                            a.player.setRepeatOne(true);
                            a.showControls(false);
                        });
                SystemClock.sleep(250);
                key(KeyEvent.KEYCODE_DPAD_DOWN);
                check(
                        scenario + "_reveals_controls",
                        ui(
                                () ->
                                        a.controlsVisible
                                                && a.getCurrentFocus()
                                                        == a.playbackControls.buttons.get(
                                                                "next-episode")));
                key(KeyEvent.KEYCODE_DPAD_DOWN);
                check(
                        scenario + "_next_focusable",
                        ui(
                                () ->
                                        a.getCurrentFocus()
                                                        == a.playbackControls.buttons.get(
                                                                "next-episode")
                                                && a.getCurrentFocus().isEnabled()));
                MoviePlayer unchanged = a.player;
                Cms.Episode unchangedEpisode = a.activeEpisode;
                key(KeyEvent.KEYCODE_DPAD_CENTER);
                check(
                        scenario + "_no_next_bubble",
                        ui(
                                () -> {
                                    if (a.playbackControls.activeDialog == null
                                            || a.playbackControls.activeDialog
                                                    instanceof AlertDialog) return false;
                                    ArrayList<View> text = new ArrayList<>();
                                    a.playbackControls
                                            .activeDialog
                                            .getWindow()
                                            .getDecorView()
                                            .findViewsWithText(
                                                    text, "无下集", View.FIND_VIEWS_WITH_TEXT);
                                    return a.playbackControls.dialogOpen
                                            && !text.isEmpty()
                                            && a.playbackControls.menuAnchor
                                                    == a.playbackControls.buttons.get(
                                                            "next-episode");
                                }));
                check(
                        scenario + "_playback_continues",
                        ui(
                                () ->
                                        a.player == unchanged
                                                && a.player.isPlaying()
                                                && a.activeEpisode == unchangedEpisode
                                                && !a.playbackControls.transitioning));
                check(
                        scenario + "_bubble_above_next",
                        ui(
                                () -> {
                                    if (a.playbackControls.activeDialog == null) return false;
                                    int[] anchor = new int[2];
                                    a.playbackControls
                                            .buttons
                                            .get("next-episode")
                                            .getLocationOnScreen(anchor);
                                    Window w = a.playbackControls.activeDialog.getWindow();
                                    return w.getAttributes().y + w.getDecorView().getHeight()
                                                    <= anchor[1]
                                            && w.getDecorView().getHeight() < a.dp(190);
                                }));
                if (single) key(KeyEvent.KEYCODE_BACK);
                else key(KeyEvent.KEYCODE_DPAD_CENTER);
                check(
                        scenario + "_dismiss_restores_next",
                        ui(
                                () ->
                                        !a.playbackControls.dialogOpen
                                                && a.getCurrentFocus()
                                                        == a.playbackControls.buttons.get(
                                                                "next-episode")));
                key(KeyEvent.KEYCODE_DPAD_UP);
                check(
                        scenario + "_up_returns_to_timeline",
                        ui(() -> a.getCurrentFocus() == a.playbackControls.timeline));
            }
            runOnMainSync(
                    () -> {
                        testLine.episodes.add(second);
                        a.activeEpisode = ep;
                        a.playbackControls.prepared();
                        a.player.setRepeatOne(true);
                    });
            runOnMainSync(() -> a.playbackControls.buttons.get("speed").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("confirm_activates_focused_action", ui(() -> a.playbackControls.dialogOpen));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "menu_focus_restored",
                    ui(() -> a.getCurrentFocus() == a.playbackControls.buttons.get("speed")));
            runOnMainSync(() -> a.playbackControls.buttons.get("more").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "more_custom_bubble",
                    ui(
                            () ->
                                    a.playbackControls.activeDialog != null
                                            && !(a.playbackControls.activeDialog
                                                    instanceof AlertDialog)
                                            && a.playbackControls
                                                            .activeDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag("player-bubble")
                                                    != null));
            check(
                    "bubble_above_anchor",
                    ui(
                            () -> {
                                int[] button = new int[2];
                                a.playbackControls.buttons.get("more").getLocationOnScreen(button);
                                Window w = a.playbackControls.activeDialog.getWindow();
                                return w.getAttributes().y + w.getDecorView().getHeight()
                                        <= button[1];
                            }));
            frame("more");
            check(
                    "bubble_compact_height",
                    ui(
                            () ->
                                    a.playbackControls
                                                    .activeDialog
                                                    .getWindow()
                                                    .getDecorView()
                                                    .getHeight()
                                            < a.root.getHeight() * .7f));
            for (int i = 0; i < 12; i++) key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "bubble_last_option_reachable",
                    ui(
                            () ->
                                    "player-option:12"
                                            .equals(
                                                    a.playbackControls
                                                            .activeDialog
                                                            .getCurrentFocus()
                                                            .getTag())));
            frame("more-scrolled");
            runOnMainSync(
                    () ->
                            a.playbackControls
                                    .activeDialog
                                    .findViewById(android.R.id.content)
                                    .findViewWithTag("player-option:1")
                                    .requestFocus());
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "more_nested_custom_bubble",
                    ui(
                            () ->
                                    a.playbackControls.dialogOpen
                                            && !(a.playbackControls.activeDialog
                                                    instanceof AlertDialog)));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "more_focus_restored",
                    ui(() -> a.getCurrentFocus() == a.playbackControls.buttons.get("more")));
            MoviePlayer originalPlayer = a.player;
            VideoOutput originalSurface = a.playbackControls.surface;
            runOnMainSync(() -> a.player.seekTo(2000));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "back_hides_controls_first",
                    ui(() -> !a.controlsVisible && !a.miniMode && a.player == originalPlayer));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "back_minimizes_to_details",
                    ui(() -> a.miniMode && a.root.findViewWithTag("mini-details") != null));
            SystemClock.sleep(220);
            check(
                    "all_regions_hidden_together",
                    ui(
                            () ->
                                    a.playerOverlay.getVisibility() == View.GONE
                                            && !a.playerChrome.heading.isShown()
                                            && !a.playerChrome.progress.isShown()
                                            && !a.playerChrome.state.isShown()));
            check(
                    "mini_reuses_player_and_surface",
                    ui(
                            () ->
                                    a.player == originalPlayer
                                            && a.playbackControls.surface == originalSurface
                                            && a.prepared));
            int miniPosition = a.player.getCurrentPosition();
            SystemClock.sleep(550);
            check(
                    "mini_playback_clock_advances",
                    ui(
                            () ->
                                    a.player.isPlaying()
                                            && a.player.getCurrentPosition() > miniPosition + 250));
            check(
                    "mini_large_poster",
                    ui(() -> a.root.findViewWithTag("mini-cover").getWidth() >= a.dp(250)));
            check(
                    "mini_does_not_overlap_cover",
                    ui(
                            () ->
                                    a.playbackLayer.getLeft()
                                            >= a.root.findViewWithTag("mini-cover").getRight()));
            check(
                    "mini_details_has_cover_and_episodes",
                    ui(
                            () ->
                                    a.root.findViewWithTag("mini-cover") != null
                                            && a.root.findViewWithTag("episode:测试线路:1") != null
                                            && a.root.findViewWithTag("nav-home") == null));
            frame("mini");
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "mini_confirm_expands",
                    ui(
                            () ->
                                    !a.miniMode
                                            && a.player == originalPlayer
                                            && a.playbackLayer.getWidth() == a.root.getWidth()));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("pause_before_minimize", ui(() -> !a.player.isPlaying()));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "back_hides_paused_overlay",
                    ui(() -> !a.controlsVisible && !a.miniMode && !a.player.isPlaying()));
            key(KeyEvent.KEYCODE_BACK);
            check("paused_state_survives_minimize", ui(() -> a.miniMode && !a.player.isPlaying()));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("paused_state_survives_expand", ui(() -> !a.miniMode && !a.player.isPlaying()));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            key(KeyEvent.KEYCODE_BACK);
            key(KeyEvent.KEYCODE_BACK);
            runOnMainSync(() -> a.root.findViewWithTag("episode:测试线路:1").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            long switchLimit = SystemClock.elapsedRealtime() + 20000;
            while (SystemClock.elapsedRealtime() < switchLimit
                    && !ui(() -> a.prepared && a.miniMode)) SystemClock.sleep(100);
            check(
                    "mini_switches_episode",
                    ui(() -> a.prepared && a.miniMode && a.activeEpisode == second));
            runOnMainSync(
                    () -> {
                        a.releasePlayer();
                        a.prefs.edit().putString("favorites", "[]").commit();
                        a.engines.put(
                                site.key,
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
                                        return new JSONObject()
                                                .put(
                                                        "list",
                                                        new JSONArray()
                                                                .put(
                                                                        new JSONObject()
                                                                                .put(
                                                                                        "vod_id",
                                                                                        video.id)
                                                                                .put(
                                                                                        "vod_name",
                                                                                        video.title)
                                                                                .put("vod_pic", "")
                                                                                .put(
                                                                                        "vod_content",
                                                                                        "这是用于检查封面、简介与选集布局的合成内容。详情页保留影片信息、收藏和选集，遥控器返回键回到上一页。")
                                                                                .put(
                                                                                        "vod_year",
                                                                                        "2026")
                                                                                .put(
                                                                                        "vod_area",
                                                                                        "合成样本")
                                                                                .put(
                                                                                        "vod_play_from",
                                                                                        "测试线路")
                                                                                .put(
                                                                                        "vod_play_url",
                                                                                        "第 1 集$"
                                                                                                + ep.url
                                                                                                + "#第 2 集$"
                                                                                                + ep.url)))
                                                .toString();
                                    }
                                });
                        a.open(new MainActivity.Screen(() -> a.detail(site, video)), true);
                    });
            long detailLimit = SystemClock.elapsedRealtime() + 10000;
            while (SystemClock.elapsedRealtime() < detailLimit
                    && !ui(() -> a.root.findViewWithTag("detail-favorite") != null))
                SystemClock.sleep(100);
            check(
                    "detail_favorite_button",
                    ui(() -> a.root.findViewWithTag("detail-favorite") != null));
            runOnMainSync(() -> a.root.findViewWithTag("detail-favorite").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "detail_adds_favorite",
                    Favorites.contains(a.prefs.getString("favorites", "[]"), site.key, video.id));
            check(
                    "detail_without_global_nav",
                    ui(
                            () ->
                                    a.root.findViewWithTag("nav-home") == null
                                            && a.root.findViewWithTag("nav-accounts") == null));
            check(
                    "detail_poster_visible",
                    ui(
                            () -> {
                                ViewGroup box = (ViewGroup) a.root.findViewWithTag("detail-cover");
                                return box != null
                                        && box.getHeight() > box.getWidth()
                                        && ((android.widget.ImageView) box.getChildAt(1))
                                                        .getDrawable()
                                                != null;
                            }));
            check(
                    "large_detail_poster",
                    ui(() -> a.root.findViewWithTag("detail-cover").getWidth() >= a.dp(250)));
            check(
                    "softened_backdrop_ready",
                    ui(
                            () ->
                                    ((ImmersivePoster) a.root.findViewWithTag("detail-cover"))
                                                    .backdrop
                                                    .bitmap
                                            != null));
            check(
                    "primary_play_available",
                    ui(() -> a.root.findViewWithTag("detail-play") != null));
            check(
                    "detail_episodes_available",
                    ui(() -> a.root.findViewWithTag("episode:测试线路:0") != null));
            frame("detail");
            runOnMainSync(
                    () ->
                            a.open(
                                    new MainActivity.Screen(() -> new FavoritesScreen(a).show()),
                                    true));
            check(
                    "favorites_entry",
                    ui(
                            () ->
                                    a.root.findViewWithTag("nav-favorites") == null
                                            && a.root.findViewWithTag(
                                                            "favorite:"
                                                                    + site.key
                                                                    + "\n"
                                                                    + video.id)
                                                    != null));
            SystemClock.sleep(350);
            frame("favorites");
            runOnMainSync(
                    () ->
                            a.root.findViewWithTag("favorite:" + site.key + "\n" + video.id)
                                    .requestFocus());
            key(KeyEvent.KEYCODE_MENU);
            boolean removed =
                    ui(
                            () ->
                                    a.appDialog != null
                                            && a.appDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("dialog-option:1")
                                                    .performClick());
            check("favorite_remove_action", removed);
            SystemClock.sleep(350);
            check(
                    "favorites_empty_state",
                    ui(() -> Favorites.read(a.prefs.getString("favorites", "[]")).isEmpty()));
            runOnMainSync(
                    () -> {
                        a.open(new MainActivity.Screen(() -> new SettingsScreen(a).show()), true);
                    });
            check(
                    "no_duplicate_account_settings",
                    ui(() -> a.root.findViewWithTag("settings-accounts") == null));
            runOnMainSync(
                    () -> {
                        a.open(new MainActivity.Screen(a::home), true);
                        a.root.findViewWithTag("nav-accounts").performClick();
                    });
            SystemClock.sleep(350);
            check(
                    "account_popup_visible",
                    ui(() -> a.accountDialog != null && a.accountDialog.isShowing()));
            check(
                    "single_login_entry",
                    ui(
                            () ->
                                    a.accountDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("account-action:LoginShow")
                                            != null));
            frame("accounts");
            key(KeyEvent.KEYCODE_BACK);
            boolean accountRestored =
                    within(
                            () ->
                                    a.accountDialog == null
                                            && a.getCurrentFocus()
                                                    == a.root.findViewWithTag("nav-accounts"),
                            1500);
            if (!accountRestored) {
                String[] seen = {""};
                runOnMainSync(
                        () -> {
                            View f = a.getCurrentFocus();
                            seen[0] =
                                    "dialog="
                                            + (a.accountDialog == null
                                                    ? "null"
                                                    : a.accountDialog.isShowing()
                                                            ? "showing"
                                                            : "hidden")
                                            + " focus="
                                            + (f == null
                                                    ? "null"
                                                    : f.getClass().getSimpleName()
                                                            + ":"
                                                            + f.getTag())
                                            + " windowFocus="
                                            + a.hasWindowFocus()
                                            + " finishing="
                                            + a.isFinishing()
                                            + " screenHome="
                                            + (a.current != null && a.current.home)
                                            + " anchorAttached="
                                            + (a.root.findViewWithTag("nav-accounts") != null);
                        });
                result.put("account_focus_debug", seen[0]);
            }
            check("account_focus_restored", accountRestored);
            runOnMainSync(
                    () -> {
                        a.open(
                                new MainActivity.Screen(() -> new SettingsScreen(a).appearance()),
                                true);
                        a.root.findViewWithTag("setting-home_columns").performClick();
                    });
            SystemClock.sleep(300);
            check(
                    "settings_use_app_dialog",
                    ui(
                            () ->
                                    a.appDialog != null
                                            && a.appDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag("app-dialog")
                                                    != null));
            frame("settings-dialog");
            key(KeyEvent.KEYCODE_BACK);
            runOnMainSync(() -> a.addressImportDialog());
            SystemClock.sleep(300);
            check(
                    "config_has_local_keyboard",
                    ui(
                            () -> {
                                View v =
                                        a.appDialog
                                                .findViewById(android.R.id.content)
                                                .findViewWithTag("address-input");
                                return v instanceof android.widget.EditText
                                        && !((android.widget.EditText) v).getShowSoftInputOnFocus();
                            }));
            runOnMainSync(
                    () ->
                            ((android.widget.EditText)
                                            a.appDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("address-input"))
                                    .setText(""));
            frame("address-dialog");
            runOnMainSync(() -> a.appDialog.getButton(-1).performClick());
            check(
                    "invalid_address_stays_open",
                    ui(() -> a.appDialog != null && a.appDialog.isShowing()));
            key(KeyEvent.KEYCODE_BACK);
            runOnMainSync(() -> a.notice("统一样式检查"));
            check("notice_uses_app_dialog", ui(() -> a.appDialog != null));
            key(KeyEvent.KEYCODE_BACK);
            runOnMainSync(() -> new SettingsScreen(a).confirm("确认样式检查", () -> {}));
            check(
                    "confirmation_uses_app_dialog",
                    ui(() -> a.appDialog != null && a.appDialog.getButton(-2) != null));
            key(KeyEvent.KEYCODE_BACK);
            runOnMainSync(() -> a.open(new MainActivity.Screen(a::home), true));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "home_back_finishes_without_dialog",
                    ui(() -> a.isFinishing() && a.appDialog == null));
            result.put("passed", true);
        } catch (Throwable error) {
            try {
                result.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                String saved = favorites, savedHistory = history;
                boolean present = hadFavorites, presentHistory = hadHistory;
                Cms.Config config = original;
                runOnMainSync(
                        () -> {
                            a.releasePlayer();
                            if (a.accountDialog != null) a.accountDialog.dismiss();
                            if (a.appDialog != null) a.appDialog.dismiss();
                            if (saved != null) {
                                if (present) a.prefs.edit().putString("favorites", saved).commit();
                                else a.prefs.edit().remove("favorites").commit();
                            }
                            if (savedHistory != null) {
                                if (presentHistory)
                                    a.prefs
                                            .edit()
                                            .putString("watch_history", savedHistory)
                                            .commit();
                                else a.prefs.edit().remove("watch_history").commit();
                            }
                            a.engines.remove("interaction-test");
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.prefs = getTargetContext().getSharedPreferences("movie", 0);
                            a.config = config;
                        });
            }
        }
        Bundle report = new Bundle();
        report.putString("result", result.toString());
        sendStatus(0, report);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
