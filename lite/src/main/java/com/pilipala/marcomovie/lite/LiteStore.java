// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Lightweight API 14 persistence for TV Lite watch history, favorites, and search history.
 */
public final class LiteStore {
    private static final String PREF_NAME = "marco_lite_store";
    private static final String KEY_HISTORY = "watch_history_v1";
    private static final String KEY_FAVORITES = "favorites_v1";
    private static final String KEY_SEARCH_HISTORY = "search_history_v1";
    public static final int MAX_HISTORY = 40;
    public static final int MAX_FAVORITES = 100;
    public static final int MAX_SEARCH_HISTORY = 16;

    public static final class HistoryEntry {
        public String siteKey = "";
        public String siteName = "";
        public String siteApi = "";
        public String vodId = "";
        public String vodName = "";
        public String vodPic = "";
        public String lineName = "";
        public int lineIndex;
        public String epName = "";
        public String epUrl = "";
        public int epIndex;
        public int positionMs;
        public int durationMs;
        public long updatedAt;

        public JSONObject toJson() throws Exception {
            return new JSONObject()
                    .put("siteKey", siteKey)
                    .put("siteName", siteName)
                    .put("siteApi", siteApi)
                    .put("vodId", vodId)
                    .put("vodName", vodName)
                    .put("vodPic", vodPic)
                    .put("lineName", lineName)
                    .put("lineIndex", lineIndex)
                    .put("epName", epName)
                    .put("epUrl", epUrl)
                    .put("epIndex", epIndex)
                    .put("positionMs", positionMs)
                    .put("durationMs", durationMs)
                    .put("updatedAt", updatedAt);
        }

        public static HistoryEntry fromJson(JSONObject o) {
            if (o == null) return null;
            HistoryEntry e = new HistoryEntry();
            e.siteKey = o.optString("siteKey", "");
            e.siteName = o.optString("siteName", "");
            e.siteApi = o.optString("siteApi", "");
            e.vodId = o.optString("vodId", "");
            e.vodName = o.optString("vodName", "");
            e.vodPic = o.optString("vodPic", "");
            e.lineName = o.optString("lineName", "");
            e.lineIndex = o.optInt("lineIndex", 0);
            e.epName = o.optString("epName", "");
            e.epUrl = o.optString("epUrl", "");
            e.epIndex = o.optInt("epIndex", 0);
            e.positionMs = o.optInt("positionMs", 0);
            e.durationMs = o.optInt("durationMs", 0);
            e.updatedAt = o.optLong("updatedAt", 0L);
            return e;
        }
    }

    public static final class FavoriteEntry {
        public String siteKey = "";
        public String siteName = "";
        public String siteApi = "";
        public String vodId = "";
        public String vodName = "";
        public String vodPic = "";
        public String vodRemarks = "";
        public long addedAt;

        public JSONObject toJson() throws Exception {
            return new JSONObject()
                    .put("siteKey", siteKey)
                    .put("siteName", siteName)
                    .put("siteApi", siteApi)
                    .put("vodId", vodId)
                    .put("vodName", vodName)
                    .put("vodPic", vodPic)
                    .put("vodRemarks", vodRemarks)
                    .put("addedAt", addedAt);
        }

        public static FavoriteEntry fromJson(JSONObject o) {
            if (o == null) return null;
            FavoriteEntry e = new FavoriteEntry();
            e.siteKey = o.optString("siteKey", "");
            e.siteName = o.optString("siteName", "");
            e.siteApi = o.optString("siteApi", "");
            e.vodId = o.optString("vodId", "");
            e.vodName = o.optString("vodName", "");
            e.vodPic = o.optString("vodPic", "");
            e.vodRemarks = o.optString("vodRemarks", "");
            e.addedAt = o.optLong("addedAt", 0L);
            return e;
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
    }

    public static List<HistoryEntry> getHistory(Context context) {
        return parseHistoryJson(prefs(context).getString(KEY_HISTORY, "[]"));
    }

