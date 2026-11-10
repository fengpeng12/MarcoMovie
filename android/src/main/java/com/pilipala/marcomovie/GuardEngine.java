package com.pilipala.marcomovie;

import android.content.Context;
import com.pilipala.catpaw.CatPawHost;
import com.pilipala.catpaw.NodeRuntime;
import java.io.*;
import java.net.HttpURLConnection;
import org.json.JSONObject;

/** Reviewed data-only plugin adapters; unknown Android plugins retain their original host. */
final class GuardEngine {
    interface Fallback {
        SourceEngine open() throws Exception;
    }

    static boolean eligible(Cms.Site site) {
        String adapter = adapterFor(site);
        // The original Android plugin supports siteUrl overrides. Keep those on
        // its existing native host until the portable adapter supports them too.
        return adapter != null && !hasUnsupportedOriginOverride(adapter, site);
    }

    static boolean hasUnsupportedOriginOverride(String adapter, Cms.Site site) {
        return ("auete-v1".equals(adapter) || "bttwoo-v1".equals(adapter))
                && hasSiteUrlOverride(site);
    }

    static boolean hasSiteUrlOverride(Cms.Site site) {
        Object value = site.ext;
        if (value instanceof String) {
            try {
                value = new JSONObject((String) value);
            } catch (Exception ignored) {
                return false;
            }
        }
        if (!(value instanceof JSONObject)) return false;
        Object address = ((JSONObject) value).opt("siteUrl");
        return address != null
                && address != JSONObject.NULL
                && !address.toString().trim().isEmpty();
    }

    static String adapterFor(Cms.Site site) {
        if (site.type != 3) return null;
        if ("csp_Dm84Guard".equalsIgnoreCase(site.api) || "csp_Dm84".equalsIgnoreCase(site.api))
            return "dm84-v1";
        if ("csp_AueteGuard".equalsIgnoreCase(site.api) || "csp_Auete".equalsIgnoreCase(site.api))
            return "auete-v1";
        if ("csp_BttwooGuard".equalsIgnoreCase(site.api) || "csp_Bttwoo".equalsIgnoreCase(site.api))
            return "bttwoo-v1";
        if ("csp_T4Guard".equalsIgnoreCase(site.api) || "csp_T4".equalsIgnoreCase(site.api))
            return "t4-v1";
        return null;
    }

    static SourceEngine open(Context context, Cms.Config config, Cms.Site site, Fallback fallback)
            throws Exception {
        String adapter = adapterFor(site);
        if (adapter == null) throw new IOException("此插件没有已审阅的移植适配器");
        if (hasUnsupportedOriginOverride(adapter, site))
            throw new IOException("此插件自定义 siteUrl 请使用原 Android 插件宿主");
        String declaration =
                site.jar != null && !site.jar.trim().isEmpty() ? site.jar : config.spider;
        // All acquisition, declared digest and ZIP checks occur before any permissible fallback.
        File artifact = CspEngine.obtain(context, declaration);
        byte[] data;
        try (InputStream input = new FileInputStream(artifact);
                ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            for (int count; (count = input.read(buffer)) != -1; ) {
                if (output.size() + count > 16 * 1024 * 1024)
                    throw new IOException("移植插件包超过 16 MB 限制");
                output.write(buffer, 0, count);
            }
            data = output.toByteArray();
        }
        JSONObject result;
        Thread caller = Thread.currentThread();
        Runnable cancelBootstrap = caller::interrupt;
        RequestScope.onCancel(cancelBootstrap);
        try {
            result =
                    new CatPawHost(context)
                            .bootstrapGuard(
                                    data,
                                    adapter,
                                    "t4-v1".equals(adapter) && site.ext != null
                                            ? site.ext.toString()
                                            : null,
                                    new CatPawHost.ConnectionObserver() {
                                        public void opened(HttpURLConnection connection)
                                                throws IOException {
                                            RequestScope.attach(connection);
                                        }

                                        public void closed(HttpURLConnection connection) {
                                            RequestScope.detach(connection);
                                        }
                                    });
        } catch (CatPawHost.UnsupportedGuardArtifactException
                | NodeRuntime.RuntimeUnavailableException unavailable) {
            if (caller.isInterrupted()) throw new InterruptedIOException("插件解析已取消");
            return fallback.open();
        } finally {
            RequestScope.offCancel(cancelBootstrap);
        }
        return new DrpyEngine(context, config, portableSite(config, site, result));
    }

    static Cms.Site portableSite(Cms.Config config, Cms.Site source, JSONObject result)
            throws Exception {
        String rule = result.getString("rule");
        if (!Cms.looksLikeDrpyRule(rule)) throw new IOException("插件移植服务未返回独立 DRPY 规则");
        Cms.Site site = new Cms.Site();
        String adapter = adapterFor(source);
        if (adapter == null) throw new IOException("此插件没有已审阅的移植适配器");
        if (hasUnsupportedOriginOverride(adapter, source))
            throw new IOException("此插件自定义 siteUrl 请使用原 Android 插件宿主");
        // This key is consumed only by the internal DRPY state identity; the
        // external source object and its playback/history ownership stay intact.
        site.key =
                "dm84-v1".equals(adapter)
                        ? source.key
                        : new org.json.JSONArray()
                                .put("guard-adapter")
                                .put(adapter)
                                .put(source.key)
                                .toString();
        site.name = source.name;
        site.api = "csp_Drpy";
        site.type = 3;
        site.playUrl = source.playUrl;
        site.searchable = source.searchable;
        site.headers.putAll(
                Cms.inheritedHeaders(config.origin, result.getString("origin"), source.headers));
        site.ext = new JSONObject().put("rule", rule).put("origin", result.getString("origin"));
        return site;
    }
}
