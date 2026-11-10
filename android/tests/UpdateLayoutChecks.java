package com.pilipala.marcomovie;

public final class UpdateLayoutChecks {
    static int count;

    static void check(boolean ok, String name) {
        if (!ok) throw new AssertionError(name);
        count++;
    }

    static void bad(String value) {
        check(!UpdatePolicy.apkUrl(value), "reject " + value);
    }

    public static void main(String[] args) throws Exception {
        String hash = new String(new char[64]).replace('\0', 'a');
        String[] urls = UpdatePolicy.downloads("0.4.12");
        check(
                urls[0].equals("https://marcotv.wlj9919.top/movie/MarcoMovie-0.4.12-preview.apk"),
                "mirror path");
        check(
                urls[1].equals(
                        "https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.12-preview/MarcoMovie-0.4.12-preview.apk"),
                "official path");
        String[] mobileUrls = UpdatePolicy.downloads("0.4.12", true);
        for (String url : mobileUrls) {
            check(url.endsWith("-mobile.apk"), "mobile route stays mobile");
            UpdatePolicy.validate(25, "0.4.12", 23, 1000, hash, url, true, "preview", true);
            boolean rejected = false;
            try {
                UpdatePolicy.validate(25, "0.4.12", 23, 1000, hash, url, true, "preview", false);
            } catch (Exception expected) {
                rejected = true;
            }
            check(rejected, "TV refuses mobile artifact");
        }
        boolean rejectedTv = false;
        try {
            UpdatePolicy.validate(25, "0.4.12", 23, 1000, hash, urls[0], true, "preview", true);
        } catch (Exception expected) {
            rejectedTv = true;
        }
        check(rejectedTv, "mobile refuses TV artifact");
        for (String url : urls) {
            check(UpdatePolicy.apkUrl(url), "allowed APK");
            UpdatePolicy.validate(25, "0.4.12", 23, 1000, hash, url, true, "preview");
            count++;
        }
        for (String url :
                new String[] {
                    urls[0].replace("https:", "http:"),
                    urls[0] + "?q=1",
                    urls[0] + "#fragment",
                    urls[0].replace(".top/", ".top.evil/"),
                    urls[0].replace("/movie/", "/../movie/"),
                    urls[0].replace("/movie/", "/%6dovie/"),
                    urls[1].replace("Pilipala9919", "other"),
                    urls[1].replace("github.com", "name@github.com"),
                    urls[1].replace("github.com", "github.com:443")
                }) bad(url);
        check(
                UpdatePolicy.feeds("preview")[1].equals(
                        "https://raw.githubusercontent.com/Pilipala9919/mtv/main/movie/updates/preview.json"),
                "feed fallback");
        check(
                UpdatePolicy.transferUrl(
                        "https://release-assets.githubusercontent.com/test?token=sample"),
                "asset redirect");
        check(!UpdatePolicy.transferUrl("http://github.com/x"), "no HTTP downgrade");
        check(!UpdatePolicy.transferUrl("https://127.0.0.1/file"), "no private redirect");
        for (int mode = 0; mode < 5; mode++) {
            boolean rejected = false;
            try {
                UpdatePolicy.validate(
                        mode == 0 ? 0 : 25,
                        "0.4.12",
                        23,
                        mode == 1 ? 0 : 1000,
                        mode == 2 ? "invalid" : hash,
                        mode == 3 ? UpdatePolicy.downloads("0.4.11")[0] : urls[0],
                        true,
                        mode == 4 ? "stable" : "preview");
            } catch (IllegalArgumentException expected) {
                rejected = true;
            }
            check(rejected, "metadata rejected " + mode);
        }
        check(
                UpdatePolicy.newer(25, 24)
                        && !UpdatePolicy.newer(24, 24)
                        && !UpdatePolicy.newer(23, 24),
                "no reinstall or downgrade");
        check(UpdatePolicy.resumeOffset(50, 206, "bytes 50-99/100", 100) == 50, "resume");
        check(UpdatePolicy.resumeOffset(50, 200, null, 100) == 0, "range ignored restarts");
        for (String range :
                new String[] {
                    null,
                    "bytes 0-99/100",
                    "bytes 50-98/100",
                    "bytes 50-99/101",
                    "bytes 50-999999999999999999999/100"
                }) {
            boolean rejected = false;
            try {
                UpdatePolicy.resumeOffset(50, 206, range, 100);
            } catch (java.io.IOException expected) {
                rejected = true;
            }
            check(rejected, "bad range");
        }
        for (int[] display : new int[][] {{1280, 720}, {1920, 1080}, {3840, 2160}, {7680, 4320}}) {
            int dpi = TvLayoutPolicy.densityDpi(display[0], display[1], 100);
            float logical = display[0] * 160f / dpi;
            check(Math.abs(logical - 960) < 2, "consistent logical width");
            check(
                    TvLayoutPolicy.densityDpi(display[1], display[0], 100) == dpi,
                    "landscape orientation");
            check(TvLayoutPolicy.densityDpi(display[0], display[1], 120) > dpi, "larger controls");
        }
        check(TvLayoutPolicy.densityDpi(1920, 1080, 100) == 320, "1080 canvas");
        check(TvLayoutPolicy.densityDpi(3840, 2160, 100) == 640, "4K canvas");
        check(TvLayoutPolicy.percent(300) == 100, "invalid preference reset");
        check(TvLayoutPolicy.searchColumns(614) == 4, "standard search columns");
        check(TvLayoutPolicy.searchColumns(454) == 3, "enlarged search columns");
        check(TvLayoutPolicy.homeColumns(960, 5) == 5, "standard home grid");
        check(TvLayoutPolicy.homeColumns(800, 5) == 4, "enlarged home grid");
        System.out.println("OK " + count + " update and display checks");
    }
}
