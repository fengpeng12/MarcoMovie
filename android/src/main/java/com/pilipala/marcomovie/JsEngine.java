package com.pilipala.marcomovie;

import android.app.Application;
import android.content.SharedPreferences;
import android.util.Base64;
import com.whl.quickjs.android.QuickJSLoader;
import com.whl.quickjs.wrapper.*;
import org.json.*;
import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;
import org.jsoup.select.Elements;
import java.io.*;
import java.net.*;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;

/** Independent QuickJS host for user-provided ES-module spiders and DRPY rules. */
public final class JsEngine implements SourceEngine {
    /** Dispatch handoff after the normal cached download, before any rule execution. */
    static final class DrpyRuleDetected extends IOException {
        final String source;

        DrpyRuleDetected(String value) {
            super("独立 DRPY 规则需要本机规则宿主");
            source = value;
        }
    }

    private static final ConcurrentHashMap<String, JsEngine> ACTIVE = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, JsEngine> CURRENT = new ConcurrentHashMap<>();
    private static final ScheduledThreadPoolExecutor REQUEST_TIMEOUTS =
            new ScheduledThreadPoolExecutor(
                    1,
                    r -> {
                        Thread t = new Thread(r, "movie-catvod-http-deadline");
                        t.setDaemon(true);
                        return t;
                    });
    private final String proxyKey = UUID.randomUUID().toString().replace("-", "");
    private final Application app;
    private final Cms.Site site;
    private final SharedPreferences storage;
    private final ExecutorService executor =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "movie-js-source");
                        t.setDaemon(true);
                        return t;
                    });
    private final Map<String, String> modules = new HashMap<>();
    private final CookieManager cookies =
            new CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER);
    private QuickJSContext context;
    private QuickJsDeadline nativeDeadline;
    private final long operationTimeoutMillis;

    private static final class OperationState {
        volatile QuickJsDeadline.Operation operation;

        void cancel() {
            QuickJsDeadline.Operation current = operation;
            if (current != null) current.cancel();
        }
    }

    private volatile OperationState activeOperation;
    private volatile boolean closed;
    private volatile long deadline;
    private boolean catApi;
    private boolean pythonSource;
    private boolean catvodModule;
    private volatile boolean initialized;
    private volatile boolean failedOperation;

    static boolean isCommonJs(String source) {
        return java.util.regex.Pattern.compile(
                        "\\b(?:module\\s*\\.\\s*exports\\b|exports\\s*(?:\\.|\\[))")
                .matcher(source)
                .find();
    }

    static boolean isEsModule(String source) {
        return java.util.regex.Pattern.compile(
                        "(?:^|[;\\n])\\s*(?:export\\s*(?:default\\b|(?:async\\s+)?function\\b|class\\b|const\\b|let\\b|var\\b|\\{|\\*)|import(?=\\s|['\"{*]))",
                        java.util.regex.Pattern.MULTILINE)
                .matcher(source)
                .find();
    }

    public static boolean eligible(Cms.Site s) {
        if (s.type == 3 && "csp_LocalPython".equals(s.api) && s.ext instanceof String) return true;
        boolean checkedScript =
                s.ext instanceof JSONObject
                        && ((JSONObject) s.ext).opt("_mm_entrySource") instanceof String
                        && !((JSONObject) s.ext).optString("_mm_entrySource").isEmpty();
        return s.type == 3
                && (Cms.isHttp(s.api) || (s.api != null && s.api.startsWith("file://")))
                && (checkedScript
                        || s.api.split("[?#]", 2)[0]
                                .toLowerCase(Locale.ROOT)
                                .matches(".*\\.(m?js|py)"));
    }

    public JsEngine(Application application, Cms.Config config, Cms.Site selected)
            throws Exception {
        this(application, config, selected, 45000);
    }

    JsEngine(Application application, Cms.Config config, Cms.Site selected, long timeoutMillis)
            throws Exception {
        if (timeoutMillis < 100 || timeoutMillis > 45000)
            throw new IllegalArgumentException("Invalid source operation deadline");
        operationTimeoutMillis = timeoutMillis;
        app = application;
        site = selected;
        storage = app.getSharedPreferences("js-source-" + hash(site.key), 0);
        if (!eligible(site)) throw new IOException("这个来源不是支持的 JavaScript 模块地址");
        try {
            execute(
                    () -> {
                        initialize();
                        return null;
                    });
        } catch (Exception e) {
            failedOperation = true;
            close();
            throw e;
        }
    }

    private <T> T execute(Callable<T> job) throws Exception {
        if (closed) throw new IOException("JavaScript 来源已关闭");
        RequestScope scope = RequestScope.current();
        OperationState operation = new OperationState();
        Future<T> pending =
                executor.submit(
                        () -> {
                            Callable<T> run = () -> runOperation(job, operation);
                            return scope == null ? run.call() : scope.call(run);
                        });
        try {
            return pending.get(48, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            failedOperation = true;
            operation.cancel();
            pending.cancel(true);
            Thread.currentThread().interrupt();
            throw e;
        } catch (TimeoutException e) {
            failedOperation = true;
            operation.cancel();
            pending.cancel(true);
            close();
            throw new IOException("JavaScript 来源请求超时；请切换来源", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IOException("JavaScript 运行异常：" + cause.getClass().getSimpleName(), cause);
        }
    }

    private void armDeadline() {
        OperationState state = activeOperation;
        if (nativeDeadline == null || state == null) return;
        long remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
        state.operation = nativeDeadline.begin(Math.max(1, remaining));
        RequestScope scope = RequestScope.current();
        if (closed || Thread.currentThread().isInterrupted() || scope != null && scope.cancelled)
            state.cancel();
    }

    private <T> T runOperation(Callable<T> job, OperationState state) throws Exception {
        if (closed) throw new IOException("JavaScript 来源已关闭");
        deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(operationTimeoutMillis);
        activeOperation = state;
        Runnable cancelled = state::cancel;
        RequestScope.onCancel(cancelled);
        boolean unhandledCatvodFailure = false;
        try {
            armDeadline();
            return job.call();
        } catch (Exception | Error failure) {
            if (catvodModule) {
                failedOperation = true;
                unhandledCatvodFailure = true;
            }
            throw failure;
        } finally {
            RequestScope.offCancel(cancelled);
            int reason = state.operation == null ? 0 : state.operation.finish();
            activeOperation = null;
            if (reason != 0) {
                failedOperation = true;
                close();
                throw new IOException(
                        reason == 1 ? "脚本执行超过时间限制，已关闭此来源；请重试重新加载" : "脚本请求已取消，已关闭此来源；请重试重新加载");
            }
            if (unhandledCatvodFailure) close();
        }
    }

    private void checkBudget() throws IOException {
        if (closed || Thread.currentThread().isInterrupted() || System.nanoTime() > deadline)
            throw new IOException("JavaScript 请求已取消或超时");
    }

    private void initialize() throws Exception {
        QuickJSLoader.init();
        context = QuickJSContext.create();
        nativeDeadline = new QuickJsDeadline(context);
        armDeadline();
        context.setMemoryLimit(48 * 1024 * 1024);
        context.setMaxStackSize(512 * 1024);
        JSObject global = context.getGlobalObject();
        bind(global, "__hostRequest", a -> request(string(a, 0), string(a, 1)));
        global.setProperty(
                "__hostCatvodRequest",
                (JSCallFunction)
                        args -> {
                            try {
                                return request(string(args, 0), string(args, 1), true);
                            } catch (Exception failure) {
                                // Throw on the JavaScript side so net.req/json can implement
                                // their error contract without depending on JNI exception mapping.
                                return "{\"__movieTransportError\":"
                                        + JSONObject.quote(
                                                "CatVod request failed: "
                                                        + failure.getClass().getSimpleName())
                                        + "}";
                            }
                        });
        bind(
                global,
                "__hostStorage",
                a -> {
                    String key = string(a, 1) + "\n" + string(a, 2);
                    String operation = string(a, 0);
                    if (operation.equals("get")) return storage.getString(key, "");
                    if (operation.equals("delete")) storage.edit().remove(key).apply();
                    else storage.edit().putString(key, string(a, 3)).apply();
                    return "";
                });
        bind(global, "__hostHtml", a -> html(string(a, 0), string(a, 1), string(a, 2)));
        bind(
                global,
                "__hostJoin",
                a -> {
                    String base = string(a, 0), part = string(a, 1);
                    if (part.isEmpty()) return base;
                    if (Cms.isHttp(part) || part.startsWith("magnet:") || part.startsWith("data:"))
                        return part;
                    try {
                        return new URL(new URL(base), part).toString();
                    } catch (Exception e) {
                        return part;
                    }
                });
        bind(
                global,
                "__hostBase64",
                a -> {
                    boolean encode = Boolean.TRUE.equals(a[1]);
                    return encode
                            ? Base64.encodeToString(
                                    string(a, 0).getBytes("ISO-8859-1"), Base64.NO_WRAP)
                            : new String(Base64.decode(string(a, 0), Base64.DEFAULT), "ISO-8859-1");
                });
        bind(global, "__hostEncode", a -> URLEncoder.encode(string(a, 0), string(a, 1)));
        bind(global, "__hostDecode", a -> URLDecoder.decode(string(a, 0), string(a, 1)));
        bind(
                global,
                "__hostSleep",
                a -> {
                    long ms = ((Number) a[0]).longValue();
                    if (ms < 0 || ms > 5000) throw new IOException("脚本等待超过限制");
                    Thread.sleep(ms);
                    checkBudget();
                    return null;
                });
        global.setProperty("__proxyAddress", proxyAddress(false));
        context.evaluate(asset("js-host/bootstrap.js"), "host-bootstrap.js");
        context.evaluate(proxyHelpers(), "host-proxy.js");
        context.evaluate(
                "(()=>{const request=__hostCatvodRequest,base="
                        + JSONObject.quote(proxyAddress(false))
                        + ";const proxy=params=>{let url=base;for(const key of Object.keys(params)){"
                        + "if(['do','site','sitekey','_mm_token'].includes(key.toLowerCase()))throw new TypeError('reserved proxy parameter');"
                        + "if(typeof params[key]!=='string')throw new TypeError('proxy values must be strings');"
                        + "url+='&'+encodeURIComponent(key)+'='+encodeURIComponent(params[key]);}return url;};"
                        + "Object.defineProperty(globalThis,'__movieCatvodBridge',{value:Object.freeze({siteKey:"
                        + JSONObject.quote(proxyKey)
                        + ",request:(url,options)=>{const result=JSON.parse(request(url,JSON.stringify(options)));"
                        + "if(result.__movieTransportError)throw new Error(result.__movieTransportError);return result;},"
                        + "proxyUrl:params=>proxy(params)}),writable:false,configurable:false});})();",
                "catvod-bridge.js");
        context.evaluate(asset("js-host/module-interop.js"), "module-interop.js");
        context.evaluate(asset("js-host/crypto-js.js"), "crypto-js.js");
        context.setModuleLoader(
                new QuickJSContext.DefaultModuleLoader() {
                    public String moduleNormalizeName(String parent, String name) {
                        if (name.equals("catvod") || name.equals("marco:catvod-crypto"))
                            return name;
                        if (name.startsWith("assets://")
                                || Cms.isHttp(name)
                                || name.startsWith("file://")) return name;
                        try {
                            return Cms.resolve(parent, name);
                        } catch (Exception e) {
                            return name;
                        }
                    }

                    public String getModuleStringCode(String name) {
                        try {
                            return module(name);
                        } catch (Exception e) {
                            throw new IllegalStateException(
                                    "JS module load failed: " + e.getClass().getSimpleName(), e);
                        }
                    }
                });
        boolean inlinePython = "csp_LocalPython".equals(site.api);
        boolean checkedScript =
                site.ext instanceof JSONObject && ((JSONObject) site.ext).has("_mm_entrySource");
        if (checkedScript)
            modules.put(site.api, ((JSONObject) site.ext).getString("_mm_entrySource"));
        String spiderOptions =
                new JSONObject()
                        .put(
                                "rawExtension",
                                site.ext instanceof String ? site.ext : JSONObject.NULL)
                        .toString();
        LocalSourcePackage.PythonPackage pythonPackage =
                !inlinePython && site.api.toLowerCase(Locale.ROOT).endsWith(".py")
                        ? LocalSourcePackage.pythonPackage(app.getFilesDir(), site.api)
                        : null;
        String source =
                pythonPackage != null
                        ? pythonPackage.source
                        : inlinePython ? (String) site.ext : module(site.api);
        if (!inlinePython && Cms.looksLikeDrpyRule(source)) throw new DrpyRuleDetected(source);
        catApi = source.contains("__jsEvalReturn") && !isEsModule(source);
        if (inlinePython || site.api.split("[?#]", 2)[0].toLowerCase(Locale.ROOT).endsWith(".py")) {
            catApi = false;
            pythonSource = true;
            global.setProperty("__movieProxyBase", proxyAddress(true));
            bind(
                    global,
                    "__readPythonSibling",
                    args -> {
                        String name = string(args, 0);
                        if (!site.api.startsWith("file://")
                                || !name.matches("(?:[A-Za-z_]\\w*/)*[A-Za-z_]\\w*\\.py"))
                            return null;
                        File parent =
                                new File(new URI(site.api)).getCanonicalFile().getParentFile();
                        File sibling = new File(parent, name).getCanonicalFile();
                        if (!sibling.getPath().startsWith(parent.getPath() + File.separator)
                                || !sibling.isFile()) return null;
                        return module(Cms.fileUri(sibling));
                    });
            context.evaluate(
                    "globalThis.__moviePythonHtmlParser=function(){const navigator={appName:'Netscape'};\n"
                            + asset("python-host/parser.js")
                            + "\nglobalThis.__moviePythonHtmlParser=()=>MoviePythonHtml;return MoviePythonHtml;};",
                    "python-html-loader.js");
            for (String file :
                    new String[] {
                        "skulpt.min.js",
                        "skulpt-stdlib.js",
                        "compiled-modules.js",
                        "html.js",
                        "regex.js",
                        "json.js",
                        "io.js",
                        "spider.js"
                    }) context.evaluate(asset("python-host/" + file), file);
            JSONObject pythonModules = new JSONObject(), packageData = null;
            if (pythonPackage != null) {
                for (Map.Entry<String, String> module : pythonPackage.modules.entrySet())
                    pythonModules.put(module.getKey(), module.getValue());
                JSONObject files = new JSONObject();
                for (Map.Entry<String, byte[]> file : pythonPackage.files.entrySet())
                    files.put(
                            file.getKey(), Base64.encodeToString(file.getValue(), Base64.NO_WRAP));
                packageData =
                        new JSONObject().put("entry", pythonPackage.entry).put("files", files);
            }
            context.evaluate(
                    "globalThis.__movieSpider=createPythonSpider("
                            + JSONObject.quote(source)
                            + ",JSON.parse("
                            + JSONObject.quote(pythonModules.toString())
                            + "),__readPythonSibling,"
                            + (packageData == null
                                    ? "null"
                                    : "JSON.parse("
                                            + JSONObject.quote(packageData.toString())
                                            + ")")
                            + ");void 0;");
        } else if (catApi) {
            context.evaluate(source, site.api);
            context.evaluate(
                    "globalThis.__movieSpider=__movieSelectSpider(__jsEvalReturn(),{preserveInit:true});");
        } else if (isEsModule(source))
            context.evaluateModule(
                    "import * as spider from "
                            + JSONObject.quote(site.api)
                            + ";globalThis.__movieSpider=__movieSelectSpider(spider,"
                            + spiderOptions
                            + ");",
                    site.api + ".host-entry.mjs");
        else if (isCommonJs(source)) {
            bind(
                    global,
                    "__hostCommonJsModule",
                    args -> commonJsModule(string(args, 0), string(args, 1)));
            context.evaluate(
                    "globalThis.__movieSpider=__movieSelectSpider(__movieLoadCommonJS("
                            + JSONObject.quote(site.api)
                            + ",(name,parent)=>JSON.parse(__hostCommonJsModule(name,parent))),"
                            + spiderOptions
                            + ");void 0;",
                    "commonjs-entry.js");
        } else throw new IOException("脚本没有兼容的 Spider 模块入口；DRPY rule 需要对应宿主适配");
        Object ext = inlinePython || checkedScript || site.ext == null ? "" : site.ext;
        String value =
                ext instanceof JSONObject || ext instanceof JSONArray
                        ? ext.toString()
                        : JSONObject.quote(String.valueOf(ext));
        if (catApi) value = "{stype:3,skey:" + JSONObject.quote(site.key) + ",ext:" + value + "}";
        evaluateSettled(
                context,
                "(async()=>{if(typeof __movieSpider.init==='function') await __movieSpider.init("
                        + value
                        + ");if(typeof __movieSpider.getRule==='function'){const r=await __movieSpider.getRule();if(!r||(!r.host&&!r.title&&!r.class_name))throw new Error('DRPY rule failed to initialize');}})()",
                "source-init.js");
        checkBudget();
        initialized = true;
    }

    private String commonJsModule(String reference, String parent) throws Exception {
        if (!(reference.startsWith(".")
                || Cms.isHttp(reference)
                || reference.startsWith("file://")))
            throw new IOException("CommonJS 不提供 Node 内置模块：" + reference);
        String resolved = Cms.resolve(parent, reference);
        String[] candidates = commonJsCandidates(resolved);
        Exception missing = null;
        for (String candidate : candidates) {
            try {
                return new JSONObject()
                        .put("name", candidate)
                        .put("source", module(candidate))
                        .toString();
            } catch (FileNotFoundException error) {
                missing = error;
            } catch (IOException error) {
                // A missing local candidate may use another standard suffix.
                // Do not turn a network/auth/timeout error into unrelated requests.
                if (!candidate.startsWith("file://") || new File(URI.create(candidate)).exists())
                    throw error;
                missing = error;
            }
        }
        throw new IOException("CommonJS 依赖未找到：" + reference, missing);
    }

    static String[] commonJsCandidates(String resolved) {
        String path = URI.create(resolved).getPath();
        if (path != null && path.toLowerCase(Locale.ROOT).matches(".*\\.(m?js|json)$"))
            return new String[] {resolved};
        int query = resolved.indexOf('?'), fragment = resolved.indexOf('#');
        int end = resolved.length();
        if (query >= 0) end = Math.min(end, query);
        if (fragment >= 0) end = Math.min(end, fragment);
        String base = resolved.substring(0, end), suffix = resolved.substring(end);
        return new String[] {
            resolved, base + ".js" + suffix, base + ".json" + suffix, base + "/index.js" + suffix
        };
    }

    private interface HostCall {
        Object run(Object[] args) throws Exception;
    }

    private void bind(JSObject global, String name, HostCall call) {
        global.setProperty(
                name,
                (JSCallFunction)
                        args -> {
                            try {
                                checkBudget();
                                return call.run(args);
                            } catch (Exception e) {
                                throw new IllegalStateException(e.getMessage(), e);
                            }
                        });
    }

    private static String string(Object[] a, int i) {
        return i < a.length && a[i] != null ? String.valueOf(a[i]) : "";
    }

    private String asset(String path) throws IOException {
        try (InputStream in = app.getAssets().open(path)) {
            // The reviewed HTML dependency bundle is larger than 1 MiB. This
            // exception applies only to the packaged asset, never remote input.
            int limit = "catpaw/drpy-dependencies.js".equals(path) ? 2 * 1024 * 1024 : 1024 * 1024;
            return new String(read(in, limit), "UTF-8");
        }
    }

    private String module(String name) throws Exception {
        String found = modules.get(name);
        if (found != null) return found;
        if (modules.size() >= 64) throw new IOException("JS 模块数量超过限制");
        if (name.equals("catvod")) {
            catvodModule = true;
            found = asset("js-host/catvod.mjs");
        } else if (name.equals("marco:catvod-crypto"))
            found =
                    "const module={exports:{}};let exports=module.exports;\n"
                            + asset("js-host/crypto-js.js")
                            + "\nexport default module.exports;";
        else if (name.equals("assets://js/lib/cheerio.min.js"))
            found = asset("js-host/cheerio-bridge.mjs");
        else if (name.equals("assets://js/lib/crypto-js.js"))
            found = "export default globalThis.CryptoJS;";
        else if (name.startsWith("assets://js-host/")) found = asset(name.substring(9));
        else if (name.startsWith("assets://js/lib/"))
            found =
                    download(
                            new URL(new URL(site.api), name.substring(name.lastIndexOf('/') + 1))
                                    .toString());
        else if (Cms.isHttp(name)) found = download(name);
        else if (name.startsWith("file://")) {
            File localFile = new File(URI.create(name));
            String allowedPrefix = app.getFilesDir().getCanonicalPath() + File.separator;
            if (!localFile.isFile() || !localFile.getCanonicalPath().startsWith(allowedPrefix)) {
                throw new IOException("本地 JS 模块路径不可用");
            }
            try (InputStream in = new FileInputStream(localFile)) {
                found = new String(read(in, 2 * 1024 * 1024), "UTF-8");
            }
        } else throw new IOException("不支持的 JS 模块路径");
        modules.put(name, found);
        return found;
    }

    private String download(String address) throws Exception {
        File cache = new File(app.getCacheDir(), "js-modules");
        cache.mkdirs();
        File cached = new File(cache, hash(address) + ".js");
        if (cached.isFile()
                && System.currentTimeMillis() - cached.lastModified() < 24 * 60 * 60 * 1000L)
            try (InputStream in = new FileInputStream(cached)) {
                return new String(read(in, 2 * 1024 * 1024), "UTF-8");
            }
        JSONObject response = new JSONObject(request(address, "{}"));
        int code = response.getInt("code");
        if (code == 404) throw new FileNotFoundException("JS 模块返回 HTTP 404");
        if (code < 200 || code >= 300) throw new IOException("JS 模块返回 HTTP " + code);
        String codeText = response.getString("content");
        if (codeText.length() > 2 * 1024 * 1024) throw new IOException("JS 模块超过大小限制");
        if (codeText.trim().toLowerCase(Locale.ROOT).startsWith("<!doctype html"))
            throw new IOException("JS 模块返回网页");
        try (OutputStream out = new FileOutputStream(cached)) {
            out.write(codeText.getBytes("UTF-8"));
        }
        return codeText;
    }

    private String request(String address, String options) throws Exception {
        return request(address, options, false);
    }

    private static void validateCatvodOptions(JSONObject options) throws IOException {
        Set<String> keys =
                new HashSet<>(
                        Arrays.asList(
                                "method",
                                "headers",
                                "buffer",
                                "redirect",
                                "timeout",
                                "cookie",
                                "bodyBase64",
                                "callTimeout"));
        Iterator<String> names = options.keys();
        while (names.hasNext())
            if (!keys.contains(names.next())) throw new IOException("CatVod 请求参数不支持");
        if (!(options.opt("method") instanceof String)
                || !(options.opt("headers") instanceof JSONObject)
                || !Boolean.FALSE.equals(options.opt("cookie")))
            throw new IOException("CatVod 请求参数格式错误");
        for (String key : new String[] {"buffer", "redirect", "timeout", "callTimeout"}) {
            if (key.equals("callTimeout") && !options.has(key)) continue;
            Object number = options.opt(key);
            if (!(number instanceof Integer || number instanceof Long))
                throw new IOException("CatVod 请求数值参数错误");
            long value = ((Number) number).longValue();
            if (key.equals("buffer")
                    ? value != 2
                    : key.equals("redirect")
                            ? value < 0 || value > 1
                            : value < 1 || value > Integer.MAX_VALUE)
                throw new IOException("CatVod 请求数值参数越界");
        }
        JSONObject headers = options.optJSONObject("headers");
        if (headers.toString().length() > 32768) throw new IOException("CatVod 请求头过大");
        names = headers.keys();
        while (names.hasNext()) {
            String name = names.next();
            Object value = headers.opt(name);
            if (!name.matches("[!#$%&'*+.^_`|~0-9a-z-]+")
                    || !(value instanceof String)
                    || ((String) value).matches("(?s).*[\\r\\n\\x00].*")
                    || Arrays.asList(
                                    "host",
                                    "content-length",
                                    "connection",
                                    "transfer-encoding",
                                    "upgrade",
                                    "trailer",
                                    "te",
                                    "proxy-connection")
                            .contains(name)) throw new IOException("CatVod 请求头格式不支持");
        }
    }

    private String request(String address, String options, boolean catvod) throws Exception {
        checkBudget();
        JSONObject opts = new JSONObject(options.isEmpty() ? "{}" : options);
        if (catvod) validateCatvodOptions(opts);
        JSONObject inputHeaders = opts.optJSONObject("headers");
        String method = opts.optString("method", "GET").toUpperCase(Locale.ROOT);
        if (!Arrays.asList("GET", "POST", "HEAD", "PUT", "DELETE", "PATCH").contains(method)
                && !(catvod && method.equals("OPTIONS"))) throw new IOException("不支持的请求方式");
        final long requestDeadline =
                catvod && opts.has("callTimeout")
                        ? Math.min(
                                deadline,
                                System.nanoTime()
                                        + TimeUnit.MILLISECONDS.toNanos(
                                                opts.getLong("callTimeout")))
                        : deadline;
        URL next = new URL(Cms.normalizeHttp(address));
        String urlAuthorization = null;
        if (next.getUserInfo() != null) {
            String credentials = URLDecoder.decode(next.getUserInfo().replace("+", "%2B"), "UTF-8");
            urlAuthorization =
                    "Basic " + Base64.encodeToString(credentials.getBytes("UTF-8"), Base64.NO_WRAP);
            // Credentials belong in the header, never in a transport or returned response URL.
            next = new URL(next.getProtocol(), next.getHost(), next.getPort(), next.getFile());
        }
        boolean forwardCookies = !catvod;
        byte[] body = null;
        Object payload = opts.opt("body");
        if (payload == null) payload = opts.opt("data");
        final int maxRequestBytes = 6 * 1024 * 1024;
        if (opts.has("bodyBase64")) {
            Object encodedValue = opts.opt("bodyBase64");
            if (opts.has("data") || opts.has("body") || !(encodedValue instanceof String))
                throw new IOException("脚本二进制请求体参数无效");
            String encoded = (String) encodedValue;
            if (encoded.length() > ((maxRequestBytes + 2) / 3) * 4)
                throw new IOException("脚本请求体过大");
            if (encoded.length() % 4 != 0
                    || java.util.regex.Pattern.compile("[^A-Za-z0-9+/=]").matcher(encoded).find())
                throw new IOException("脚本二进制请求体 Base64 无效");
            try {
                body = Base64.decode(encoded, Base64.DEFAULT);
            } catch (IllegalArgumentException invalid) {
                throw new IOException("脚本二进制请求体 Base64 无效", invalid);
            }
            if (!Base64.encodeToString(body, Base64.NO_WRAP).equals(encoded))
                throw new IOException("脚本二进制请求体 Base64 无效");
        } else if (payload instanceof JSONObject) {
            StringBuilder form = new StringBuilder();
            Iterator<String> keys = ((JSONObject) payload).keys();
            while (keys.hasNext()) {
                String key = keys.next();
                if (form.length() > 0) form.append('&');
                form.append(URLEncoder.encode(key, "UTF-8"))
                        .append('=')
                        .append(URLEncoder.encode(((JSONObject) payload).optString(key), "UTF-8"));
            }
            body = form.toString().getBytes("UTF-8");
        } else if (payload != null && payload != JSONObject.NULL)
            body = String.valueOf(payload).getBytes("UTF-8");
        if (body != null && body.length > maxRequestBytes) throw new IOException("脚本请求体过大");
        if (catvod && body != null && (method.equals("GET") || method.equals("HEAD")))
            throw new IOException("CatVod 请求方法不能携带正文");
        for (int redirect = 0; redirect < 6; redirect++) {
            checkBudget();
            if (catvod && System.nanoTime() >= requestDeadline)
                throw new SocketTimeoutException("CatVod 请求超时");
            HttpURLConnection connection = (HttpURLConnection) next.openConnection();
            connection.setInstanceFollowRedirects(false);
            int remaining =
                    (int)
                            Math.max(
                                    1,
                                    TimeUnit.NANOSECONDS.toMillis(
                                            requestDeadline - System.nanoTime()));
            int requested = opts.optInt("timeout", 15000);
            int timeout =
                    Math.max(
                            1,
                            Math.min(
                                    remaining, Math.min(requested > 0 ? requested : 15000, 20000)));
            connection.setConnectTimeout(timeout);
            connection.setReadTimeout(timeout);
            connection.setRequestMethod(method);
            connection.setRequestProperty("User-Agent", Cms.USER_AGENT);
            boolean explicitAuthorization = false;
            if (inputHeaders != null) {
                Iterator<String> keys = inputHeaders.keys();
                while (keys.hasNext()) {
                    String key = keys.next(), v = inputHeaders.optString(key);
                    if (!key.contains("\r")
                            && !key.contains("\n")
                            && !v.contains("\r")
                            && !v.contains("\n")) {
                        connection.setRequestProperty(key, v);
                        if (key.equalsIgnoreCase("Authorization")) explicitAuthorization = true;
                    }
                }
            }
            if (!explicitAuthorization && urlAuthorization != null)
                connection.setRequestProperty("Authorization", urlAuthorization);
            URI uri = next.toURI();
            if (forwardCookies)
                for (Map.Entry<String, List<String>> h :
                        cookies.get(uri, new HashMap<>()).entrySet())
                    if (!h.getValue().isEmpty()
                            && connection.getRequestProperty(h.getKey()) == null)
                        connection.setRequestProperty(
                                h.getKey(), android.text.TextUtils.join("; ", h.getValue()));
            ScheduledFuture<?> transportDeadline = null;
            try {
                RequestScope.attach(connection);
                if (catvod)
                    transportDeadline =
                            REQUEST_TIMEOUTS.schedule(
                                    connection::disconnect, remaining, TimeUnit.MILLISECONDS);
                if (body != null && !method.equals("GET") && !method.equals("HEAD")) {
                    connection.setDoOutput(true);
                    try (OutputStream output = connection.getOutputStream()) {
                        output.write(body);
                    }
                }
                int code = connection.getResponseCode();
                if (!catvod) cookies.put(uri, connection.getHeaderFields());
                if (Arrays.asList(301, 302, 303, 307, 308).contains(code)
                        && opts.optInt("redirect", 1) != 0) {
                    String location = connection.getHeaderField("Location");
                    if (location == null) throw new IOException("JS 重定向缺少地址");
                    URL redirected = new URL(next, location);
                    if (!Cms.isHttp(redirected.toString())) throw new IOException("JS 重定向协议不支持");
                    if (redirected.getUserInfo() != null)
                        throw new IOException("JS 重定向地址不能包含用户名密码");
                    boolean sameOrigin =
                            next.getProtocol().equalsIgnoreCase(redirected.getProtocol())
                                    && next.getHost().equalsIgnoreCase(redirected.getHost())
                                    && (next.getPort() < 0 ? next.getDefaultPort() : next.getPort())
                                            == (redirected.getPort() < 0
                                                    ? redirected.getDefaultPort()
                                                    : redirected.getPort());
                    if (!sameOrigin) {
                        urlAuthorization = null;
                        forwardCookies = false;
                        if (inputHeaders != null) {
                            JSONObject forwarded = new JSONObject();
                            Iterator<String> keys = inputHeaders.keys();
                            while (keys.hasNext()) {
                                String key = keys.next();
                                if (!key.equalsIgnoreCase("Authorization")
                                        && !key.equalsIgnoreCase("Proxy-Authorization")
                                        && !key.equalsIgnoreCase("Cookie")
                                        && !key.equalsIgnoreCase("Cookie2"))
                                    forwarded.put(key, inputHeaders.opt(key));
                            }
                            inputHeaders = forwarded;
                        }
                    }
                    next = redirected;
                    if (code == 303 || code == 302 && method.equals("POST")) {
                        method = "GET";
                        body = null;
                    }
                    continue;
                }
                JSONObject headers = new JSONObject();
                for (Map.Entry<String, List<String>> h : connection.getHeaderFields().entrySet())
                    if (h.getKey() != null)
                        headers.put(
                                h.getKey().toLowerCase(Locale.ROOT),
                                android.text.TextUtils.join(", ", h.getValue()));
                byte[] bytes;
                InputStream stream =
                        code >= 400 ? connection.getErrorStream() : connection.getInputStream();
                String compression = connection.getContentEncoding();
                if (stream != null && "gzip".equalsIgnoreCase(compression))
                    stream = new java.util.zip.GZIPInputStream(stream);
                else if (stream != null && "deflate".equalsIgnoreCase(compression))
                    stream = new java.util.zip.InflaterInputStream(stream);
                if (stream == null) bytes = new byte[0];
                else
                    try (InputStream in = stream) {
                        bytes = read(in, catvod ? 6 * 1024 * 1024 : 8 * 1024 * 1024);
                    }
                if (catvod && System.nanoTime() >= requestDeadline)
                    throw new SocketTimeoutException("CatVod 请求超时");
                JSONObject response = new JSONObject();
                response.put("code", code);
                response.put("headers", headers);
                response.put("url", next.toString());
                if (opts.optInt("buffer", 0) == 2)
                    response.put("content", Base64.encodeToString(bytes, Base64.NO_WRAP));
                else if (opts.optInt("buffer", 0) == 1) {
                    JSONArray numbers = new JSONArray();
                    for (byte b : bytes) numbers.put(b & 255);
                    response.put("content", numbers);
                } else {
                    String encoding = opts.optString("encoding", "UTF-8");
                    java.util.regex.Matcher charset =
                            java.util.regex.Pattern.compile(
                                            "charset=([^;\\s]+)",
                                            java.util.regex.Pattern.CASE_INSENSITIVE)
                                    .matcher(headers.optString("content-type"));
                    if (charset.find()) encoding = charset.group(1).replace("\"", "");
                    if (!Charset.isSupported(encoding)) encoding = "UTF-8";
                    response.put("content", new String(bytes, encoding));
                }
                return response.toString();
            } finally {
                if (transportDeadline != null) {
                    transportDeadline.cancel(false);
                    // API 23-compatible removal avoids retaining completed connections
                    // (and their buffers) until the original operation deadline.
                    if (transportDeadline instanceof Runnable)
                        REQUEST_TIMEOUTS.remove((Runnable) transportDeadline);
                }
                RequestScope.detach(connection);
                connection.disconnect();
            }
        }
        throw new IOException("JS 请求重定向过多");
    }

    private static byte[] read(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (out.size() + n > limit) throw new IOException("JS 响应超过大小限制");
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }

    private static String hash(String value) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256").digest(value.getBytes("UTF-8"));
            StringBuilder s = new StringBuilder();
            for (byte b : bytes) s.append(String.format(Locale.ROOT, "%02x", b & 255));
            return s.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static String html(String source, String expression, String kind) throws Exception {
        String[] parts = expression.split("&&");
        Elements elements = new Elements(Jsoup.parse(source));
        boolean many = kind.equals("many");
        int end = many ? parts.length : Math.max(0, parts.length - 1);
        for (int i = 0; i < end; i++) {
            String selector = parts[i].trim();
            if (selector.isEmpty()) continue;
            Elements next = new Elements();
            for (Element element : elements) next.addAll(element.select(selector));
            elements = next;
            if (!many && elements.size() > 1) elements = new Elements(elements.first());
        }
        if (many) {
            JSONArray a = new JSONArray();
            for (Element element : elements) a.put(element.outerHtml());
            return a.toString();
        }
        if (elements.isEmpty()) return "";
        Element first = elements.first();
        String attribute = parts.length == 0 ? "Text" : parts[parts.length - 1].trim();
        if (attribute.equalsIgnoreCase("Text")) return first.text();
        if (attribute.equalsIgnoreCase("Html")) return first.html();
        return first.attr(attribute);
    }

    private String call(String function, Object... args) throws Exception {
        return execute(
                () -> {
                    JSONArray a = new JSONArray();
                    for (Object value : args) a.put(value);
                    String invocation =
                            "(()=>{const fn=__movieSpider["
                                    + JSONObject.quote(function)
                                    + "];if(typeof fn!=='function')throw new Error('Spider API is missing: ' + "
                                    + JSONObject.quote(function)
                                    + ");return fn.apply(__movieSpider,"
                                    + a.toString()
                                    + ");})()";
                    if (function.equals("proxy"))
                        invocation =
                                "Promise.resolve("
                                        + invocation
                                        + ").then(__movieEncodeProxyResult)";
                    Object result =
                            evaluateSettled(context, invocation, "source-" + function + ".js");
                    checkBudget();
                    if (!(result instanceof String) || ((String) result).isEmpty())
                        throw new IOException("JS 来源未返回数据");
                    return (String) result;
                });
    }

    static Object evaluateSettled(QuickJSContext runtime, String expression, String name) {
        // wrapper-android 3.2.3 calls JS_ExecutePendingJob before evaluate() returns.
        // The second evaluation reads the settled value without spinning or using timers.
        runtime.evaluate("__movieBeginCall(()=> (" + expression + "));void 0;", name);
        return runtime.evaluate("__movieFinishCall()", name + ".result");
    }

    public String home() throws Exception {
        return call("home", true);
    }

    public String homeVideos() throws Exception {
        return call("homeVod");
    }

    public String liveContent(String url) throws Exception {
        return call("liveContent", url);
    }

    public String category(String id, int page) throws Exception {
        return category(id, page, java.util.Collections.emptyMap());
    }

    public String category(String id, int page, java.util.Map<String, String> filters)
            throws Exception {
        return call("category", id, page, true, new JSONObject(filters));
    }

    public String detail(String id) throws Exception {
        return call("detail", catApi ? new JSONArray().put(id) : id);
    }

    public String search(String keyword, int page) throws Exception {
        return call("search", keyword, false, page);
    }

    public String player(String flag, String id) throws Exception {
        return normalizePlayerResult(call("play", flag, id, new JSONArray()));
    }

    /** DRPY may retain its sniff flag after lazy has already resolved a media URL. */
    static String normalizePlayerResult(String response) throws JSONException {
        JSONObject result = new JSONObject(response);
        if (result.optInt("parse", 0) != 1
                || result.optInt("jx", -1) != 0
                || !result.optString("playUrl", "").isEmpty()) return response;
        String url = result.optString("url", "");
        if (!Cms.isHttp(url)) return response;
        try {
            String path = new URL(url).getPath().toLowerCase(Locale.ROOT);
            if (path.matches(".*\\.(mp4|m3u8|mpd|flv|m4a|mp3|webm)$")) {
                result.put("parse", 0);
                return result.toString();
            }
        } catch (MalformedURLException ignored) {
        }
        return response;
    }

    public boolean requiresExternalRuntime() {
        return true;
    }

    public Object[] proxy(Map<String, String> params) throws Exception {
        return decodeProxyResponse(call("proxy", new JSONObject(params)));
    }

    private String proxyAddress(boolean python) {
        return ProxyAddress.base()
                + "/proxy?do="
                + (python ? "py&siteKey=" : "js&site=")
                + proxyKey
                + (ProxyAddress.token.isEmpty() ? "" : "&_mm_token=" + ProxyAddress.token);
    }

    /** Kept at the host boundary so ordinary scripts cannot serialize typed bytes as objects. */
    static String proxyHelpers() {
        return "globalThis.getProxy=function(local=true){if(typeof local!=='boolean')throw new TypeError('local must be boolean');return __proxyAddress;};\n"
                + "globalThis.proxyUrl=function(params={}){if(params===null)params={};"
                + "if(typeof params!=='object'||Array.isArray(params))throw new TypeError('proxy params must be an object');"
                + "let url=__proxyAddress;for(const key of Object.keys(params)){"
                + "if(['do','site','sitekey','_mm_token'].includes(key.toLowerCase()))throw new TypeError('reserved proxy parameter');"
                + "if(!['string','number','boolean'].includes(typeof params[key]))throw new TypeError('proxy values must be scalar');"
                + "url+='&'+encodeURIComponent(key)+'='+encodeURIComponent(params[key]);}return url;};\n"
                + "globalThis.__movieEncodeProxyResult=function(value){"
                + "if(!Array.isArray(value)||value.length<3||value.length>5)return value;"
                + "if(value.length===5&&value[4]!==0&&value[4]!==1)throw new TypeError('invalid proxy encoding flag');"
                + "if(value.length>3&&value[3]!=null&&(typeof value[3]!=='object'||Array.isArray(value[3])))throw new TypeError('invalid proxy response headers');"
                + "const body=value[2];const bytes=body instanceof ArrayBuffer?new Uint8Array(body):"
                + "ArrayBuffer.isView(body)?new Uint8Array(body.buffer,body.byteOffset,body.byteLength):null;"
                + "if(!bytes)return value;if(bytes.length>6*1024*1024)throw new Error('proxy body too large');"
                + "const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';const chunks=[];let part='';"
                + "for(let i=0;i<bytes.length;i+=3){const a=bytes[i],b=bytes[i+1]||0,c=bytes[i+2]||0;"
                + "part+=alphabet[a>>2]+alphabet[((a&3)<<4)|(b>>4)]+(i+1<bytes.length?alphabet[((b&15)<<2)|(c>>6)]:'=')+(i+2<bytes.length?alphabet[c&63]:'=');"
                + "if(part.length>=4096){chunks.push(part);part='';}}chunks.push(part);"
                + "return [value[0],value[1],chunks.join(''),value[3]==null?{}:value[3],1];};";
    }

    /** Buffered script ABI only; native JAR streams remain handled by LocalProxy. */
    static Object[] decodeProxyResponse(String raw) throws IOException {
        final int limit = 6 * 1024 * 1024;
        try {
            if (raw == null || raw.length() > 25 * 1024 * 1024) throw new IOException("脚本代理响应过大");
            JSONArray result = new JSONArray(raw);
            if (result.length() < 3 || result.length() > 5) throw new IOException("脚本代理返回格式错误");
            Object status = result.get(0), mime = result.get(1);
            if (!(status instanceof Integer || status instanceof Long)
                    || ((Number) status).longValue() < 200
                    || ((Number) status).longValue() > 599
                    || !(mime instanceof String)
                    || ((String) mime).length() > 256
                    || !((String) mime)
                            .matches(
                                    "[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(?: *;[^\\r\\n]*)?")
                    || java.util.regex.Pattern.compile("[\\x00-\\x1f\\x7f-\\uffff]")
                            .matcher((String) mime)
                            .find()) throw new IOException("脚本代理状态或类型无效");
            Object flag = result.length() == 5 ? result.get(4) : Integer.valueOf(0);
            if (!(flag instanceof Integer || flag instanceof Long)
                    || (((Number) flag).longValue() != 0 && ((Number) flag).longValue() != 1))
                throw new IOException("脚本代理编码标记无效");
            Map<String, String> headers = new LinkedHashMap<>();
            Object rawHeaders = result.length() > 3 ? result.get(3) : JSONObject.NULL;
            if (rawHeaders != JSONObject.NULL) {
                if (!(rawHeaders instanceof JSONObject) || ((JSONObject) rawHeaders).length() > 64)
                    throw new IOException("脚本代理响应头无效");
                JSONObject values = (JSONObject) rawHeaders;
                Set<String> names = new HashSet<>();
                int size = 0;
                for (Iterator<String> keys = values.keys(); keys.hasNext(); ) {
                    String key = keys.next();
                    Object value = values.get(key);
                    if (!key.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
                            || !(value instanceof String)
                            || java.util.regex.Pattern.compile(
                                            "[\\x00-\\x08\\x0a-\\x1f\\x7f\\u0100-\\uffff]")
                                    .matcher((String) value)
                                    .find()
                            || !names.add(key.toLowerCase(Locale.ROOT)))
                        throw new IOException("脚本代理响应头无效");
                    size +=
                            key.getBytes("UTF-8").length
                                    + ((String) value).getBytes("UTF-8").length;
                    if (size > 16 * 1024) throw new IOException("脚本代理响应头过大");
                    headers.put(key, (String) value);
                }
            }
            Object content = result.get(2);
            byte[] bytes;
            if (content instanceof JSONArray) {
                JSONArray values = (JSONArray) content;
                if (values.length() > limit) throw new IOException("脚本代理正文过大");
                bytes = new byte[values.length()];
                for (int i = 0; i < bytes.length; i++) {
                    Object value = values.get(i);
                    if (!(value instanceof Integer || value instanceof Long)
                            || ((Number) value).longValue() < 0
                            || ((Number) value).longValue() > 255)
                        throw new IOException("脚本代理二进制正文无效");
                    bytes[i] = (byte) ((Number) value).intValue();
                }
            } else if (content instanceof String) {
                String value = (String) content;
                if (((Number) flag).intValue() == 1) {
                    int encodedLimit = ((limit + 2) / 3) * 4;
                    if (value.length() > encodedLimit + 1280) throw new IOException("脚本代理正文过大");
                    if (value.startsWith("data:")) {
                        int comma = value.indexOf(',');
                        if (comma < 0
                                || comma > 256
                                || !value.substring(0, comma).matches("data:[\\x20-\\x7e]*;base64"))
                            throw new IOException("脚本代理 Base64 正文无效");
                        value = value.substring(comma + 1);
                    }
                    value = value.replaceAll("[ \\t\\r\\n]", "");
                    if (value.length() > encodedLimit
                            || value.length() % 4 != 0
                            || !value.matches("[A-Za-z0-9+/]*={0,2}"))
                        throw new IOException("脚本代理 Base64 正文无效");
                    try {
                        bytes = Base64.decode(value, Base64.DEFAULT);
                    } catch (IllegalArgumentException invalid) {
                        throw new IOException("脚本代理 Base64 正文无效");
                    }
                    if (!Base64.encodeToString(bytes, Base64.NO_WRAP).equals(value))
                        throw new IOException("脚本代理 Base64 正文无效");
                } else {
                    if (value.length() > limit) throw new IOException("脚本代理正文过大");
                    bytes = value.getBytes("UTF-8");
                }
            } else throw new IOException("脚本代理正文必须是文字或字节数组");
            if (bytes.length > limit) throw new IOException("脚本代理正文过大");
            return new Object[] {((Number) status).intValue(), mime, bytes, headers};
        } catch (JSONException invalid) {
            // JSON parser diagnostics can contain private source URLs or tokens.
            throw new IOException("脚本代理返回格式错误");
        }
    }

    void activate() {
        synchronized (ACTIVE) {
            if (closed) throw new IllegalStateException("JS source closed");
            JsEngine previous = CURRENT.put(site.key, this);
            ACTIVE.put(proxyKey, this);
            if (previous != null && previous != this) previous.close();
        }
    }

    public boolean isClosed() {
        return closed;
    }

    public static Object[] proxyFor(Map<String, String> params) throws Exception {
        boolean python = "py".equalsIgnoreCase(params.get("do"));
        String key = params.get(python ? "siteKey" : "site");
        JsEngine engine = key == null ? null : ACTIVE.get(key);
        if (engine == null) throw new IOException("JS 代理来源尚未打开");
        if (engine.closed || engine.pythonSource != python) throw new IOException("脚本代理来源已失效");
        return engine.proxy(params);
    }

    public void close() {
        synchronized (ACTIVE) {
            if (closed) return;
            closed = true;
            ACTIVE.remove(proxyKey, this);
            CURRENT.remove(site.key, this);
        }
        OperationState running = activeOperation;
        boolean destroySource = initialized && catvodModule && !failedOperation && running == null;
        if (running != null) running.cancel();
        try {
            executor.execute(
                    () -> {
                        try {
                            if (destroySource
                                    && !failedOperation
                                    && context != null
                                    && nativeDeadline != null) {
                                QuickJsDeadline.Operation cleanup =
                                        nativeDeadline.begin(Math.min(500, operationTimeoutMillis));
                                try {
                                    // Route is already revoked and all host calls reject closed
                                    // sources.
                                    // Cleanup cannot start new network work or revive a cancelled
                                    // source.
                                    evaluateSettled(
                                            context,
                                            "typeof __movieSpider.destroy==='function'?__movieSpider.destroy():undefined",
                                            "source-destroy.js");
                                } finally {
                                    cleanup.finish();
                                }
                            }
                        } catch (Exception ignored) {
                        } finally {
                            if (nativeDeadline != null) {
                                nativeDeadline.close();
                                nativeDeadline = null;
                            }
                            if (context != null) {
                                context.destroy();
                                context = null;
                            }
                        }
                    });
        } catch (RejectedExecutionException ignored) {
        }
        executor.shutdown();
    }
}
