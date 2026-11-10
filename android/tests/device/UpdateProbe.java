package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Private signed fixtures are verified but never installed. All download tests use isolated cache/preferences. */
public final class UpdateProbe extends Instrumentation {
    MainActivity a;
    final JSONObject report = new JSONObject();
    final CountDownLatch launched = new CountDownLatch(1);
    UpdateManager manager;

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
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

    void check(String name, boolean value) throws Exception {
        report.put(name, value);
        if (!value) throw new AssertionError(name);
    }

    interface Work {
        void run() throws Exception;
    }

    void rejected(String name, Work work) throws Exception {
        boolean failed = false;
        try {
            work.run();
        } catch (Exception expected) {
            failed = true;
        }
        check(name, failed);
    }

    byte[] read(File f) throws Exception {
        try (InputStream in = new FileInputStream(f);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[8192];
            for (int n; (n = in.read(b)) != -1; ) out.write(b, 0, n);
            return out.toByteArray();
        }
    }

    void write(File f, byte[] b) throws Exception {
        f.getParentFile().mkdirs();
        try (OutputStream out = new FileOutputStream(f)) {
            out.write(b);
        }
    }

    JSONObject metadata(File f, int code, String version) throws Exception {
        return new JSONObject()
                .put("schema", 1)
                .put("versionCode", code)
                .put("versionName", version)
                .put("minSdk", 23)
                .put("size", f.length())
                .put("sha256", UpdateManager.sha(f))
                .put("url", UpdatePolicy.downloads(version)[0])
                .put("prerelease", true)
                .put("notes", "Private fixture; never install");
    }

