// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.IOException;
import org.json.JSONObject;

/** Edition-bound metadata shared by the Android updater and offline behavior checks. */
class UpdateRelease {
    final int code, minSdk;
    final long size;
    final String version, url, sha, notes;
    final boolean preview;
    final String[] downloads;

    UpdateRelease(JSONObject data, String channel, boolean mobile) throws Exception {
        if (data.getInt("schema") != 1) throw new IOException("Unsupported feed");
        boolean dedicated = data.has("platform");
        if (dedicated && !UpdatePolicy.platform(mobile).equals(data.getString("platform")))
            throw new IOException("更新信息与安装版本不匹配");
        // Legacy feeds contain TV metadata at the root. A phone MUST have its own
        // mobile artifact; absence is not permission to use the TV package.
        JSONObject artifact = !dedicated && mobile ? data.getJSONObject("mobile") : data;
        code =
                artifact.has("versionCode")
                        ? artifact.getInt("versionCode")
                        : data.getInt("versionCode");
        version =
                artifact.has("versionName")
                        ? artifact.getString("versionName")
                        : data.getString("versionName");
        minSdk = artifact.has("minSdk") ? artifact.getInt("minSdk") : data.getInt("minSdk");
        size = artifact.getLong("size");
        url = artifact.getString("url");
        sha = artifact.getString("sha256");
        preview =
                artifact.has("prerelease")
                        ? artifact.getBoolean("prerelease")
                        : data.getBoolean("prerelease");
        notes = artifact.optString("notes", data.optString("notes", ""));
        UpdatePolicy.validate(code, version, minSdk, size, sha, url, preview, channel, mobile);
        downloads =
                UpdatePolicy.downloads(version, mobile, url, artifact.optString("githubUrl", ""));
        if (notes.length() > 8000) throw new IOException("Notes too long");
    }
}
