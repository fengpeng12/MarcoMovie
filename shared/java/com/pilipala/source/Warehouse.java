package com.pilipala.source;

import java.io.IOException;
import java.net.IDN;
import java.net.URL;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/** Bounded nested catalog traversal shared by standard Android and API 14 Lite. */
public final class Warehouse {
    public interface Reader {
        String read(String url) throws Exception;
    }

    public interface Decoder {
        JSONObject decode(String raw) throws Exception;
    }

    public interface Validator {
        void validate(String raw, String origin) throws Exception;
    }

    public static final String DEPOTS = "_marco_depots";
    public static final String ORIGIN = "_marco_origin";
    public static final String ROOT = "_marco_warehouse";

    private Warehouse() {}

    public static JSONArray depots(JSONObject root, String origin) throws Exception {
        JSONArray out = new JSONArray();
        Set<String> seen = new HashSet<String>();
        String[] fields = {"urls", "storeHouse", "depots"};
        for (String field : fields) {
            JSONArray rows = root.optJSONArray(field);
            if (rows == null) continue;
            for (int i = 0; i < Math.min(256, rows.length()); i++) {
                JSONObject row = rows.optJSONObject(i);
                if (row == null) continue;
                String raw =
                        row.optString("url", row.optString("sourceUrl", row.optString("api", "")))
                                .trim();
                if (raw.length() == 0
                        || !(raw.startsWith("http://")
                                || raw.startsWith("https://")
                                || raw.startsWith("/")
                                || raw.startsWith("./")
                                || raw.startsWith("../")
                                || raw.matches("[^\\s]+\\.[a-zA-Z0-9]{1,8}(?:[?#].*)?"))) continue;
                try {
                    URL u =
                            origin == null || origin.length() == 0
                                    ? new URL(raw)
                                    : new URL(new URL(origin), raw);
                    if (!("http".equals(u.getProtocol()) || "https".equals(u.getProtocol()))
                            || u.getUserInfo() != null
                            || u.getHost().length() == 0) continue;
                    String url =
                            new URL(
                                            u.getProtocol(),
                                            IDN.toASCII(u.getHost()),
                                            u.getPort(),
                                            u.getFile())
                                    .toString();
                    if (!seen.add(url)) continue;
                    String name =
                            row.optString(
                                    "name",
                                    row.optString("sourceName", "仓库 " + (out.length() + 1)));
                    out.put(new JSONObject().put("name", name).put("url", url));
                } catch (IllegalArgumentException ignored) {
                } catch (java.net.MalformedURLException ignored) {
                }
            }
        }
        return out;
    }

    public static boolean isCatalog(JSONObject json) {
        JSONArray sites = json.optJSONArray("sites");
        JSONArray lives = json.optJSONArray("lives");
        return (sites == null || sites.length() == 0)
                && (lives == null || lives.length() == 0)
                && !json.has("api")
                && (json.has("urls") || json.has("storeHouse") || json.has("depots"));
    }

    public static String resolve(
            String raw, String origin, Reader reader, Decoder decoder, Validator validator)
            throws Exception {
        JSONObject json = decoder.decode(raw);
        if (!isCatalog(json)) {
            validator.validate(raw, origin);
            return raw;
        }
        Walk walk = new Walk(reader, decoder, validator);
        walk.seen.add(origin);
        JSONObject leaf = walk.visit(json, origin, "", 0);
        JSONArray directories = new JSONArray();
        for (JSONObject entry : walk.entries.values()) directories.put(entry);
        return leaf.put(DEPOTS, directories).put(ROOT, origin == null ? "" : origin).toString();
    }

    /** Preserve the root and other branches when the user selects a child warehouse. */
    public static String retainDirectory(
            String selectedRaw, String selectedOrigin, String previousRaw, Decoder decoder)
            throws Exception {
        JSONObject old = decoder.decode(previousRaw), selected = decoder.decode(selectedRaw);
        Map<String, JSONObject> entries = new LinkedHashMap<String, JSONObject>();
        JSONObject[] documents = {old, selected};
        for (JSONObject document : documents) {
            JSONArray rows = document.optJSONArray(DEPOTS);
            if (rows != null)
                for (int i = 0; i < rows.length(); i++) {
                    JSONObject entry = rows.optJSONObject(i);
                    if (entry != null) entries.put(entry.optString("url"), entry);
                }
        }
        JSONArray rows = new JSONArray();
        for (JSONObject entry : entries.values()) rows.put(entry);
        return selected.put(DEPOTS, rows)
                .put(ROOT, old.optString(ROOT))
                .put(ORIGIN, selected.optString(ORIGIN, selectedOrigin))
                .toString();
    }

    private static final class Walk {
        final Reader reader;
        final Decoder decoder;
        final Validator validator;
        final Set<String> seen = new HashSet<String>();
        final Map<String, JSONObject> entries = new LinkedHashMap<String, JSONObject>();
        final long deadline = System.nanoTime() + 60000000000L;
        int requests;

        Walk(Reader r, Decoder d, Validator v) {
            reader = r;
            decoder = d;
            validator = v;
        }

        JSONObject visit(JSONObject root, String origin, String parent, int depth)
                throws Exception {
            if (depth >= 6) throw new IOException("多仓嵌套超过 6 层");
            JSONArray rows = depots(root, origin);
            for (int i = 0; i < rows.length(); i++) {
                JSONObject row = rows.getJSONObject(i);
                if (parent.length() > 0) row.put("name", parent + " / " + row.optString("name"));
                if (!entries.containsKey(row.optString("url")))
                    entries.put(row.optString("url"), row);
            }
            for (int i = 0; i < rows.length(); i++) {
                if (requests >= 32
                        || System.nanoTime() >= deadline
                        || Thread.currentThread().isInterrupted()) break;
                JSONObject row = rows.getJSONObject(i);
                String url = row.optString("url");
                if (!seen.add(url)) continue;
                requests++;
                try {
                    String raw = reader.read(url);
                    JSONObject parsed = decoder.decode(raw);
                    if (isCatalog(parsed))
                        return visit(parsed, url, row.optString("name"), depth + 1);
                    validator.validate(raw, url);
                    return parsed.put(ORIGIN, url);
                } catch (Exception ignored) {
                }
            }
            throw new IOException("多仓没有可读取的子仓库，地址失效或存在循环引用");
        }
    }
}