    void idle() throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 15000;
        while (manager.busy && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20);
        if (manager.busy) throw new AssertionError("update timeout");
        waitForIdleSync();
    }

    static class Response extends HttpURLConnection {
        final byte[] body;
        final int code;
        final String range;

        Response(String address, byte[] body, int code, String range) throws Exception {
            super(new URL(address));
            this.body = body;
            this.code = code;
            this.range = range;
        }

        public void connect() {}

        public void disconnect() {}

        public boolean usingProxy() {
            return false;
        }

        public int getResponseCode() {
            return code;
        }

        public int getContentLength() {
            return body.length;
        }

        public String getHeaderField(String name) {
            return "Content-Range".equals(name) ? range : null;
        }

        public InputStream getInputStream() {
            return new ByteArrayInputStream(body);
        }
    }

    @Override
    public void onStart() {
        try {
            Context context = getTargetContext();
            final int nextCode = UpdateManager.installedCode(context) + 1;
            String[] parts = UpdateManager.installedVersion(context).split("\\.");
            final String nextVersion =
                    parts[0] + "." + parts[1] + "." + (Integer.parseInt(parts[2]) + 1);
            final String olderVersion =
                    parts[0] + "." + parts[1] + "." + Math.max(0, Integer.parseInt(parts[2]) - 1);
            File fixture = new File(context.getExternalFilesDir(null), "update-fixtures");
            File newer = new File(fixture, "newer.apk");
            JSONObject json = metadata(newer, nextCode, nextVersion);
            UpdateManager.Release release = new UpdateManager.Release(json, "preview");
            UpdateManager.verifyApk(context, newer, release);
            check("same_signer_newer_verified", true);
            rejected(
                    "wrong_package_rejected",
                    () -> {
                        File f = new File(fixture, "foreign.apk");
                        UpdateManager.verifyApk(
                                context,
                                f,
                                new UpdateManager.Release(
                                        metadata(f, nextCode, nextVersion), "preview"));
                    });
            rejected(
                    "wrong_signer_rejected",
                    () -> {
                        File f = new File(fixture, "wrong-signer.apk");
                        UpdateManager.verifyApk(
                                context,
                                f,
                                new UpdateManager.Release(
                                        metadata(f, nextCode, nextVersion), "preview"));
                    });
            rejected(
                    "downgrade_rejected",
                    () -> {
                        File f = new File(fixture, "older.apk");
                        UpdateManager.verifyApk(
                                context,
                                f,
                                new UpdateManager.Release(
                                        metadata(f, nextCode - 2, olderVersion), "preview"));
                    });
            JSONObject tampered =
                    new JSONObject(json.toString())
                            .put("sha256", new String(new char[64]).replace('\0', '0'));
            rejected(
                    "tampered_hash_rejected",
                    () ->
                            UpdateManager.verifyApk(
                                    context,
                                    newer,
                                    new UpdateManager.Release(tampered, "preview")));
            rejected(
                    "metadata_version_mismatch_rejected",
                    () ->
                            UpdateManager.verifyApk(
                                    context,
                                    newer,
                                    new UpdateManager.Release(
                                            new JSONObject(json.toString())
                                                    .put("versionCode", nextCode + 1),
                                            "preview")));
            final byte[] payload = read(newer), feed = json.toString().getBytes("UTF-8");
            final int[] feedCalls = {0}, apkCalls = {0};
            final long[] resumed = {-1};
            Context isolated =
                    new ContextWrapper(context) {
                        public File getCacheDir() {
                            File f = new File(super.getCacheDir(), "update-probe");
                            f.mkdirs();
                            return f;
                        }
                    };
            android.content.SharedPreferences prefs =
                    context.getSharedPreferences("update_probe", 0);
            prefs.edit().clear().commit();
            manager =
                    new UpdateManager(
                            isolated,
                            prefs,
                            (address, offset) -> {
                                if (address.endsWith(".json")) {
                                    feedCalls[0]++;
                                    if (feedCalls[0] == 1)
                                        throw new IOException("mirror fixture unavailable");
                                    return new Response(address, feed, 200, null);
                                }
                                apkCalls[0]++;
                                if (address.startsWith(UpdatePolicy.MIRROR))
                                    throw new IOException("mirror fixture unavailable");
                                resumed[0] = offset;
                                return new Response(
                                        address,
                                        Arrays.copyOfRange(payload, (int) offset, payload.length),
                                        offset > 0 ? 206 : 200,
                                        offset > 0
                                                ? "bytes "
                                                        + offset
                                                        + "-"
                                                        + (payload.length - 1)
                                                        + "/"
                                                        + payload.length
                                                : null);
                            });
            manager.check(true);
            idle();
            check(
                    "feed_fallback_finds_update",
                    feedCalls[0] == 2
                            && manager.available != null
                            && manager.available.code == nextCode);
            write(new File(manager.folder(), "release.part"), Arrays.copyOf(payload, 100));
            prefs.edit().putString("partial_sha", release.sha).commit();
            manager.download();
            idle();
            check("apk_fallback_and_range_resume", apkCalls[0] >= 3 && resumed[0] == 100);
            check(
                    "download_verified_and_ready",
                    manager.ready() && UpdateManager.sha(manager.apk()).equals(release.sha));
            check("download_does_not_request_install", !prefs.contains("pending_code"));
            check("one_update_notice", manager.consumeNotice() && !manager.consumeNotice());
            manager.setMode("off");
            int calls = feedCalls[0];
            manager.automatic();
            check("manual_mode_blocks_automatic", feedCalls[0] == calls && !manager.busy);
            manager.worker.shutdownNow();
            manager = null;
            prefs.edit().clear().commit();
            manager =
                    new UpdateManager(
                            isolated,
                            prefs,
                            (address, offset) -> new Response(address, new byte[32769], 200, null));
            manager.check(true);
            idle();
            check("oversized_feed_rejected", manager.available == null && !manager.ready());
            manager.worker.shutdownNow();
            manager = null;
            UpdateApkProvider provider = new UpdateApkProvider();
            android.content.pm.ProviderInfo info = new android.content.pm.ProviderInfo();
            info.authority = UpdateApkProvider.AUTHORITY;
            provider.attachInfo(context, info);
            check(
                    "provider_mime",
                    provider.getType(UpdateApkProvider.URI)
                            .equals("application/vnd.android.package-archive"));
            rejected("provider_rejects_write", () -> provider.openFile(UpdateApkProvider.URI, "w"));
            rejected(
                    "provider_rejects_other_path",
                    () ->
                            provider.getType(
                                    android.net.Uri.parse(
                                            "content://"
                                                    + UpdateApkProvider.AUTHORITY
                                                    + "/../config.json")));
            Intent install = UpdateScreen.installIntent();
            check(
                    "installer_read_grant",
                    (install.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0
                            && install.getClipData() != null);
            check(
                    "installer_available",
                    install.resolveActivity(context.getPackageManager()) != null);
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.open(new MainActivity.Screen(() -> new UpdateScreen(a).show()), false);
                    });
            waitForIdleSync();
            SystemClock.sleep(400);
            final boolean[] visible = {false};
            runOnMainSync(
                    () -> {
                        View button = a.root.findViewWithTag("update-check");
                        visible[0] =
                                button != null
                                        && button.isShown()
                                        && button.isFocusable()
                                        && a.root.findViewWithTag("update-status") != null;
                    });
            check("custom_update_screen_controls", visible[0]);
            android.util.DisplayMetrics screen = new android.util.DisplayMetrics();
            a.getWindowManager().getDefaultDisplay().getRealMetrics(screen);
            check(
                    "activity_uses_adaptive_density",
                    a.getResources().getDisplayMetrics().densityDpi
                            == TvLayoutPolicy.densityDpi(
                                    screen.widthPixels,
                                    screen.heightPixels,
                                    a.prefs.getInt("ui_scale_percent", 100)));
            runOnMainSync(() -> a.updateScreen.mode());
            waitForIdleSync();
            check("update_mode_uses_app_dialog", a.appDialog != null && a.appDialog.isShowing());
            HttpURLConnection live = UpdateManager.open(UpdatePolicy.feeds("preview")[0]);
            JSONObject liveJson;
            try (InputStream in = live.getInputStream();
                    ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] bytes = new byte[4096];
                for (int n; (n = in.read(bytes)) != -1; ) out.write(bytes, 0, n);
                liveJson = new JSONObject(new String(out.toByteArray(), "UTF-8"));
            } finally {
                live.disconnect();
            }
            UpdateManager.Release published = new UpdateManager.Release(liveJson, "preview");
            check("live_mirror_feed_readable_on_tv", published.code >= 24);
            HttpURLConnection download = UpdateManager.open(published.url);
            File networkFile = new File(isolated.getCacheDir(), "network-release.apk");
            try (InputStream in = download.getInputStream();
                    OutputStream out = new FileOutputStream(networkFile)) {
                byte[] bytes = new byte[32768];
                for (int n; (n = in.read(bytes)) != -1; ) out.write(bytes, 0, n);
            } finally {
                download.disconnect();
            }
            check(
                    "live_mirror_apk_matches_published_digest",
                    networkFile.length() == published.size
                            && UpdateManager.sha(networkFile).equals(published.sha));
            networkFile.delete();
            report.put("passed", true);
        } catch (Throwable e) {
            try {
                report.put("passed", false).put("error", e.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (manager != null) manager.worker.shutdownNow();
            if (a != null)
                runOnMainSync(
                        () -> {
                            if (a.appDialog != null) a.appDialog.dismiss();
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
