package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.util.concurrent.*;
import org.json.*;

/** Verifies intermediate and interrupted animation state with isolated preferences. */
public final class MotionProbe extends Instrumentation {
    MainActivity a;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject report = new JSONObject();

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

    void check(String key, boolean ok) throws Exception {
        report.put(key, ok);
        if (!ok) throw new AssertionError(key);
    }

    View tag(String key) {
        return a.root.findViewWithTag(key);
    }

    FocusMotion.State state(View v) {
        return (FocusMotion.State) v.getTag(R.id.focus_motion);
    }

    void frame(String name) {
        runOnMainSync(
                () -> {
                    android.graphics.Bitmap b =
                            android.graphics.Bitmap.createBitmap(
                                    a.root.getWidth(),
                                    a.root.getHeight(),
                                    android.graphics.Bitmap.Config.ARGB_8888);
                    a.root.draw(new android.graphics.Canvas(b));
                    try (java.io.FileOutputStream out =
                            new java.io.FileOutputStream(
                                    new java.io.File(a.getExternalFilesDir(null), name + ".png"))) {
                        b.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out);
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    } finally {
                        b.recycle();
                    }
                });
    }

    @Override
    public void onStart() {
        SharedPreferences original = null;
        boolean oldReduced = false;
        try {
            Context c = getTargetContext();
            c.startActivity(
                    new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            original = a.prefs;
            oldReduced = a.reduced;
            SharedPreferences fixture = c.getSharedPreferences("motion_probe_fixture", 0);
            fixture.edit().clear().commit();
            final Button[] buttons = new Button[2];
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        a.reduced = false;
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.open(
                                new MainActivity.Screen(
                                        () -> {
                                            a.renderPage("动效验证", "");
                                            buttons[0] = a.button("第一个", "motion-first", () -> {});
                                            buttons[1] = a.button("第二个", "motion-second", () -> {});
                                            a.addButton(a.body, buttons[0]);
                                            a.addButton(a.body, buttons[1]);
                                        }),
                                false);
                    });
            SystemClock.sleep(300);
            runOnMainSync(() -> buttons[0].requestFocus());
            SystemClock.sleep(420);
            runOnMainSync(() -> buttons[1].requestFocus());
            SystemClock.sleep(45);
            check(
                    "background_has_intermediate_color",
                    ui(
                            () ->
                                    state(buttons[1]) != null
                                            && state(buttons[1]).color != 0xff242429
                                            && state(buttons[1]).color != MainActivity.WHITE));
            check(
                    "scale_has_intermediate_value",
                    ui(() -> buttons[1].getScaleX() > 1 && buttons[1].getScaleX() < 1.026f));
            SystemClock.sleep(420);
            check(
                    "focused_state_settles",
                    ui(
                            () ->
                                    state(buttons[1]).animator == null
                                            && state(buttons[1]).color == MainActivity.WHITE
                                            && Math.abs(buttons[1].getScaleX() - 1.025f) < .001));
            check(
                    "focus_text_readable",
                    ui(() -> buttons[1].getCurrentTextColor() == MainActivity.DARK));
            check(
                    "lost_focus_resets",
                    ui(
                            () ->
                                    state(buttons[0]).color == 0xff242429
                                            && Math.abs(buttons[0].getScaleX() - 1) < .001));
            runOnMainSync(
                    () -> {
                        for (int i = 0; i < 50; i++) buttons[i % 2].requestFocus();
                        buttons[0].requestFocus();
                    });
            SystemClock.sleep(420);
            check(
                    "rapid_focus_has_one_final_target",
                    ui(
                            () ->
                                    buttons[0].hasFocus()
                                            && state(buttons[0]).animator == null
                                            && state(buttons[1]).animator == null));
            check(
                    "rapid_focus_has_no_residual_scale",
                    ui(
                            () ->
                                    Math.abs(buttons[1].getScaleX() - 1) < .001
                                            && Math.abs(buttons[0].getScaleX() - 1.025f) < .001));
            runOnMainSync(() -> FocusMotion.press(a, buttons[0], true));
            SystemClock.sleep(100);
            check(
                    "press_compresses_focused_button",
                    ui(() -> buttons[0].getScaleX() < 1.025f && buttons[0].getAlpha() < 1));
            runOnMainSync(() -> FocusMotion.press(a, buttons[0], false));
            SystemClock.sleep(350);
            check(
                    "release_recovers_focus_scale",
                    ui(
                            () ->
                                    Math.abs(buttons[0].getScaleX() - 1.025f) < .001
                                            && buttons[0].getAlpha() == 1));
            runOnMainSync(
                    () -> {
                        a.reduced = true;
                        buttons[1].requestFocus();
                    });
            check(
                    "reduced_motion_is_immediate",
                    ui(
                            () ->
                                    state(buttons[1]).animator == null
                                            && buttons[1].getScaleX() == 1
                                            && state(buttons[1]).color == MainActivity.WHITE));
            runOnMainSync(() -> a.reduced = false);
            runOnMainSync(() -> buttons[0].requestFocus());
            View old = buttons[0];
            runOnMainSync(
                    () ->
                            a.open(
                                    new MainActivity.Screen(() -> new SettingsScreen(a).show()),
                                    true));
            check(
                    "detached_views_cancel_animation",
                    ui(() -> state(old).animator == null && !state(old).pressed));
            SystemClock.sleep(420);
            check(
                    "settings_rows_share_motion",
                    ui(() -> a.getCurrentFocus() != null && state(a.getCurrentFocus()) != null));
            check(
                    "settings_focus_not_clipped_by_content_padding",
                    ui(() -> !a.body.getClipToPadding() && !a.body.getClipChildren()));
            frame("motion-settings");
            runOnMainSync(() -> a.notice("动效弹窗"));
            SystemClock.sleep(200);
            runOnMainSync(() -> a.appDialog.getButton(-1).requestFocus());
            SystemClock.sleep(420);
            check(
                    "dialog_buttons_share_motion",
                    ui(() -> state(a.appDialog.getButton(-1)) != null));
            runOnMainSync(() -> a.appDialog.dismiss());
            check("dialog_restores_focus", ui(() -> a.getCurrentFocus() != null));
            runOnMainSync(
                    () -> {
                        a.renderPage("", "", true);
                    });
            SystemClock.sleep(200);
            runOnMainSync(() -> tag("nav-search").requestFocus());
            SystemClock.sleep(420);
            check(
                    "dock_icons_share_motion",
                    ui(
                            () ->
                                    state(tag("nav-search")) != null
                                            && tag("nav-search").getScaleX() > 1));
            check(
                    "dock_label_visible",
                    ui(() -> tag("home-dock-label").getVisibility() == View.VISIBLE));
            runOnMainSync(() -> tag("nav-settings").requestFocus());
            SystemClock.sleep(420);
            check(
                    "dock_label_tracks_latest_focus",
                    ui(
                            () ->
                                    ((TextView) tag("home-dock-label"))
                                                    .getText()
                                                    .toString()
                                                    .equals("设置")
                                            && tag("home-dock-label").getAlpha() == 1));
            frame("motion-dock");
            report.put("passed", true);
        } catch (Throwable e) {
            try {
                report.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                SharedPreferences prefs = original;
                boolean reduced = oldReduced;
                runOnMainSync(
                        () -> {
                            if (a.appDialog != null) a.appDialog.dismiss();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.prefs = prefs;
                            a.reduced = reduced;
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
