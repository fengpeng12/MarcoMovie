package com.pilipala.marcomovie;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.SystemClock;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONObject;

/** Real Android package parser and production updater; isolated assets, never installs candidates. */
public final class UpdateIsolationProbe extends Instrumentation {
    final JSONObject report = new JSONObject();
    final List<UpdateManager> managers = new ArrayList<>();
    int checks;
    String expectedEdition;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        expectedEdition = args.getString("edition");
        start();
    }

    void check(String name, boolean value) throws Exception {
        report.put(name, value);
        if (!value) throw new AssertionError(name);
        checks++;
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

    File fixture(String name) throws Exception {
        File file = new File(getTargetContext().getCacheDir(), "update-isolation-" + name + ".apk");
        try (InputStream in = getContext().getAssets().open(name + ".apk");
                FileOutputStream out = new FileOutputStream(file)) {
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) != -1; ) out.write(buffer, 0, n);
        }
        return file;
    }

    JSONObject feed(File file, boolean mobile) throws Exception {
        Context c = getTargetContext();
        String[] parts = UpdateManager.installedVersion(c).split("\\.");
        String version = parts[0] + "." + parts[1] + "." + (Integer.parseInt(parts[2]) + 1);
        String platform = UpdatePolicy.platform(mobile);
        String name = "MarcoMovie-" + version + "-" + platform + ".apk";
        return new JSONObject()
                .put("schema", 1)
                .put("platform", platform)
                .put("versionName", version)
                .put("versionCode", UpdateManager.installedCode(c) + 1)
                .put("minSdk", 23)
                .put("size", file.length())
                .put("sha256", UpdateManager.sha(file))
                .put("url", UpdatePolicy.MIRROR + name)
                .put(
                        "githubUrl",
                        "https://github.com/Pilipala9919/MarcoMovie/releases/download/"
                                + platform
                                + "-v"
                                + version
                                + "/"
                                + name)
                .put("prerelease", false)
                .put("notes", "Isolated update check; never install");
    }

    UpdateManager manager(String id, JSONObject cached, UpdateManager.Connector connector)
            throws Exception {
        Context c = getTargetContext();
        SharedPreferences prefs = c.getSharedPreferences("update_isolation_" + id, 0);
        prefs.edit()
                .clear()
                .putString("channel", "stable")
                .putString("mode", "notify")
                .putString("metadata", cached == null ? "" : cached.toString())
                .commit();
        UpdateManager manager = new UpdateManager(c, prefs, connector);
        managers.add(manager);
        return manager;
    }

    void idle(UpdateManager manager) throws Exception {
        long end = SystemClock.elapsedRealtime() + 10000;
        while (manager.busy && SystemClock.elapsedRealtime() < end) SystemClock.sleep(10);
        check("completed_" + managers.size(), !manager.busy);
    }

    static HttpURLConnection response(String address, JSONObject data) throws Exception {
        return response(address, data.toString().getBytes("UTF-8"));
    }

    static HttpURLConnection response(String address, final byte[] body) throws Exception {
        return new HttpURLConnection(new URL(address)) {
            public void connect() {}

            public void disconnect() {}

            public boolean usingProxy() {
                return false;
            }

            public int getResponseCode() {
                return 200;
            }

            public int getContentLength() {
                return body.length;
            }

            public InputStream getInputStream() {
                return new ByteArrayInputStream(body);
            }
        };
    }

    @Override
    public void onStart() {
        try {
            Context c = getTargetContext();
            String actual =
                    c.getPackageManager()
                            .getApplicationInfo(c.getPackageName(), PackageManager.GET_META_DATA)
                            .metaData
                            .getString("com.pilipala.marcomovie.EDITION");
            check("installed_edition_matches", actual.equals(expectedEdition));
            boolean mobile = UpdatePolicy.mobileEdition(actual);
            File own = fixture(mobile ? "mobile" : "tv");
            File other = fixture(mobile ? "tv" : "mobile");
            JSONObject ownFeed = feed(own, mobile), otherFeed = feed(other, !mobile);
            UpdateManager.verifyApk(c, own, new UpdateManager.Release(ownFeed, "stable", mobile));
            check("same_edition_same_signer_apk_accepted", true);
            rejected(
                    "opposite_edition_apk_rejected_with_matching_hash",
                    () ->
                            UpdateManager.verifyApk(
                                    c,
                                    other,
                                    new UpdateManager.Release(
                                            feed(other, mobile), "stable", mobile)));
            for (String name : new String[] {"missing", "unknown", "wrong-signer"}) {
                File bad = fixture(name.equals("wrong-signer") ? name + "-" + actual : name);
                rejected(
                        name + "_apk_rejected",
                        () ->
                                UpdateManager.verifyApk(
                                        c,
                                        bad,
                                        new UpdateManager.Release(
                                                feed(bad, mobile), "stable", mobile)));
            }
            rejected(
                    "opposite_feed_rejected",
                    () -> new UpdateManager.Release(otherFeed, "stable", mobile));
            UpdateManager cached =
                    manager(
                            "cached",
                            otherFeed,
                            (url, offset) -> {
                                throw new AssertionError("Unexpected network");
                            });
            check("opposite_cached_offer_discarded", cached.available == null);
            List<String> requests = new ArrayList<>();
            UpdateManager fallback =
                    manager(
                            "fallback",
                            null,
                            (url, offset) -> {
                                requests.add(url);
                                return response(url, requests.size() == 1 ? otherFeed : ownFeed);
                            });
            fallback.check(true);
            idle(fallback);
            check(
                    "wrong_mirror_falls_back_to_own_feed",
                    fallback.available != null
                            && fallback.available.url.equals(ownFeed.getString("url")));
            String[] urls = UpdatePolicy.feeds("stable", mobile);
            check(
                    "edition_feed_order",
                    requests.size() == 2
                            && requests.get(0).equals(urls[0])
                            && requests.get(1).equals(urls[1]));
            check(
                    "actual_release_tag_retained",
                    fallback.available.downloads[1].equals(ownFeed.getString("githubUrl")));
            UpdateManager foreign =
                    manager("foreign", null, (url, offset) -> response(url, otherFeed));
            foreign.check(true);
            idle(foreign);
            check(
                    "all_foreign_feeds_never_offer_install",
                    foreign.available == null && !foreign.ready());
            byte[] payload;
            try (InputStream in = new java.io.FileInputStream(own);
                    java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192];
                for (int n; (n = in.read(buffer)) != -1; ) out.write(buffer, 0, n);
                payload = out.toByteArray();
            }
            final byte[] apkBytes = payload;
            List<String> downloads = new ArrayList<>();
            UpdateManager downloader =
                    manager(
                            "download",
                            ownFeed,
                            (url, offset) -> {
                                downloads.add(url);
                                if (url.startsWith(UpdatePolicy.MIRROR))
                                    throw new java.io.IOException("Owned mirror failure fixture");
                                return response(url, apkBytes);
                            });
            downloader.download();
            idle(downloader);
            check("downloaded_own_apk_ready", downloader.ready());
            check(
                    "download_retry_stays_on_own_release",
                    downloads.size() == 3
                            && downloads.get(0).equals(ownFeed.getString("url"))
                            && downloads.get(1).equals(ownFeed.getString("url"))
                            && downloads.get(2).equals(ownFeed.getString("githubUrl")));
            check(
                    "downloaded_apk_exact_hash",
                    UpdateManager.sha(downloader.apk()).equals(ownFeed.getString("sha256")));
            report.put("edition", actual).put("checks", checks).put("passed", true);
        } catch (Throwable error) {
            try {
                report.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            for (UpdateManager manager : managers) manager.worker.shutdownNow();
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(android.app.Activity.RESULT_OK, new Bundle());
    }
}