    public static List<HistoryEntry> parseHistoryJson(String raw) {
        List<HistoryEntry> out = new ArrayList<HistoryEntry>();
        if (raw == null || raw.length() == 0) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length() && out.size() < MAX_HISTORY; i++) {
                HistoryEntry e = HistoryEntry.fromJson(arr.optJSONObject(i));
                if (e != null && e.vodId.length() > 0 && e.vodName.length() > 0) {
                    out.add(e);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static String recordHistoryJson(String existingRaw, HistoryEntry entry) {
        if (entry == null || entry.vodId == null || entry.vodId.length() == 0) {
            return existingRaw == null ? "[]" : existingRaw;
        }
        List<HistoryEntry> current = parseHistoryJson(existingRaw);
        JSONArray next = new JSONArray();
        try {
            if (entry.updatedAt <= 0L) entry.updatedAt = System.currentTimeMillis();
            next.put(entry.toJson());
            for (int i = 0; i < current.size() && next.length() < MAX_HISTORY; i++) {
                HistoryEntry old = current.get(i);
                if (sameVideo(old.siteKey, old.vodId, entry.siteKey, entry.vodId)) continue;
                next.put(old.toJson());
            }
        } catch (Exception ignored) {
        }
        return next.toString();
    }

    public static void saveHistory(Context context, HistoryEntry entry) {
        if (context == null || entry == null) return;
        SharedPreferences sp = prefs(context);
        String updated = recordHistoryJson(sp.getString(KEY_HISTORY, "[]"), entry);
        sp.edit().putString(KEY_HISTORY, updated).commit();
    }

    public static HistoryEntry findHistory(Context context, String siteKey, String vodId) {
        if (context == null) return null;
        List<HistoryEntry> list = getHistory(context);
        for (int i = 0; i < list.size(); i++) {
            HistoryEntry e = list.get(i);
            if (sameVideo(e.siteKey, e.vodId, siteKey, vodId)) return e;
        }
        return null;
    }

    public static void removeHistory(Context context, String siteKey, String vodId) {
        List<HistoryEntry> current = getHistory(context);
        JSONArray next = new JSONArray();
        try {
            for (int i = 0; i < current.size(); i++) {
                HistoryEntry old = current.get(i);
                if (!sameVideo(old.siteKey, old.vodId, siteKey, vodId)) {
                    next.put(old.toJson());
                }
            }
        } catch (Exception ignored) {
        }
        prefs(context).edit().putString(KEY_HISTORY, next.toString()).commit();
    }

    public static void clearHistory(Context context) {
        prefs(context).edit().putString(KEY_HISTORY, "[]").commit();
    }

    public static List<FavoriteEntry> getFavorites(Context context) {
        return parseFavoritesJson(prefs(context).getString(KEY_FAVORITES, "[]"));
    }

    public static List<FavoriteEntry> parseFavoritesJson(String raw) {
        List<FavoriteEntry> out = new ArrayList<FavoriteEntry>();
        if (raw == null || raw.length() == 0) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length() && out.size() < MAX_FAVORITES; i++) {
                FavoriteEntry e = FavoriteEntry.fromJson(arr.optJSONObject(i));
                if (e != null && e.vodId.length() > 0 && e.vodName.length() > 0) {
                    out.add(e);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static boolean isFavorite(Context context, String siteKey, String vodId) {
        return containsFavorite(prefs(context).getString(KEY_FAVORITES, "[]"), siteKey, vodId);
    }

    public static boolean containsFavorite(String raw, String siteKey, String vodId) {
        List<FavoriteEntry> list = parseFavoritesJson(raw);
        for (int i = 0; i < list.size(); i++) {
            FavoriteEntry e = list.get(i);
            if (sameVideo(e.siteKey, e.vodId, siteKey, vodId)) return true;
        }
        return false;
    }

    public static String toggleFavoriteJson(String existingRaw, FavoriteEntry entry) {
        List<FavoriteEntry> list = parseFavoritesJson(existingRaw);
        boolean removed = false;
        JSONArray next = new JSONArray();
        try {
            for (int i = 0; i < list.size(); i++) {
                FavoriteEntry old = list.get(i);
                if (sameVideo(old.siteKey, old.vodId, entry.siteKey, entry.vodId)) {
                    removed = true;
                }
            }
            if (!removed) {
                if (entry.addedAt <= 0L) entry.addedAt = System.currentTimeMillis();
                next.put(entry.toJson());
            }
            for (int i = 0; i < list.size() && next.length() < MAX_FAVORITES; i++) {
                FavoriteEntry old = list.get(i);
                if (!sameVideo(old.siteKey, old.vodId, entry.siteKey, entry.vodId)) {
                    next.put(old.toJson());
                }
            }
        } catch (Exception ignored) {
        }
        return next.toString();
    }

    public static boolean toggleFavorite(Context context, FavoriteEntry entry) {
        SharedPreferences sp = prefs(context);
        String raw = sp.getString(KEY_FAVORITES, "[]");
        String updated = toggleFavoriteJson(raw, entry);
        sp.edit().putString(KEY_FAVORITES, updated).commit();
        return containsFavorite(updated, entry.siteKey, entry.vodId);
    }

    public static void clearFavorites(Context context) {
        prefs(context).edit().putString(KEY_FAVORITES, "[]").commit();
    }

    public static List<String> getSearchHistory(Context context) {
        List<String> out = new ArrayList<String>();
        try {
            JSONArray arr = new JSONArray(prefs(context).getString(KEY_SEARCH_HISTORY, "[]"));
            for (int i = 0; i < arr.length() && out.size() < MAX_SEARCH_HISTORY; i++) {
                String kw = arr.optString(i, "").trim();
                if (kw.length() > 0 && !out.contains(kw)) out.add(kw);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static void addSearchKeyword(Context context, String keyword) {
        if (context == null || keyword == null) return;
        String kw = keyword.trim();
        if (kw.length() == 0) return;
        List<String> existing = getSearchHistory(context);
        JSONArray next = new JSONArray();
        next.put(kw);
        for (int i = 0; i < existing.size() && next.length() < MAX_SEARCH_HISTORY; i++) {
            String item = existing.get(i);
            if (!kw.equalsIgnoreCase(item)) next.put(item);
        }
        prefs(context).edit().putString(KEY_SEARCH_HISTORY, next.toString()).commit();
    }

    public static void clearSearchHistory(Context context) {
        prefs(context).edit().putString(KEY_SEARCH_HISTORY, "[]").commit();
    }

    private static boolean sameVideo(String siteA, String vodA, String siteB, String vodB) {
        String sa = siteA == null ? "" : siteA;
        String sb = siteB == null ? "" : siteB;
        String va = vodA == null ? "" : vodA;
        String vb = vodB == null ? "" : vodB;
        return sa.equals(sb) && va.equals(vb) && va.length() > 0;
    }
}
