package com.pilipala.marcomovie;

import android.content.Context;
import com.pilipala.catpaw.CatPawHost;
import java.io.*;
import java.net.URI;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** App-owned DRPY rule caller. Remote Spider engines are never replaced by filename. */
final class DrpyEngine implements SourceEngine {
    interface RuleReader {
        String read(String address, Map<String, String> headers) throws Exception;
    }

    private final CatPawHost host;
    private final String address;
    private final JSONObject description;
    private boolean active;

    static boolean eligible(Cms.Site site) {
        if (site.type != 3) return false;
        if ("csp_Drpy".equalsIgnoreCase(site.api) || "csp_LocalRule.js".equalsIgnoreCase(site.api))
            return true;
        return site.ext instanceof JSONObject
                && Cms.looksLikeDrpyRule(((JSONObject) site.ext).optString("_mm_entrySource"));
    }

    DrpyEngine(Context context, Cms.Config config, Cms.Site site) throws Exception {
        this(context, config, site, null);
    }

    DrpyEngine(Context context, Cms.Config config, Cms.Site site, String fetchedRule)
            throws Exception {
        if (!eligible(site) && !Cms.looksLikeDrpyRule(fetchedRule))
            throw new IOException("此来源不是已识别的 DRPY 规则");
        host = new CatPawHost(context);
        description =
                manifest(
                        config,
                        site,
                        fetchedRule,
                        context.getFilesDir().getCanonicalPath(),
                        (url, headers) -> readRule(context, url, headers));
        address = host.installDrpy(description);
    }

    static String readRule(Context context, String address, Map<String, String> headers)
            throws Exception {
        if (Cms.isHttp(address)) return Cms.fetch(address, headers);
        if (address.startsWith("file://")) {
            File file = new File(new URI(address)).getCanonicalFile();
            String prefix = context.getFilesDir().getCanonicalPath() + File.separator;
            if (!file.isFile() || !file.getPath().startsWith(prefix))
                throw new IOException("本地 DRPY 规则必须位于导入包目录内");
            try (InputStream input = new FileInputStream(file)) {
                return Cms.read(input, Cms.MAX_JSON);
            }
        }
        throw new IOException("DRPY 规则需要 HTTP(S) 或已导入的本地文件");
    }

    static JSONObject manifest(Cms.Config config, Cms.Site site, RuleReader reader)
            throws Exception {
        return manifest(config, site, null, reader);
    }

    static JSONObject manifest(
            Cms.Config config, Cms.Site site, String fetchedRule, RuleReader reader)
            throws Exception {
        return manifest(config, site, fetchedRule, "", reader);
    }

    static JSONObject manifest(
            Cms.Config config,
            Cms.Site site,
            String fetchedRule,
            String stateNamespace,
            RuleReader reader)
            throws Exception {
        String base = config == null || config.origin == null ? "" : config.origin;
        String api = site.api == null ? "" : site.api;
        String origin = Cms.isHttp(api) || api.startsWith("file://") ? api : base;
        Object rule = fetchedRule == null ? site.ext : fetchedRule;
        if (rule instanceof JSONObject) {
            JSONObject descriptor = (JSONObject) rule;
            if (descriptor.has("_mm_entrySource")) rule = descriptor.getString("_mm_entrySource");
            else if (descriptor.has("rule")) {
                rule = descriptor.get("rule");
                if (descriptor.has("origin"))
                    origin = Cms.resolve(base, descriptor.getString("origin"));
            }
        }
        if (rule instanceof JSONObject) rule = "var rule = " + rule.toString() + ";";
        if (!(rule instanceof String) || ((String) rule).trim().isEmpty())
            throw new IOException("DRPY 来源缺少规则内容或规则地址");
        String code = ((String) rule).trim();
        if (!Cms.looksLikeDrpyRule(code)) {
            if (code.startsWith("{")) code = "var rule = " + new JSONObject(code).toString() + ";";
            else {
                String resolved = Cms.resolve(base, code);
                if (!Cms.isHttp(resolved) && !resolved.startsWith("file://"))
                    throw new IOException("DRPY 扩展没有可读取的规则地址");
                origin = resolved;
                code = reader.read(resolved, site.headers);
            }
        }
        if (!Cms.looksLikeDrpyRule(code))
            throw new IOException("指定内容不是独立 DRPY 规则；不会替换远程 Spider 引擎");
        boolean hasOrigin = Cms.isHttp(origin) || origin.startsWith("file://");
        // Legacy pasted sources can reuse a generic key without any address. Scope those by
        // content, and always separate the activity's public/private storage namespace.
        // Only the digest enters the shared host; local directory paths are never persisted.
        String identity =
                sourceId(
                        new JSONArray()
                                .put(stateNamespace)
                                .put(base)
                                .put(site.key == null ? "" : site.key)
                                .put(origin)
                                .put(hasOrigin ? "" : sourceId(code))
                                .toString());
        Map<String, String> headers = new LinkedHashMap<>(site.headers);
        if (Cms.isHttp(origin)) {
            java.net.URL url = new java.net.URL(Cms.normalizeHttp(origin));
            if (url.getUserInfo() != null) {
                boolean hasAuthorization = false;
                for (String key : headers.keySet())
                    hasAuthorization |= key.equalsIgnoreCase("Authorization");
                if (!hasAuthorization) {
                    String userInfo =
                            java.net.URLDecoder.decode(
                                    url.getUserInfo().replace("+", "%2B"), "UTF-8");
                    headers.put(
                            "Authorization",
                            "Basic "
                                    + android.util.Base64.encodeToString(
                                            userInfo.getBytes("UTF-8"),
                                            android.util.Base64.NO_WRAP));
                }
            }
            // The helper sees only a credential-free origin; auth is scoped by its HTTP bridge.
            origin =
                    new java.net.URL(url.getProtocol(), url.getHost(), url.getPort(), url.getFile())
                            .toString();
        } else origin = "pkg://" + identity + "/main.js";
        return new JSONObject()
                .put("kind", "drpy")
                .put("version", 1)
                .put("runtime", CatPawHost.DRPY_RUNTIME)
                .put("sourceId", identity)
                .put("origin", origin)
                .put("rule", code)
                .put("headers", new JSONObject(headers))
                .put("requestTimeoutMs", 10000);
    }

