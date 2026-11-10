package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.graphics.*;
import android.graphics.drawable.BitmapDrawable;
import java.util.concurrent.*;
import java.net.*;
import java.io.*;
import org.json.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;

/** Isolated preferences and synthetic media; never imports over the user's configuration. */
public final class ConfigLiveProbe extends Instrumentation {
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
                            if (created.layoutReady) launched.countDown();
                            else created.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    boolean ui(Callable<Boolean> f) {
        boolean[] v = {false};
        runOnMainSync(
                () -> {
                    try {
                        v[0] = f.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return v[0];
    }

    void await(Callable<Boolean> f) throws Exception {
        long end = SystemClock.elapsedRealtime() + 20000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(f)) return;
            SystemClock.sleep(30);
        }
        throw new AssertionError("timeout");
    }

    void check(String key, boolean v) throws Exception {
        report.put(key, v);
        if (!v) throw new AssertionError(key);
    }

    void key(int key) throws Exception {
        await(() -> a.hasWindowFocus());
        sendKeyDownUpSync(key);
        SystemClock.sleep(100);
    }

    byte[] read(File file) throws IOException {
        if (!file.exists()) return new byte[0];
        try (InputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[8192];
            for (int n; (n = in.read(b)) != -1; ) out.write(b, 0, n);
            return out.toByteArray();
        }
    }

    @Override
    public void onStart() {
        SharedPreferences prefs = null;
        Cms.Config config = null;
        ConfigStore store = null;
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            prefs = a.prefs;
            config = a.config;
            store = a.configStore;
            byte[] originalFile = read(new File(a.getFilesDir(), "config.json"));
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.configStore =
                                new ConfigStore(
                                        new File(
                                                a.getCacheDir(),
                                                "phone-config-probe-" + System.nanoTime()));
                        try {
                            a.configStore.write("old configuration fixture");
                        } catch (IOException e) {
                            throw new RuntimeException(e);
                        }
                        a.prefs = context.getSharedPreferences("config_live_probe", 0);
                        a.prefs.edit().clear().putInt("repeat_mode", 1).commit();
                        a.open(new MainActivity.Screen(() -> a.renderPage("遥控功能检查", "")), false);
                        a.importDialog();
                    });
            await(
                    () ->
                            a.phoneConfig != null
                                    && a.phoneConfig.dialog != null
                                    && a.phoneConfig.dialog.isShowing());
            check("qr_has_remote_focus", ui(() -> a.appDialog.getButton(-2).hasFocus()));
            check(
                    "qr_is_default_config_entry",
                    ui(
                            () ->
                                    a.appDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("config-qr")
                                            != null));
            final String[] link = {""};
            runOnMainSync(
                    () -> {
                        try {
                            ImageView image =
                                    a.appDialog
                                            .findViewById(android.R.id.content)
                                            .findViewWithTag("config-qr");
                            Bitmap b = ((BitmapDrawable) image.getDrawable()).getBitmap();
                            int[] pixels = new int[b.getWidth() * b.getHeight()];
                            b.getPixels(pixels, 0, b.getWidth(), 0, 0, b.getWidth(), b.getHeight());
                            link[0] =
                                    new MultiFormatReader()
                                            .decode(
                                                    new BinaryBitmap(
                                                            new HybridBinarizer(
                                                                    new RGBLuminanceSource(
                                                                            b.getWidth(),
                                                                            b.getHeight(),
                                                                            pixels))))
                                            .getText();
                        } catch (Exception e) {
                            throw new RuntimeException(e);
                        }
                    });
            check(
                    "qr_decodes_to_local_session",
                    link[0].equals(a.phoneConfig.server.address(PhoneConfigDialog.lanAddress())));
            await(() -> a.phoneConfig.dialog.getWindow().getDecorView().getWidth() > 0);
            SystemClock.sleep(250);
            Bitmap screenshot = getUiAutomation().takeScreenshot();
            if (screenshot != null) {
                try (FileOutputStream out =
                        new FileOutputStream(
                                new File(a.getExternalFilesDir(null), "phone-config-panel.png"))) {
                    screenshot.compress(Bitmap.CompressFormat.PNG, 100, out);
                } finally {
                    screenshot.recycle();
                }
            }
            HttpURLConnection c = (HttpURLConnection) new URL(link[0]).openConnection();
            c.setConnectTimeout(3000);
            c.setReadTimeout(3000);
            check("lan_phone_page_served", c.getResponseCode() == 200);
            c.disconnect();
            runOnMainSync(() -> a.appDialog.dismiss());
            check("dismiss_stops_config_receiver", ui(() -> a.phoneConfig == null));
            boolean stopped = false;
            try {
                HttpURLConnection old = (HttpURLConnection) new URL(link[0]).openConnection();
                old.setConnectTimeout(1000);
                old.getResponseCode();
                old.disconnect();
            } catch (IOException expected) {
                stopped = true;
            }
            check("old_qr_stops_working_after_close", stopped);
            runOnMainSync(() -> a.addressImportDialog());
            check(
                    "manual_keyboard_still_available",
                    ui(
                            () ->
                                    a.appDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("address-input")
                                            != null));
            runOnMainSync(() -> a.appDialog.dismiss());
            runOnMainSync(() -> a.importDialog());
            final String[] submit = {""};
            runOnMainSync(
                    () ->
                            submit[0] =
                                    ((TextView)
                                                    a.appDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag(
                                                                    "config-phone-address"))
                                            .getText()
                                            .toString());
            if ("true".equals(args.getString("browser"))) {
                try (FileOutputStream output =
                        new FileOutputStream(
                                new File(
                                        a.getExternalFilesDir(null),
                                        "phone-browser-session.txt"))) {
                    output.write(submit[0].getBytes("UTF-8"));
                }
                long until = SystemClock.elapsedRealtime() + 120000;
                while (SystemClock.elapsedRealtime() < until
                        && !ui(
                                () ->
                                        a.config != null
                                                && a.config.sites.size() == 1
                                                && a.config.sites.get(0).key.equals("lan-fixture")))
                    SystemClock.sleep(100);
                check(
                        "phone_submission_imports_configuration",
                        ui(
                                () ->
                                        a.config != null
                                                && a.config.sites.size() == 1
                                                && a.config
                                                        .sites
                                                        .get(0)
                                                        .key
                                                        .equals("lan-fixture")));
            } else {
                HttpURLConnection post = (HttpURLConnection) new URL(submit[0]).openConnection();
                post.setConnectTimeout(3000);
                post.setReadTimeout(20000);
                post.setDoOutput(true);
                post.setRequestMethod("POST");
                post.setRequestProperty(
                        "Origin",
                        new URL(submit[0]).getProtocol()
                                + "://"
                                + new URL(submit[0]).getAuthority());
                post.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
                byte[] form =
                        ("address="
                                        + URLEncoder.encode(
                                                args.getString("base") + "phone-config.json",
                                                "UTF-8"))
                                .getBytes("UTF-8");
                try (OutputStream os = post.getOutputStream()) {
                    os.write(form);
                }
                check("phone_submission_imports_configuration", post.getResponseCode() == 200);
                post.disconnect();
            }
            check(
                    "configuration_saved_in_isolated_store",
                    ui(
                            () ->
                                    a.config != null
                                            && a.config.sites.size() == 1
                                            && a.config.sites.get(0).key.equals("lan-fixture")
                                            && new File(a.configStore.directory, "config.json")
                                                    .isFile()));
            check("successful_import_dismisses_qr", ui(() -> a.appDialog == null));
            check(
                    "user_configuration_file_unchanged",
                    java.util.Arrays.equals(
                            originalFile, read(new File(a.getFilesDir(), "config.json"))));
            LiveCatalog.Source source = new LiveCatalog.Source();
            source.name = "合成频道";
            LiveCatalog.Catalog catalogue = new LiveCatalog.Catalog();
            for (int g = 0; g < 2; g++) {
                LiveCatalog.Group group = new LiveCatalog.Group();
                group.name = "分组 " + g;
                for (int n = 0; n < 6; n++) {
                    LiveCatalog.Channel channel = new LiveCatalog.Channel();
                    channel.name = "频道 " + (g * 6 + n + 1);
                    LiveCatalog.Stream stream = new LiveCatalog.Stream();
                    stream.url = args.getString("base") + "h264-aac.mp4";
                    channel.streams.add(stream);
                    group.channels.add(channel);
                }
                catalogue.groups.add(group);
            }
            runOnMainSync(
                    () -> {
                        a.liveSession = new LiveSession(source, catalogue);
                        a.playLive(
                                source,
                                catalogue.groups.get(0).channels.get(5),
                                catalogue.groups.get(0).channels.get(5).streams.get(0));
                    });
            await(() -> a.prepared);
            check("live_video_prepared", ui(() -> a.isLive() && !a.controlsVisible));
            final int[] backCount = {0};
            runOnMainSync(() -> backCount[0] = a.back.size());
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            await(() -> a.prepared && a.liveSession.index == 6);
            check("down_tunes_across_groups", true);
            key(KeyEvent.KEYCODE_DPAD_UP);
            await(() -> a.prepared && a.liveSession.index == 5);
            check("up_tunes_previous", true);
            key(KeyEvent.KEYCODE_1);
            key(KeyEvent.KEYCODE_2);
            check(
                    "number_overlay_shows_12",
                    ui(
                            () ->
                                    ((TextView) a.root.findViewWithTag("live-number"))
                                            .getText()
                                            .toString()
                                            .equals("12")));
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            await(() -> a.prepared && a.liveSession.index == 11);
            check("confirm_tunes_number_12", true);
            key(KeyEvent.KEYCODE_CHANNEL_UP);
            await(() -> a.prepared && a.liveSession.index == 0);
            check("channel_up_wraps_forward", true);
            key(KeyEvent.KEYCODE_3);
            await(() -> a.prepared && a.liveSession.index == 2);
            check("numeric_timeout_tunes_channel", true);
            key(KeyEvent.KEYCODE_0);
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check("invalid_number_keeps_channel", ui(() -> a.liveSession.index == 2));
            key(KeyEvent.KEYCODE_1);
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "back_cancels_number_without_exit",
                    ui(
                            () ->
                                    a.isLive()
                                            && a.liveSession.index == 2
                                            && a.liveSession.digits.isEmpty()));
            key(KeyEvent.KEYCODE_MENU);
            key(KeyEvent.KEYCODE_DPAD_UP);
            check(
                    "toolbar_navigation_does_not_tune",
                    ui(() -> a.controlsVisible && a.liveSession.index == 2));
            check(
                    "live_toolbar_labels",
                    ui(
                            () ->
                                    a.playbackControls
                                                    .buttons
                                                    .get("next-episode")
                                                    .getText()
                                                    .toString()
                                                    .equals("下台")
                                            && a.playbackControls
                                                    .buttons
                                                    .get("episodes")
                                                    .getText()
                                                    .toString()
                                                    .equals("频道")));
            check(
                    "channel_switch_does_not_grow_back_stack",
                    ui(() -> a.back.size() == backCount[0]));
            key(KeyEvent.KEYCODE_BACK);
            check("back_hides_live_controls", ui(() -> !a.controlsVisible));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "back_returns_to_channel_context",
                    ui(() -> a.current != null && !a.current.player));
            report.put("passed", true);
        } catch (Throwable error) {
            try {
                report.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (a != null) {
                SharedPreferences old = prefs;
                Cms.Config cfg = config;
                ConfigStore originalStore = store;
                runOnMainSync(
                        () -> {
                            if (a.phoneConfig != null) a.phoneConfig.close();
                            if (a.appDialog != null) a.appDialog.dismiss();
                            a.releasePlayer();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            if (old != null) a.prefs = old;
                            a.config = cfg;
                            a.configOrigin = a.prefs.getString("origin", "");
                            a.configStore = originalStore;
                            a.liveSession = null;
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
            }
        }
        Bundle b = new Bundle();
        b.putString("result", report.toString());
        sendStatus(0, b);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
