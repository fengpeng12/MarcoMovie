// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.net.URI;

/** Public update metadata policy, also tested without Android. */
final class UpdatePolicy {
    static final long MAX_APK = 128L * 1024 * 1024;
    static final String FEED =
            "https://raw.githubusercontent.com/Pilipala9919/mtv/main/movie/updates/";
    static final String MIRROR = "https://marcotv.wlj9919.top/movie/";

    static String[] feeds(String channel) {
        if (!"stable".equals(channel) && !"preview".equals(channel))
            throw new IllegalArgumentException("channel");
        return new String[] {MIRROR + "updates/" + channel + ".json", FEED + channel + ".json"};
    }

    static String platform(boolean mobile) {
        return mobile ? "android-mobile" : "android-tv";
    }

    static boolean mobileEdition(String edition) {
        if ("mobile".equals(edition)) return true;
        if ("tv".equals(edition)) return false;
        throw new IllegalArgumentException("Unknown application edition");
    }

    static String[] feeds(String channel, boolean mobile) {
        String[] legacy = feeds(channel);
        String name = platform(mobile) + ("preview".equals(channel) ? "-preview" : "");
        return new String[] {
            MIRROR + "updates/" + name + ".json", FEED + name + ".json", legacy[0], legacy[1]
        };
    }

    static boolean editionUrl(String url, String version, boolean mobile) {
        if (!apkUrl(url)) return false;
        String platform = platform(mobile);
        String legacy = "MarcoMovie-" + version + (mobile ? "-mobile.apk" : "-preview.apk");
        String named = "MarcoMovie-" + version + "-" + platform + ".apk";
        for (String file : new String[] {named, legacy}) {
            if (url.equals(MIRROR + file)) return true;
            for (String tag :
                    new String[] {
                        "v" + version + "-preview",
                        "v" + version,
                        platform + "-v" + version,
                        platform + "-v" + version + "-preview"
                    }) {
                if (url.equals(
                        "https://github.com/Pilipala9919/MarcoMovie/releases/download/"
                                + tag
                                + "/"
                                + file)) return true;
            }
        }
        return false;
    }

    /** Keep the release's actual tag; never switch editions when retrying a download. */
    static String[] downloads(String version, boolean mobile, String primary, String github) {
        if (!editionUrl(primary, version, mobile))
            throw new IllegalArgumentException("APK edition");
        String file = primary.substring(primary.lastIndexOf('/') + 1);
        if (github == null || github.isEmpty()) {
            if (primary.startsWith("https://github.com/")) github = primary;
            else if (file.equals("MarcoMovie-" + version + "-" + platform(mobile) + ".apk"))
                throw new IllegalArgumentException("Missing release download URL");
            else github = downloads(version, mobile)[1];
        }
        if (!github.startsWith("https://github.com/")
                || !editionUrl(github, version, mobile)
                || !github.endsWith("/" + file)
                || (primary.startsWith("https://github.com/") && !primary.equals(github)))
            throw new IllegalArgumentException("Invalid release download URL");
        String mirror = MIRROR + file;
        return new String[] {mirror, github};
    }

    static String[] downloads(String version) {
        return downloads(version, false);
    }

    static String[] downloads(String version, boolean mobile) {
        if (version == null
                || !version.matches("[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.]+)?")
                || version.length() > 48) throw new IllegalArgumentException("version");
        String file = "MarcoMovie-" + version + (mobile ? "-mobile.apk" : "-preview.apk");
        return new String[] {
            MIRROR + file,
            "https://github.com/Pilipala9919/MarcoMovie/releases/download/v"
                    + version
                    + "-preview/"
                    + file
        };
    }

    static boolean apkUrl(String value) {
        try {
            URI u = new URI(value);
            return "https".equals(u.getScheme())
                    && u.getUserInfo() == null
                    && u.getPort() == -1
                    && u.getQuery() == null
                    && u.getFragment() == null
                    && (("github.com".equals(u.getHost())
                                    && u.getPath()
                                            .startsWith(
                                                    "/Pilipala9919/MarcoMovie/releases/download/")
                                    && u.getPath().endsWith(".apk"))
                            || ("marcotv.wlj9919.top".equals(u.getHost())
                                    && u.getPath()
                                            .matches(
                                                    "/movie/MarcoMovie-[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.]+)*\\.apk")))
                    && !u.getPath().contains("..")
                    && u.getRawPath().equals(u.getPath());
        } catch (Exception e) {
            return false;
        }
    }

    static boolean transferUrl(String value) {
        try {
            URI u = new URI(value);
            String h = u.getHost();
            return "https".equals(u.getScheme())
                    && u.getUserInfo() == null
                    && u.getPort() == -1
                    && ("marcotv.wlj9919.top".equals(h)
                            || "raw.githubusercontent.com".equals(h)
                            || "github.com".equals(h)
                            || "release-assets.githubusercontent.com".equals(h)
                            || "objects.githubusercontent.com".equals(h));
        } catch (Exception e) {
            return false;
        }
    }

    static void validate(
            int code,
            String version,
            int minSdk,
            long size,
            String sha,
            String url,
            boolean preview,
            String channel) {
        validate(code, version, minSdk, size, sha, url, preview, channel, false);
    }

    static void validate(
            int code,
            String version,
            int minSdk,
            long size,
            String sha,
            String url,
            boolean preview,
            String channel,
            boolean mobile) {
        if (code <= 0
                || version == null
                || !version.matches("[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.]+)?")
                || version.length() > 48
                || minSdk < 23
                || minSdk > 100
                || size < 1
                || size > MAX_APK
                || sha == null
                || !sha.matches("[a-f0-9]{64}")
                || !apkUrl(url)
                || !editionUrl(url, version, mobile)
                || (!"stable".equals(channel) && !"preview".equals(channel))
                || ("stable".equals(channel) && preview))
            throw new IllegalArgumentException("Invalid update metadata");
    }

    static boolean newer(int offered, int installed) {
        return offered > installed;
    }

    static long resumeOffset(long requested, int status, String range, long size)
            throws java.io.IOException {
        if (requested < 0 || requested >= size) throw new java.io.IOException("invalid offset");
        if (status == 200) return 0;
        if (status == 404) throw new java.io.IOException("http 404");
        if (status != 206 || requested == 0 || range == null)
            throw new java.io.IOException("invalid range response");
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matcher(range);
        try {
            if (!m.matches()
                    || Long.parseLong(m.group(1)) != requested
                    || Long.parseLong(m.group(2)) != size - 1
                    || Long.parseLong(m.group(3)) != size)
                throw new java.io.IOException("range mismatch");
        } catch (NumberFormatException e) {
            throw new java.io.IOException("range number", e);
        }
        return requested;
    }
}
