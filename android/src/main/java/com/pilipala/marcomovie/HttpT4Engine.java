package com.pilipala.marcomovie;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/** TVBox type-4 HTTP API. This is a protocol adapter, not a remote plugin host. */
public final class HttpT4Engine implements SourceEngine {
    private final Cms.Site site;
    private String extension;

    public static boolean eligible(Cms.Site site) {
        return site.type == 4 && Cms.isHttp(site.api);
    }

    public HttpT4Engine(Cms.Site site) {
        if (!eligible(site)) throw new IllegalArgumentException("Unsupported T4 source");
        this.site = site;
    }

    private synchronized String extension() throws Exception {
        if (extension != null) return extension;
        String value = site.ext == null || site.ext == JSONObject.NULL ? "" : site.ext.toString();
        if (Cms.isHttp(value))
            value = Cms.fetch(value, Cms.inheritedHeaders(site.api, value, site.headers));
        extension = value.trim();
        return extension;
    }

    private String call(String... pairs) throws Exception {
        String ext = extension();
        Map<String, String> params = new LinkedHashMap<>();
        for (int i = 0; i < pairs.length; i += 2) params.put(pairs[i], pairs[i + 1]);
        if (!ext.isEmpty()) params.put("extend", ext);
        String[] flat = new String[params.size() * 2];
        int i = 0;
        for (Map.Entry<String, String> item : params.entrySet()) {
            flat[i++] = item.getKey();
            flat[i++] = item.getValue();
        }
        String raw =
                ext.length() > 1000
                        ? Cms.fetch(site.api, site.headers, params)
                        : Cms.fetch(Cms.query(site.api, flat), site.headers);
        // HTML/error pages must not turn into an apparently empty catalogue.
        return new JSONObject(raw).toString();
    }

    public String home() throws Exception {
        return call("filter", "true");
    }

    public String category(String id, int page) throws Exception {
        return category(id, page, Collections.emptyMap());
    }

    public String category(String id, int page, Map<String, String> filters) throws Exception {
        // Android 6 has no java.util.Base64. The shared codec is API-23 safe.
        String encoded =
                Cms.basicAuthorization(new JSONObject(filters).toString())
                        .substring(6)
                        .replace('+', '-')
                        .replace('/', '_');
        return call("ac", "detail", "t", id, "pg", Integer.toString(page), "ext", encoded);
    }

    public String detail(String id) throws Exception {
        return call("ac", "detail", "ids", id);
    }

    public String search(String keyword, int page) throws Exception {
        return call("wd", keyword, "quick", "false", "pg", Integer.toString(page));
    }

    public String player(String flag, String id) throws Exception {
        return call("play", id, "flag", flag);
    }

    public boolean requiresExternalRuntime() {
        return false;
    }
}
