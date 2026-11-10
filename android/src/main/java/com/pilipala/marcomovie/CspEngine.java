package com.pilipala.marcomovie;

import android.app.Application;
import android.content.Context;
import dalvik.system.DexClassLoader;
import com.github.catvod.crawler.Spider;
import java.io.*;
import java.net.*;
import java.lang.reflect.*;
import java.security.*;
import java.util.*;
import java.util.zip.*;
import org.json.*;

/** Experimental ordinary CSP host. Never unwraps, patches, or bypasses plugin protection. */
public final class CspEngine implements SourceEngine {
    static final Map<String, DexClassLoader> LOADERS = new HashMap<>();
    static final Set<ClassLoader> ALL_PLUGIN_LOADERS =
            Collections.synchronizedSet(new LinkedHashSet<>());
    static volatile String activeJarDeclaration = "";
    static volatile DexClassLoader activeProxyLoader;
    static volatile String pendingPluginDanmaku = "";
    static volatile long pendingPluginDanmakuAtMs = 0L;
    static volatile PluginApplication pluginAppWrapper;

    static boolean isStoragePermission(String permission) {
        if (permission == null) return false;
        return "android.permission.READ_EXTERNAL_STORAGE".equals(permission)
                || "android.permission.WRITE_EXTERNAL_STORAGE".equals(permission)
                || "android.permission.MANAGE_EXTERNAL_STORAGE".equals(permission);
    }

    static final class PluginApplication extends Application {
        final Application base;

        PluginApplication(Application base) {
            this.base = base;
            attachBaseContext(base);
        }

        @Override
        public Context getApplicationContext() {
            return this;
        }

        @Override
        public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
            base.registerActivityLifecycleCallbacks(callback);
        }