    static String sourceId(String key) throws Exception {
        StringBuilder digest = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(key.getBytes("UTF-8")))
            digest.append(String.format(Locale.US, "%02x", b & 255));
        return digest.toString();
    }

    private String call(String method, Object... args) throws Exception {
        active = true;
        return host.post(
                address,
                new JSONObject()
                        .put("version", 1)
                        .put("method", method)
                        .put("args", new JSONArray(Arrays.asList(args))),
                new CatPawHost.ConnectionObserver() {
                    public void opened(java.net.HttpURLConnection connection) throws IOException {
                        RequestScope.attach(connection);
                    }

                    public void closed(java.net.HttpURLConnection connection) {
                        RequestScope.detach(connection);
                    }
                });
    }

    public String home() throws Exception {
        return call("home", true);
    }

    public String homeVideos() throws Exception {
        return call("homeVod");
    }

    public String category(String id, int page) throws Exception {
        return category(id, page, Collections.emptyMap());
    }

    public String category(String id, int page, Map<String, String> filters) throws Exception {
        return call("category", id, page, true, new JSONObject(filters));
    }

    public String detail(String id) throws Exception {
        return call("detail", id);
    }

    public String search(String word, int page) throws Exception {
        return call("search", word, false, page);
    }

    public String player(String flag, String id) throws Exception {
        return playback(call("play", flag, id, new JSONArray()), description);
    }

    static String playback(String raw, JSONObject manifest) throws Exception {
        JSONObject result = new JSONObject(raw);
        Map<String, String> defaults = new LinkedHashMap<>();
        JSONObject inherited = manifest.getJSONObject("headers");
        for (Iterator<String> keys = inherited.keys(); keys.hasNext(); ) {
            String key = keys.next();
            defaults.put(key, inherited.getString(key));
        }
        // Mixed-origin quality arrays receive no implicit credentials. Each variant can still
        // provide explicit playback headers through the existing result contract.
        String target = result.opt("url") instanceof String ? result.optString("url") : "";
        Map<String, String> headers =
                Cms.inheritedHeaders(manifest.getString("origin"), target, defaults);
        Object explicit = result.opt("header");
        if (explicit instanceof String && !((String) explicit).isEmpty())
            explicit = new JSONObject((String) explicit);
        if (explicit instanceof JSONObject) {
            Map<String, String> overrides = new LinkedHashMap<>();
            JSONObject values = (JSONObject) explicit;
            for (Iterator<String> keys = values.keys(); keys.hasNext(); ) {
                String key = keys.next();
                if (values.opt(key) instanceof String) overrides.put(key, values.getString(key));
            }
            Cms.mergeHeaders(headers, overrides);
        }
        result.put("header", new JSONObject(headers));
        return result.toString();
    }

    public boolean requiresExternalRuntime() {
        return true;
    }

    public void close() {
        if (!active) return;
        active = false;
        try {
            host.release(address);
        } catch (Exception ignored) {
        }
    }
}