        @Override
        public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
            base.unregisterActivityLifecycleCallbacks(callback);
        }

        @Override
        public void registerComponentCallbacks(android.content.ComponentCallbacks callback) {
            base.registerComponentCallbacks(callback);
        }

        @Override
        public void unregisterComponentCallbacks(android.content.ComponentCallbacks callback) {
            base.unregisterComponentCallbacks(callback);
        }

        @Override
        public int checkSelfPermission(String permission) {
            if (isStoragePermission(permission)) {
                return android.content.pm.PackageManager.PERMISSION_GRANTED;
            }
            return base.checkSelfPermission(permission);
        }

        @Override
        public int checkPermission(String permission, int pid, int uid) {
            if (isStoragePermission(permission)) {
                return android.content.pm.PackageManager.PERMISSION_GRANTED;
            }
            return base.checkPermission(permission, pid, uid);
        }
    }

    static Application wrapPluginApplication(Application app) {
        if (app == null || app instanceof PluginApplication) return app;
        PluginApplication current = pluginAppWrapper;
        if (current != null && current.base == app) return current;
        synchronized (CspEngine.class) {
            current = pluginAppWrapper;
            if (current == null || current.base != app) {
                current = new PluginApplication(app);
                pluginAppWrapper = current;
            }
            return current;
        }
    }

    static Application unwrapApplication(Application app) {
        return app instanceof PluginApplication ? ((PluginApplication) app).base : app;
    }

    public static int proxyPort() {
        return ProxyAddress.port > 0 ? ProxyAddress.port : 9978;
    }

    public static void onPluginDanmaku(String path) {
        if (path == null || path.trim().isEmpty()) return;
        final String trimmed = path.trim();
        pendingPluginDanmaku = trimmed;
        pendingPluginDanmakuAtMs = System.currentTimeMillis();
        final MainActivity activity = MainActivity.activeActivity;
        if (activity != null && !activity.isFinishing()) {
            activity.ui.post(
                    () -> {
                        if (activity.isFinishing()) return;
                        if (activity.playbackControls != null) {
                            activity.playbackControls.applyExternalDanmaku(trimmed);
                        }
                    });
        }
    }

    public static void onPluginSubtitle(String path) {
        if (path == null || path.trim().isEmpty()) return;
    }

    static String consumeRecentPluginDanmaku(long maxAgeMs) {
        String url = pendingPluginDanmaku;
        long at = pendingPluginDanmakuAtMs;
        if (url != null
                && !url.isEmpty()
                && at > 0L
                && (System.currentTimeMillis() - at) <= maxAgeMs) {
            pendingPluginDanmaku = "";
            pendingPluginDanmakuAtMs = 0L;
            return url;
        }
        return "";
    }

    final Application app;
    final Cms.Site site;
    final Spider spider;
    final Object pluginLock;
    public final String pluginSha256;
    private volatile boolean homeWarmed = false;

    public CspEngine(Application application, Cms.Config config, Cms.Site selected)
            throws Exception {
        app = wrapPluginApplication(application);
        site = selected;
        if (!eligible(selected)) throw new IOException("此来源不是实验 CSP JAR 接口支持的 csp_ 站点");
        try {
            String primaryJar =
                    selected.jar != null && !selected.jar.trim().isEmpty()
                            ? selected.jar
                            : config.spider;
            File artifact;
            try {
                artifact = obtain(application, primaryJar);
                activeJarDeclaration = primaryJar;
            } catch (Exception firstError) {
                if (selected.jar != null
                        && !selected.jar.trim().isEmpty()
                        && config.spider != null
                        && !config.spider.trim().isEmpty()
                        && !selected.jar.equals(config.spider)) {
                    artifact = obtain(application, config.spider);
                    activeJarDeclaration = config.spider;
                } else {
                    throw firstError;
                }
            }
            pluginSha256 = digest(artifact, "SHA-256");
            DexClassLoader loader = loader(app, artifact, pluginSha256);
            activeProxyLoader = loader;
            pluginLock = new Object();
            try (InputStream resource = loader.getResourceAsStream("classes.dex")) {
                if (resource == null) throw new IOException("插件类加载器无法读取原始资源");
            }
            String className = "com.github.catvod.spider." + site.api.substring(4);
            Object candidate = loader.loadClass(className).getDeclaredConstructor().newInstance();
            if (!(candidate instanceof Spider)) throw new IOException("插件父接口与当前宿主不兼容");
            spider = (Spider) candidate;
            synchronized (pluginLock) {
                try {
                    spider.initApi(new com.github.catvod.crawler.SpiderApi());
                } catch (Throwable ignored) {
                }
                spider.init(app, site.ext == null ? "" : site.ext.toString());
            }
            collectPluginLoaders(loader, spider);
            syncPluginProxyPort(loader, ProxyAddress.port);
            syncPluginActivity(loader, MainActivity.activeActivity);
            diagnostic("loaded", className, null);
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            diagnostic("load_failed", site.api, cause);
            throw new EngineException(
                    "扩展引擎初始化失败：" + cause.getClass().getSimpleName() + "。此来源尚未验证兼容。", cause);
        }
    }

    static synchronized DexClassLoader loader(Application app, File artifact, String sha)
            throws Exception {
        app = wrapPluginApplication(app);
        DexClassLoader existing = LOADERS.get(sha);
        if (existing != null) {
            collectPluginLoaders(existing, null);
            syncPluginActivity(existing, MainActivity.activeActivity);
            return existing;
        }
        File optimized = new File(app.getCodeCacheDir(), "csp-opt");
        if (!optimized.exists() && !optimized.mkdirs()) throw new IOException("无法创建插件私有目录");
        DexClassLoader loader =
                new DexClassLoader(
                        artifact.getAbsolutePath(),
                        optimized.getAbsolutePath(),
                        null,
                        app.getClassLoader());
        ALL_PLUGIN_LOADERS.add(loader);
        prepareHostStorage(app);
        List<Object> before = lifecycleCallbacks(app);
        loader.loadClass("com.github.catvod.spider.Init")
                .getMethod("init", Context.class)
                .invoke(null, app);
        collectPluginLoaders(loader, null);
        syncPluginProxyPort(loader, ProxyAddress.port);
        replayForegroundActivity(app, before);
        syncPluginActivity(loader, MainActivity.activeActivity);
        LOADERS.put(sha, loader);
        return loader;
    }

    static Set<ClassLoader> collectPluginLoaders(ClassLoader rootLoader, Object spiderInstance) {
        LinkedHashSet<ClassLoader> found = new LinkedHashSet<>();
        if (rootLoader != null) {
            found.add(rootLoader);
            try {
                Class<?> initClass =
                        Class.forName("com.github.catvod.spider.Init", false, rootLoader);
                for (String methodName : new String[] {"loader", "classLoader", "getClassLoader"}) {
                    try {
                        Method m = initClass.getDeclaredMethod(methodName);
                        if (Modifier.isStatic(m.getModifiers())
                                && ClassLoader.class.isAssignableFrom(m.getReturnType())) {
                            m.setAccessible(true);
                            Object inner = m.invoke(null);
                            if (inner instanceof ClassLoader) found.add((ClassLoader) inner);
                        }
                    } catch (Throwable ignored) {
                    }
                }
                for (Field f : initClass.getDeclaredFields()) {
                    try {
                        if (Modifier.isStatic(f.getModifiers())
                                && ClassLoader.class.isAssignableFrom(f.getType())) {
                            f.setAccessible(true);
                            Object inner = f.get(null);
                            if (inner instanceof ClassLoader) found.add((ClassLoader) inner);
                        }
                    } catch (Throwable ignored) {
                    }
                }
                for (Class<?> dc : initClass.getDeclaredClasses()) {
                    for (Field f : dc.getDeclaredFields()) {
                        try {
                            if (Modifier.isStatic(f.getModifiers())) {
                                f.setAccessible(true);
                                Object holder = f.get(null);
                                if (holder instanceof ClassLoader) {
                                    found.add((ClassLoader) holder);
                                } else if (holder != null) {
                                    for (Field hf : holder.getClass().getDeclaredFields()) {
                                        try {
                                            hf.setAccessible(true);
                                            Object v = hf.get(holder);
                                            if (v instanceof ClassLoader) {
                                                found.add((ClassLoader) v);
                                            }
                                        } catch (Throwable ignored) {
                                        }
                                    }
                                }
                            }
                        } catch (Throwable ignored) {
                        }
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        if (spiderInstance != null) {
            ClassLoader sc = spiderInstance.getClass().getClassLoader();
            if (sc != null) found.add(sc);
            for (Class<?> c = spiderInstance.getClass();
                    c != null && c != Object.class;
                    c = c.getSuperclass()) {
                for (Field f : c.getDeclaredFields()) {
                    try {
                        f.setAccessible(true);
                        Object val = f.get(spiderInstance);
                        if (val instanceof ClassLoader) {
                            found.add((ClassLoader) val);
                        } else if (val != null) {
                            ClassLoader vc = val.getClass().getClassLoader();
                            if (vc instanceof dalvik.system.BaseDexClassLoader
                                    && vc != CspEngine.class.getClassLoader()) {
                                found.add(vc);
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                }
            }
        }
        MainActivity active = MainActivity.activeActivity;
        if (active != null) {
            List<Object> cbs = lifecycleCallbacks(active.getApplication());
            if (cbs != null) {
                for (Object cb : cbs) {
                    if (cb == null) continue;
                    ClassLoader cbCl = cb.getClass().getClassLoader();
                    if (cbCl instanceof dalvik.system.BaseDexClassLoader
                            && cbCl != CspEngine.class.getClassLoader()) {
                        found.add(cbCl);
                    }
                    for (Field f : cb.getClass().getDeclaredFields()) {
                        try {
                            f.setAccessible(true);
                            Object innerCb = f.get(cb);
                            if (innerCb != null) {
                                ClassLoader icl = innerCb.getClass().getClassLoader();
                                if (icl instanceof dalvik.system.BaseDexClassLoader
                                        && icl != CspEngine.class.getClassLoader()) {
                                    found.add(icl);
                                }
                            }
                        } catch (Throwable ignored) {
                        }
                    }
                }
            }
        }
        ALL_PLUGIN_LOADERS.addAll(found);
        return found;
    }

    static synchronized void syncAllPluginActivities(android.app.Activity activity) {
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) return;
        LinkedHashSet<ClassLoader> snapshot = new LinkedHashSet<>(LOADERS.values());
        synchronized (ALL_PLUGIN_LOADERS) {
            snapshot.addAll(ALL_PLUGIN_LOADERS);
        }
        for (ClassLoader loader : snapshot) {
            syncPluginProxyPort(loader, ProxyAddress.port);
            syncPluginActivity(loader, activity);
        }
    }

    static void syncPluginActivity(ClassLoader loader, android.app.Activity activity) {
        if (loader == null || activity == null || activity.isFinishing() || activity.isDestroyed())
            return;
        for (ClassLoader cl : collectPluginLoaders(loader, null)) {
            for (String initName :
                    new String[] {
                        "com.github.catvod.spider.Init",
                        "com.github.catvod.spider.InitOrigin",
                        "com.github.catvod.spider.AwInit"
                    }) {
                try {
                    Class<?> initClass = Class.forName(initName, false, cl);
                    syncSingleInitClass(initClass, activity);
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private static void syncSingleInitClass(Class<?> initClass, android.app.Activity activity) {
        if (initClass == null || activity == null) return;
        Object instance = null;
        try {
            Method getMethod = initClass.getDeclaredMethod("get");
            getMethod.setAccessible(true);
            instance = getMethod.invoke(null);
        } catch (Throwable ignored) {
        }
        if (instance == null) {
            for (Field f : initClass.getDeclaredFields()) {
                try {
                    if (Modifier.isStatic(f.getModifiers())
                            && initClass.isAssignableFrom(f.getType())) {
                        f.setAccessible(true);
                        instance = f.get(null);
                        if (instance != null) break;
                    }
                } catch (Throwable ignored) {
                }
            }
        }
        if (instance == null) {
            for (Class<?> inner : initClass.getDeclaredClasses()) {
                for (Field f : inner.getDeclaredFields()) {
                    try {
                        if (Modifier.isStatic(f.getModifiers())
                                && initClass.isAssignableFrom(f.getType())) {
                            f.setAccessible(true);
                            instance = f.get(null);
                            if (instance != null) break;
                        }
                    } catch (Throwable ignored) {
                    }
                }
                if (instance != null) break;
            }
        }
        bindActivityFields(initClass, null, activity);
        if (instance != null) {
            bindActivityFields(initClass, instance, activity);
        }
        for (Method m : initClass.getDeclaredMethods()) {
            try {
                Class<?>[] params = m.getParameterTypes();
                if (params.length == 1
                        && params[0].isAssignableFrom(android.app.Activity.class)
                        && m.getName().toLowerCase(Locale.ROOT).contains("activity")) {
                    m.setAccessible(true);
                    if (Modifier.isStatic(m.getModifiers())) {
                        m.invoke(null, activity);
                    } else if (instance != null) {
                        m.invoke(instance, activity);
                    }
                }
            } catch (Throwable ignored) {
            }
        }
    }

    private static void bindActivityFields(
            Class<?> clazz, Object target, android.app.Activity activity) {
        if (clazz == null || activity == null) return;
        for (Field f : clazz.getDeclaredFields()) {
            try {
                boolean isStatic = Modifier.isStatic(f.getModifiers());
                if (target == null && !isStatic) continue;
                if (target != null && isStatic) continue;
                Class<?> type = f.getType();
                if (android.app.Activity.class.isAssignableFrom(type)) {
                    f.setAccessible(true);
                    f.set(target, activity);
                } else if (Application.class.isAssignableFrom(type)) {
                    f.setAccessible(true);
                    f.set(target, wrapPluginApplication(activity.getApplication()));
                } else if (java.lang.ref.WeakReference.class.isAssignableFrom(type)) {
                    f.setAccessible(true);
                    Object current = f.get(target);
                    Object refVal =
                            current instanceof java.lang.ref.WeakReference
                                    ? ((java.lang.ref.WeakReference<?>) current).get()
                                    : null;
                    if (refVal == null
                            || refVal instanceof android.app.Activity
                            || f.getName().toLowerCase(Locale.ROOT).contains("activity")) {
                        f.set(target, new java.lang.ref.WeakReference<>(activity));
                    }
                }
            } catch (Throwable ignored) {
            }
        }
    }

    static void syncPluginProxyPort(ClassLoader loader, int port) {
        if (loader == null || port <= 0) return;
        for (ClassLoader cl : collectPluginLoaders(loader, null)) {
            try {
                Class<?> proxyClass = Class.forName("com.github.catvod.spider.Proxy", false, cl);
                try {
                    proxyClass.getMethod("set", int.class).invoke(null, port);
                    continue;
                } catch (Throwable ignored) {
                }
                for (Field f : proxyClass.getDeclaredFields()) {
                    if (Modifier.isStatic(f.getModifiers())
                            && (f.getType() == int.class || f.getType() == Integer.class)
                            && f.getName().toLowerCase(Locale.ROOT).contains("port")) {
                        f.setAccessible(true);
                        f.setInt(null, port);
                    }
                }
            } catch (Throwable ignored) {
            }
        }
    }

    /**
     * Extensions written for TVBox-style hosts expect the usual private folders and a "tv"
     * database directory to exist. Missing ones made the extension's own setup stop half way.
     */
    static void prepareHostStorage(Application app) {
        try {
            File files = app.getFilesDir(), cache = app.getCacheDir();
            if (files != null && !files.exists()) files.mkdirs();
            if (cache != null && !cache.exists()) cache.mkdirs();
            File database = app.getDatabasePath("tv");
            File folder = database.getParentFile();
            if (folder != null && !folder.exists()) folder.mkdirs();
        } catch (Throwable error) {
            AppLog.w("CspEngine", "prepare host storage failed", error);
        }
    }

    @SuppressWarnings("unchecked")
    static List<Object> lifecycleCallbacks(Application app) {
        try {
            Application raw = unwrapApplication(app);
            Field field = Application.class.getDeclaredField("mActivityLifecycleCallbacks");
            field.setAccessible(true);
            Object value = field.get(raw);
            if (value instanceof List)
                synchronized (value) {
                    return new ArrayList<>((List<Object>) value);
                }
        } catch (Throwable ignored) {
        }
        return null;
    }

    /**
     * The extension registers lifecycle callbacks when it is first loaded, which is after the
     * app screen is already open. Tell only those new callbacks about the visible screen, so
     * login dialogs have a window to attach to instead of crashing on a missing activity.
     */
    static void replayForegroundActivity(Application app, List<Object> before) {
        if (before == null) return;
        final Application rawApp = unwrapApplication(app);
        List<Object> after = lifecycleCallbacks(rawApp);
        if (after == null) return;
        final List<Application.ActivityLifecycleCallbacks> rawCallbacks = new ArrayList<>();
        for (Object callback : after)
            if (!before.contains(callback)
                    && callback instanceof Application.ActivityLifecycleCallbacks) {
                rawCallbacks.add((Application.ActivityLifecycleCallbacks) callback);
            }
        android.os.Handler mainHandler = new android.os.Handler(android.os.Looper.getMainLooper());
        if (!rawCallbacks.isEmpty()) {
            mainHandler.post(
                    () -> {
                        List<Application.ActivityLifecycleCallbacks> added = new ArrayList<>();
                        for (Application.ActivityLifecycleCallbacks rawCb : rawCallbacks) {
                            Application.ActivityLifecycleCallbacks safeCb =
                                    wrapLifecycleCallback(rawCb);
                            try {
                                rawApp.unregisterActivityLifecycleCallbacks(rawCb);
                                rawApp.registerActivityLifecycleCallbacks(safeCb);
                            } catch (Throwable ignored) {
                            }
                            added.add(safeCb);
                        }
                        MainActivity activity = MainActivity.activeActivity;
                        if (activity == null || activity.isFinishing() || activity.isDestroyed())
                            return;
                        for (Application.ActivityLifecycleCallbacks callback : added)
                            try {
                                callback.onActivityCreated(activity, null);
                                callback.onActivityStarted(activity);
                                callback.onActivityResumed(activity);
                            } catch (Throwable error) {
                                AppLog.w("CspEngine", "extension lifecycle replay failed", error);
                            }
                    });
        }
        mainHandler.postDelayed(() -> syncAllPluginActivities(MainActivity.activeActivity), 350);
    }

    private static Application.ActivityLifecycleCallbacks wrapLifecycleCallback(
            final Application.ActivityLifecycleCallbacks delegate) {
        if (delegate != null) {
            ClassLoader dcl = delegate.getClass().getClassLoader();
            if (dcl instanceof dalvik.system.BaseDexClassLoader
                    && dcl != CspEngine.class.getClassLoader()) {
                ALL_PLUGIN_LOADERS.add(dcl);
            }
        }
        return new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityCreated(android.app.Activity a, android.os.Bundle b) {
                try {
                    delegate.onActivityCreated(a, b);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityCreated failed", e);
                }
            }

            @Override
            public void onActivityStarted(android.app.Activity a) {
                try {
                    delegate.onActivityStarted(a);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityStarted failed", e);
                }
            }

            @Override
            public void onActivityResumed(android.app.Activity a) {
                try {
                    delegate.onActivityResumed(a);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityResumed failed", e);
                }
            }

            @Override
            public void onActivityPaused(android.app.Activity a) {
                if (MainActivity.activeActivity != null && MainActivity.activeActivity != a) return;
                try {
                    delegate.onActivityPaused(a);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityPaused failed", e);
                }
            }

            @Override
            public void onActivityStopped(android.app.Activity a) {
                if (MainActivity.activeActivity != null && MainActivity.activeActivity != a) return;
                try {
                    delegate.onActivityStopped(a);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityStopped failed", e);
                }
            }

            @Override
            public void onActivitySaveInstanceState(android.app.Activity a, android.os.Bundle b) {
                try {
                    delegate.onActivitySaveInstanceState(a, b);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivitySaveInstanceState failed", e);
                }
            }

            @Override
            public void onActivityDestroyed(android.app.Activity a) {
                if (MainActivity.activeActivity != null && MainActivity.activeActivity != a) return;
                try {
                    delegate.onActivityDestroyed(a);
                } catch (Throwable e) {
                    AppLog.w("CspEngine", "plugin onActivityDestroyed failed", e);
                }
            }
        };
    }

    public static boolean eligible(Cms.Site s) {
        return s.type == 3
                && s.api.startsWith("csp_")
                && s.api.substring(4).matches("[A-Za-z0-9_$.]+");
    }

    public static Object[] proxy(Application app, Cms.Config config, Map<String, String> params)
            throws Exception {
        DexClassLoader loader = activeProxyLoader;
        if (loader == null) {
            String decl =
                    activeJarDeclaration != null && !activeJarDeclaration.isEmpty()
                            ? activeJarDeclaration
                            : config.spider;
            File artifact = obtain(app, decl);
            loader = loader(app, artifact, digest(artifact, "SHA-256"));
            activeProxyLoader = loader;
        }
        syncPluginProxyPort(loader, ProxyAddress.port);
        // playerContent may call its own HTTP proxy synchronously. Holding its
        // catalogue lock here would deadlock that reentrant network request.
        try {
            return (Object[])
                    loader.loadClass("com.github.catvod.spider.Proxy")
                            .getMethod("proxy", Map.class)
                            .invoke(null, params);
        } catch (InvocationTargetException e) {
            throw new IOException("来源代理执行失败", unwrap(e));
        }
    }

    public static final class EngineException extends Exception {
        EngineException(String message, Throwable t) {
            super(message, t);
        }
    }

    private interface Call {
        String run() throws Exception;
    }

    private String call(String operation, Call c) throws Exception {
        return call(operation, c, true);
    }

    private String call(String operation, Call c, boolean cmsObject) throws Exception {
        synchronized (pluginLock) {
            try {
                syncAllPluginActivities(MainActivity.activeActivity);
                String result = c.run();
                if (result == null || result.trim().isEmpty()) throw new IOException("插件返回空结果");
                if (cmsObject) new JSONObject(result);
                diagnostic(operation + "_ok", site.api, null);
                return result;
            } catch (Throwable t) {
                Throwable error = unwrap(t);
                diagnostic(operation + "_failed", site.api, error);
                throw new EngineException(
                        "扩展来源请求失败：" + error.getClass().getSimpleName() + "。请检查来源或稍后重试。", error);
            }
        }
    }

    private void ensureConfigHomeWarmed() {
        if (homeWarmed || !SourceController.isConfigOrNetdiskSite(site)) return;
        homeWarmed = true;
        try {
            spider.homeContent(true);
        } catch (Throwable ignored) {
        }
    }

    static Spider unwrapSpiderDelegate(Spider root) {
        if (root == null) return null;
        Spider current = root;
        for (int depth = 0; depth < 4; depth++) {
            Spider next = null;
            for (Class<?> c = current.getClass();
                    c != null && c != Object.class && c != Spider.class;
                    c = c.getSuperclass()) {
                for (Field f : c.getDeclaredFields()) {
                    if (Modifier.isStatic(f.getModifiers())) continue;
                    try {
                        f.setAccessible(true);
                        Object val = f.get(current);
                        if (val instanceof Spider && val != current) {
                            next = (Spider) val;
                            break;
                        }
                    } catch (Throwable ignored) {
                    }
                }
                if (next != null) break;
            }
            if (next == null) break;
            current = next;
        }
        return current;
    }

    public String home() throws Exception {
        String res = call("home", () -> spider.homeContent(true));
        homeWarmed = true;
        return res;
    }

    public String homeVideos() throws Exception {
        return call(
                "recommendations",
                () -> {
                    String raw = spider.homeVideoContent();
                    return raw == null || raw.trim().isEmpty() ? "{\"list\":[]}" : raw;
                });
    }

    public String liveContent(String url) throws Exception {
        return call("live", () -> spider.liveContent(url), false);
    }

    public String category(String id, int page) throws Exception {
        return category(id, page, Collections.emptyMap());
    }

    public String category(String id, int page, Map<String, String> filters) throws Exception {
        HashMap<String, String> values = new HashMap<>(filters);
        return call("category", () -> spider.categoryContent(id, "" + page, true, values));
    }

    public String detail(String id) throws Exception {
        return call(
                "detail",
                () -> {
                    try {
                        return spider.detailContent(Collections.singletonList(id));
                    } catch (Throwable t) {
                        Throwable cause = unwrap(t);
                        if (SourceController.isConfigOrNetdiskSite(site)
                                && cause.getClass().getSimpleName().contains("JsonSyntax")) {
                            String act = spider.action(id);
                            if (act == null || act.trim().isEmpty()) {
                                return "{\"list\":[]}";
                            }
                            return act;
                        }
                        if (t instanceof Exception) throw (Exception) t;
                        throw new RuntimeException(t);
                    }
                });
    }

    public String search(String keyword, int page) throws Exception {
        return call(
                "search",
                () -> {
                    Throwable lastError = null;
                    String raw = null;
                    if (page <= 1) {
                        try {
                            raw = spider.searchContent(keyword, false);
                        } catch (Throwable t) {
                            lastError = unwrap(t);
                        }
                        if (raw == null || raw.trim().isEmpty()) {
                            try {
                                raw = spider.searchContent(keyword, false, "1");
                            } catch (Throwable t) {
                                if (lastError == null) lastError = unwrap(t);
                            }
                        }
                        if (raw == null || raw.trim().isEmpty()) {
                            try {
                                raw = spider.searchContent(keyword, true);
                            } catch (Throwable t) {
                                if (lastError == null) lastError = unwrap(t);
                            }
                        }
                    } else {
                        try {
                            raw = spider.searchContent(keyword, false, "" + page);
                        } catch (Throwable t) {
                            lastError = unwrap(t);
                        }
                    }
                    if (raw != null && !raw.trim().isEmpty()) {
                        return raw;
                    }
                    if (lastError != null) {
                        if (lastError instanceof Exception) throw (Exception) lastError;
                        throw new IOException(lastError);
                    }
                    return "{\"list\":[]}";
                });
    }

    public String player(String flag, String id) throws Exception {
        return call(
                "player",
                () -> {
                    Throwable lastError = null;
                    String raw = null;
                    for (int attempt = 0; attempt < 2; attempt++) {
                        try {
                            raw = spider.playerContent(flag, id, Collections.emptyList());
                            if (raw != null && !raw.trim().isEmpty()) {
                                break;
                            }
                        } catch (Throwable t) {
                            lastError = unwrap(t);
                            if (attempt == 0) {
                                try {
                                    Thread.sleep(150);
                                } catch (InterruptedException ie) {
                                    Thread.currentThread().interrupt();
                                    break;
                                }
                            }
                        }
                    }
                    if (raw != null) {
                        String trimmed = raw.trim();
                        if (!trimmed.isEmpty()) {
                            if (trimmed.startsWith("{")) {
                                return trimmed;
                            }
                            if (Cms.isHttp(trimmed)
                                    || Cms.isMedia(trimmed)
                                    || trimmed.startsWith("magnet:?")) {
                                return new JSONObject()
                                        .put("url", trimmed)
                                        .put("parse", 0)
                                        .toString();
                            }
                        }
                    }
                    String fallbackId = id == null ? "" : id.trim();
                    if (!fallbackId.isEmpty()
                            && (Cms.isMedia(fallbackId) || fallbackId.startsWith("magnet:?"))) {
                        return new JSONObject().put("url", fallbackId).put("parse", 0).toString();
                    }
                    if (lastError != null) {
                        if (lastError instanceof Exception) throw (Exception) lastError;
                        throw new IOException(lastError);
                    }
                    return new JSONObject().put("url", "").put("parse", 0).toString();
                });
    }

    public String action(String value) throws Exception {
        synchronized (pluginLock) {
            try {
                syncAllPluginActivities(MainActivity.activeActivity);
                ensureConfigHomeWarmed();
                String res = spider.action(value);
                return res == null ? "" : res;
            } catch (Throwable error) {
                throw new EngineException(
                        "来源交互失败：" + unwrap(error).getClass().getSimpleName(), unwrap(error));
            }
        }
    }

    @Override
    public boolean supportsCustomAction() {
        try {
            String apiLower =
                    site != null && site.api != null ? site.api.toLowerCase(Locale.ROOT) : "";
            if (apiLower.contains("mydrive")
                    || apiLower.contains("wexokconfig")
                    || apiLower.contains("amns")) {
                return true;
            }
            if (apiLower.contains("panconfig") || apiLower.contains("wexconfig")) {
                return false;
            }
            Spider target = unwrapSpiderDelegate(spider);
            if (target == null) return false;
            Method m = target.getClass().getMethod("action", String.class);
            Class<?> declaring = m.getDeclaringClass();
            if (declaring == Spider.class) return false;
            String declName = declaring.getName();
            if (declName.endsWith("BaseSpiderGuard")) {
                String clsName = target.getClass().getName();
                String innerName =
                        clsName.endsWith("Guard")
                                ? clsName.substring(0, clsName.length() - 5)
                                : clsName;
                for (ClassLoader cl :
                        collectPluginLoaders(target.getClass().getClassLoader(), spider)) {
                    try {
                        Class<?> innerCls = Class.forName(innerName, false, cl);
                        if (innerCls != target.getClass()) {
                            Method im = innerCls.getMethod("action", String.class);
                            Class<?> idc = im.getDeclaringClass();
                            return idc != Spider.class && !idc.getName().endsWith(".Spider");
                        }
                    } catch (Throwable ignored) {
                    }
                }
                return true;
            }
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    @Override
    public String detailAction(String id) throws Exception {
        synchronized (pluginLock) {
            try {
                syncAllPluginActivities(MainActivity.activeActivity);
                ensureConfigHomeWarmed();
                String res = spider.detailContent(Collections.singletonList(id));
                diagnostic("detail_action_ok", site.api, null);
                return res == null ? "" : res;
            } catch (Throwable error) {
                try {
                    String fallback = spider.action(id);
                    diagnostic("detail_action_fallback_ok", site.api, null);
                    return fallback == null ? "" : fallback;
                } catch (Throwable ignored) {
                }
                Throwable cause = unwrap(error);
                diagnostic("detail_action_failed", site.api, cause);
                throw new EngineException("来源交互失败：" + cause.getClass().getSimpleName(), cause);
            }
        }
    }

    public boolean requiresExternalRuntime() {
        return true;
    }

    public void close() {
        synchronized (pluginLock) {
            try {
                spider.destroy();
            } catch (Throwable e) {
                AppLog.w("CspEngine", "destroy failed: " + site.api, e);
            }
        }
    }

    static Throwable unwrap(Throwable t) {
        while (t instanceof InvocationTargetException
                && ((InvocationTargetException) t).getCause() != null)
            t = ((InvocationTargetException) t).getCause();
        return t;
    }

    static String digest(File file, String algorithm) throws Exception {
        MessageDigest d = MessageDigest.getInstance(algorithm);
        try (InputStream in = new FileInputStream(file)) {
            byte[] b = new byte[8192];
            int n;
            while ((n = in.read(b)) != -1) d.update(b, 0, n);
        }
        StringBuilder out = new StringBuilder();
        for (byte v : d.digest()) out.append(String.format(Locale.ROOT, "%02x", v & 255));
        return out.toString();
    }

    private static final java.util.concurrent.ConcurrentHashMap<String, Object> ARTIFACT_LOCKS =
            new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.concurrent.ConcurrentHashMap<String, VerifiedArtifact>
            VERIFIED_CACHE = new java.util.concurrent.ConcurrentHashMap<>();

    private static final class VerifiedArtifact {
        final String path;
        final long length;
        final long lastModified;
        final String sha256;
        final String md5;

        VerifiedArtifact(File file, String sha256, String md5) {
            this.path = file.getAbsolutePath();
            this.length = file.length();
            this.lastModified = file.lastModified();
            this.sha256 = sha256;
            this.md5 = md5;
        }

        boolean matches(File file, String expectedSha, String expectedMd5) {
            return file.exists()
                    && path.equals(file.getAbsolutePath())
                    && length == file.length()
                    && lastModified == file.lastModified()
                    && sha256.equals(expectedSha)
                    && (expectedMd5.isEmpty() || expectedMd5.equals(md5));
        }
    }

    static boolean verifyCachedArtifact(File cached, String sha, String expectedMd5)
            throws Exception {
        if (!cached.exists()) return false;
        VerifiedArtifact v = VERIFIED_CACHE.get(sha);
        if (v != null && v.matches(cached, sha, expectedMd5)) return true;
        String actualSha = digest(cached, "SHA-256");
        if (!sha.equals(actualSha)) return false;
        String actualMd5 = expectedMd5.isEmpty() ? "" : digest(cached, "MD5");
        if (!expectedMd5.isEmpty() && !expectedMd5.equals(actualMd5)) return false;
        VERIFIED_CACHE.put(sha, new VerifiedArtifact(cached, actualSha, actualMd5));
        return true;
    }

    static File obtain(Context app, String declaration) throws Exception {
        if (declaration == null || declaration.trim().isEmpty())
            throw new IOException("配置没有声明 spider 插件");
        String[] parts = declaration.split("(?i);md5;", 2);
        String address = parts[0];
        // An explicit checksum is mandatory even when empty. Do not trim it or
        // treat a malformed declaration as an unchecked cache lookup.
        if (parts.length == 2 && !parts[1].matches("[0-9a-fA-F]{32}"))
            throw new IOException("插件 MD5 声明无效");
        String expected = parts.length == 2 ? parts[1].toLowerCase(Locale.ROOT) : "";
        if (address.startsWith("file:")) {
            File localFile = new File(URI.create(address));
            String allowedPrefix = app.getFilesDir().getCanonicalPath() + File.separator;
            if (!localFile.exists() || !localFile.getCanonicalPath().startsWith(allowedPrefix)) {
                throw new IOException("本地 spider 插件不存在或不在受保护目录内");
            }
            if (!expected.isEmpty() && !expected.equals(digest(localFile, "MD5")))
                throw new IOException("插件 MD5 与配置不一致，已拒绝加载");
            try (ZipFile zip = new ZipFile(localFile)) {
                if (zip.getEntry("classes.dex") == null)
                    throw new IOException("本地插件不含 classes.dex");
            }
            return localFile;
        }
        if (!Cms.isHttp(address)) throw new IOException("spider 需要 HTTP(S) 插件地址");
        File folder = new File(app.getFilesDir(), "csp");
        if (!folder.exists() && !folder.mkdirs()) throw new IOException("插件目录不可用");
        String key = hex(declaration.getBytes("UTF-8"));
        Object lock = ARTIFACT_LOCKS.get(key);
        if (lock == null) {
            Object candidate = new Object();
            Object prev = ARTIFACT_LOCKS.putIfAbsent(key, candidate);
            lock = prev != null ? prev : candidate;
        }
        synchronized (lock) {
            File identity = new File(folder, "selection-" + key + ".txt");
            if (identity.exists()) {
                String sha;
                try (InputStream in = new FileInputStream(identity)) {
                    sha = Cms.read(in, 128).trim();
                }
                if (sha.matches("[0-9a-f]{64}")) {
                    File cached = new File(folder, sha + ".jar");
                    if (verifyCachedArtifact(cached, sha, expected)) return cached;
                }
            }
            File temp = File.createTempFile("incoming-", ".tmp", folder);
            try {
                URL next = new URL(Cms.normalizeHttp(address));
                String authorization = null;
                if (next.getUserInfo() != null) {
                    authorization =
                            Cms.basicAuthorization(
                                    URLDecoder.decode(
                                            next.getUserInfo().replace("+", "%2B"), "UTF-8"));
                    next =
                            new URL(
                                    next.getProtocol(),
                                    next.getHost(),
                                    next.getPort(),
                                    next.getFile());
                }
                boolean done = false;
                for (int redirect = 0; redirect < 5 && !done; redirect++) {
                    checkRequest();
                    HttpURLConnection c = (HttpURLConnection) next.openConnection();
                    c.setConnectTimeout(12000);
                    c.setReadTimeout(20000);
                    c.setInstanceFollowRedirects(false);
                    c.setRequestProperty("User-Agent", Cms.USER_AGENT);
                    if (authorization != null) c.setRequestProperty("Authorization", authorization);
                    RequestScope.attach(c);
                    try {
                        int code = c.getResponseCode();
                        if (code == 301
                                || code == 302
                                || code == 303
                                || code == 307
                                || code == 308) {
                            String loc = c.getHeaderField("Location");
                            if (loc == null) throw new IOException("插件重定向无地址");
                            URL target = new URL(next, loc);
                            if (!Cms.isHttp(target.toString()))
                                throw new IOException("插件重定向协议不受支持");
                            if (target.getUserInfo() != null)
                                throw new IOException("插件重定向不能注入登录凭据");
                            if (!Cms.sameOrigin(next.toString(), target.toString()))
                                authorization = null;
                            next = target;
                            continue;
                        }
                        if (code < 200 || code >= 300) throw new IOException("插件下载失败 HTTP " + code);
                        try (InputStream in = c.getInputStream();
                                OutputStream out = new FileOutputStream(temp)) {
                            byte[] b = new byte[8192];
                            int n, total = 0;
                            while ((n = in.read(b)) != -1) {
                                checkRequest();
                                total += n;
                                if (total > 20 * 1024 * 1024)
                                    throw new IOException("插件超过 20 MB 限制");
                                out.write(b, 0, n);
                            }
                        }
                        done = true;
                    } finally {
                        RequestScope.detach(c);
                        c.disconnect();
                    }
                }
                if (!done) throw new IOException("插件重定向次数过多");
                String actualMd5 = expected.isEmpty() ? "" : digest(temp, "MD5");
                if (!expected.isEmpty() && !expected.equals(actualMd5))
                    throw new IOException("插件 MD5 与配置不一致，已拒绝加载");
                try (ZipFile zip = new ZipFile(temp)) {
                    if (zip.getEntry("classes.dex") == null)
                        throw new IOException("插件不含 classes.dex");
                }
                String sha = digest(temp, "SHA-256");
                File artifact = new File(folder, sha + ".jar");
                if (artifact.exists()) {
                    if (!verifyCachedArtifact(artifact, sha, expected))
                        throw new IOException("缓存插件摘要不一致");
                } else if (!temp.renameTo(artifact)) throw new IOException("无法保存插件");
                artifact.setReadOnly();
                VERIFIED_CACHE.put(sha, new VerifiedArtifact(artifact, sha, actualMd5));
                try (OutputStream out = new FileOutputStream(identity)) {
                    out.write(sha.getBytes("UTF-8"));
                }
                return artifact;
            } finally {
                temp.delete();
            }
        }
    }

    private static void checkRequest() throws IOException {
        RequestScope scope = RequestScope.current();
        if (scope != null) scope.check();
        else if (Thread.currentThread().isInterrupted()) throw new java.io.InterruptedIOException();
    }

    static String hex(byte[] bytes) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder s = new StringBuilder();
        for (byte b : d) s.append(String.format(Locale.ROOT, "%02x", b & 255));
        return s.toString();
    }

    void diagnostic(String state, String className, Throwable error) {
        if (error != null) AppLog.w("CspEngine", state + ":" + className, error);
        try {
            JSONObject j = new JSONObject();
            j.put("state", state);
            j.put("class", className);
            j.put("error_type", error == null ? JSONObject.NULL : error.getClass().getName());
            j.put("elapsed_ms", android.os.SystemClock.elapsedRealtime());
            if (error != null) {
                JSONArray stack = new JSONArray();
                StackTraceElement[] elements = error.getStackTrace();
                for (int i = 0; i < Math.min(8, elements.length); i++)
                    stack.put(elements[i].getClassName() + "." + elements[i].getMethodName());
                j.put("frames", stack);
            }
            try (OutputStream out =
                    app.openFileOutput("csp-diagnostic.json", Context.MODE_PRIVATE)) {
                out.write(j.toString(2).getBytes("UTF-8"));
            }
        } catch (Exception ignored) {
        }
    }
}
