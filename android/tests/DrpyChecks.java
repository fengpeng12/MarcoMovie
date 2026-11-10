package com.pilipala.marcomovie;

import android.content.Context;
import com.pilipala.catpaw.CatPawHost;
import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.*;

/** Real caller, immutable rule staging and HTTP transport; no native runtime claim. */
public final class DrpyChecks {
    static int checks;

    static void check(boolean condition, String name) {
        if (!condition) throw new AssertionError(name);
        checks++;
    }

    interface Work {
        void run() throws Exception;
    }

    static void rejects(Work action, String name) throws Exception {
        try {
            action.run();
        } catch (IOException expected) {
            checks++;
            return;
        }
        throw new AssertionError(name);
    }

    static Cms.Site site(String api, Object ext) {
        Cms.Site site = new Cms.Site();
        site.key = "fixture";
        site.api = api;
        site.type = 3;
        site.playUrl = "";
        site.ext = ext;
        site.headers.put("User-Agent", "Fixture");
        return site;
    }

    static final String RULE =
            "var rule={title:'Fixture',host:'https://source.test',class_name:'Movie',class_url:'1'};";

    static void authenticatedFetch() throws Exception {
        HttpServer first = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer other = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String base = "http://127.0.0.1:" + first.getAddress().getPort();
        String second = "http://127.0.0.1:" + other.getAddress().getPort();
        com.sun.net.httpserver.HttpHandler echo =
                exchange -> {
                    try {
                        JSONObject value =
                                new JSONObject()
                                        .put("query", exchange.getRequestURI().getRawQuery());
                        for (String key : exchange.getRequestHeaders().keySet())
                            value.put(
                                    key.toLowerCase(Locale.US),
                                    exchange.getRequestHeaders().getFirst(key));
                        byte[] content = value.toString().getBytes("UTF-8");
                        exchange.sendResponseHeaders(200, content.length);
                        exchange.getResponseBody().write(content);
                    } finally {
                        exchange.close();
                    }
                };
        first.createContext("/echo", echo);
        other.createContext("/echo", echo);
        for (String[] route :
                new String[][] {
                    {"/same", "/echo?token=a%2Bb%2F"},
                    {"/cross", second + "/echo"},
                    {"/roundtrip", second + "/return"},
                    {
                        "/inject",
                        "http://new:login@127.0.0.1:" + first.getAddress().getPort() + "/echo"
                    }
                }) {
            first.createContext(
                    route[0],
                    exchange -> {
                        exchange.getResponseHeaders().set("Location", route[1]);
                        exchange.sendResponseHeaders(302, -1);
                        exchange.close();
                    });
        }
        other.createContext(
                "/return",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", base + "/echo");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });
        first.start();
        other.start();
        try {
            JSONObject same =
                    new JSONObject(
                            Cms.fetch(
                                    base.replace("http://", "http://user:p%2Bss@") + "/same",
                                    null));
            check(
                    "Basic dXNlcjpwK3Nz".equals(same.optString("authorization"))
                            && same.getString("query").equals("token=a%2Bb%2F"),
                    "PHP/rule URL Basic and raw query survive same-origin redirect");
            Map<String, String> headers = new LinkedHashMap<>();
            for (String key :
                    new String[] {"aUtHoRiZaTiOn", "Cookie", "Cookie2", "Proxy-Authorization"})
                headers.put(key, "fixture");
            headers.put("X-Fixture", "retained");
            check(
                    new JSONObject(
                                    Cms.fetch(
                                            base.replace("http://", "http://user:pass@") + "/same",
                                            headers))
                            .getString("authorization")
                            .equals("fixture"),
                    "explicit CMS Authorization overrides URL credentials");
            for (String path : new String[] {"/cross", "/roundtrip"}) {
                JSONObject value = new JSONObject(Cms.fetch(base + path, headers));
                check(
                        !value.has("authorization")
                                && !value.has("cookie")
                                && !value.has("cookie2")
                                && !value.has("proxy-authorization")
                                && value.getString("x-fixture").equals("retained"),
                        "CMS redirect credentials stripped " + path);
            }
            rejects(
                    () -> Cms.fetch(base + "/inject", null),
                    "redirect userinfo injection rejected");
            for (String credentials : new String[] {"", "u", "u:", "u:p", "user:中文", "u:+pass"})
                check(
                        Cms.basicAuthorization(credentials)
                                .equals(
                                        "Basic "
                                                + java.util.Base64.getEncoder()
                                                        .encodeToString(
                                                                credentials.getBytes("UTF-8"))),
                        "API23 Basic encoding parity");
        } finally {
            first.stop(0);
            other.stop(0);
        }
    }

    public static void main(String[] args) throws Exception {
        authenticatedFetch();
        File work = new File(args[0]), files = new File(work, "files");
        files.mkdirs();
        Context context = new Context(files, new File(work, "assets"));
        Cms.Config config = new Cms.Config();
        config.origin = "https://source.test/sub/config.php";
        for (String code :
                new String[] {
                    RULE,
                    RULE.replace("var rule", "let rule"),
                    RULE.replace("var rule", "const rule"),
                    "// export default {}\n" + RULE,
                    "const note='module.exports; var rule';\n" + RULE,
                    "const regex=/export default|var rule=/;\n" + RULE,
                    "const note=`exports.home; var rule`;\n" + RULE
                }) check(Cms.looksLikeDrpyRule(code), "genuine rule classification");
        for (String code :
                new String[] {
                    "// var rule={};",
                    "const note='var rule={}';",
                    "const note=`var rule={}`;",
                    RULE + "\nexport default {home(){}}",
                    RULE + "module.exports={home(){}}",
                    RULE + "exports['home']=()=>{};"
                }) check(!Cms.looksLikeDrpyRule(code), "do not replace Spider or quoted rule");
        check(
                Cms.parseConfig(RULE, "").sites.get(0).api.equals("csp_LocalRule.js"),
                "inline rule import");
        check(
                !DrpyEngine.eligible(site("https://source.test/drpy2.js", "./rule.js")),
                "remote runtime filename is not compatibility proof");
        AtomicInteger fetches = new AtomicInteger();
        Cms.Site descriptor = site("csp_Drpy", "./rules/entry.js");
        JSONObject manifest =
                DrpyEngine.manifest(
                        config,
                        descriptor,
                        (url, headers) -> {
                            check(
                                    url.equals("https://source.test/sub/rules/entry.js"),
                                    "relative rule origin");
                            fetches.incrementAndGet();
                            return RULE;
                        });
        check(
                fetches.get() == 1 && manifest.getString("rule").equals(RULE),
                "fetch actual rule once");
        JSONObject inline =
                DrpyEngine.manifest(
                        new Cms.Config(),
                        site("csp_LocalRule.js", new JSONObject().put("_mm_entrySource", RULE)),
                        (url, h) -> {
                            throw new AssertionError("inline fetched");
                        });
        check(
                inline.getString("origin").startsWith("pkg://")
                        && inline.getString("sourceId").matches("[a-f0-9]{64}"),
                "local manifest identity");
        Cms.Site legacy = site("csp_LocalRule.js", RULE);
        JSONObject legacyA =
                DrpyEngine.manifest(
                        new Cms.Config(),
                        legacy,
                        (url, h) -> {
                            throw new AssertionError("inline fetched");
                        });
        legacy.ext = RULE.replace("Fixture", "Other fixture");
        JSONObject legacyB =
                DrpyEngine.manifest(
                        new Cms.Config(),
                        legacy,
                        (url, h) -> {
                            throw new AssertionError("inline fetched");
                        });
        check(
                !legacyA.getString("sourceId").equals(legacyB.getString("sourceId")),
                "reused legacy inline key cannot share rule state");
        check(
                legacyB.getString("sourceId")
                        .equals(
                                DrpyEngine.manifest(
                                                new Cms.Config(),
                                                legacy,
                                                (url, h) -> {
                                                    throw new AssertionError("inline fetched");
                                                })
                                        .getString("sourceId")),
                "same inline source reopens stable state");
        JSONObject publicState =
                DrpyEngine.manifest(config, descriptor, RULE, "/fixture/files", (url, h) -> RULE);
        JSONObject privateState =
                DrpyEngine.manifest(
                        config, descriptor, RULE, "/fixture/files/private-space", (url, h) -> RULE);
        check(
                !publicState.getString("sourceId").equals(privateState.getString("sourceId")),
                "public and private storage scopes cannot share state");
        check(
                !publicState.toString().contains("/fixture/files")
                        && !privateState.toString().contains("/fixture/files"),
                "local storage namespace is hashed only");
        check(
                publicState
                        .getString("sourceId")
                        .equals(
                                DrpyEngine.manifest(
                                                config,
                                                descriptor,
                                                RULE.replace("Fixture", "Updated"),
                                                "/fixture/files",
                                                (url, h) -> RULE)
                                        .getString("sourceId")),
                "addressed source update preserves its own state");
        Cms.Site authenticated =
                site(
                        "https://user:p%2Bss@source.test/rule.php?key=one#label",
                        new JSONObject().put("_mm_entrySource", RULE));
        JSONObject auth =
                DrpyEngine.manifest(
                        config,
                        authenticated,
                        (url, h) -> {
                            throw new AssertionError("preloaded fetched");
                        });
        check(
                auth.getString("origin").equals("https://source.test/rule.php?key=one")
                        && auth.getJSONObject("headers")
                                .getString("Authorization")
                                .equals("Basic dXNlcjpwK3Nz"),
                "userinfo becomes scoped header");
        JSONObject same =
                new JSONObject(
                        DrpyEngine.playback("{\"url\":\"https://source.test/video.m3u8\"}", auth));
        check(same.getJSONObject("header").has("Authorization"), "same-origin media auth");
        JSONObject cross =
                new JSONObject(
                        DrpyEngine.playback("{\"url\":\"https://cdn.test/video.m3u8\"}", auth));
        check(
                !cross.getJSONObject("header").has("Authorization")
                        && cross.getJSONObject("header").has("User-Agent"),
                "cross-origin auth stripped, UA retained");
        JSONObject explicit =
                new JSONObject(
                        DrpyEngine.playback(
                                "{\"url\":\"https://cdn.test/video.m3u8\",\"header\":{\"authorization\":\"fixture-explicit\"}}",
                                auth));
        check(
                explicit.getJSONObject("header")
                                .getString("authorization")
                                .equals("fixture-explicit")
                        && !explicit.getJSONObject("header").has("Authorization"),
                "explicit result auth wins once");
        JSONObject variants =
                new JSONObject(
                        DrpyEngine.playback(
                                "{\"url\":[\"A\",\"https://source.test/a.m3u8\",\"B\",\"https://cdn.test/b.m3u8\"]}",
                                auth));
        check(
                !variants.getJSONObject("header").has("Authorization"),
                "mixed-origin quality credentials omitted");
        Map<String, String> defaults = new LinkedHashMap<>();
        for (String key :
                new String[] {
                    "AUTHORIZATION",
                    "Cookie",
                    "Cookie2",
                    "Proxy-Authorization",
                    "Referer",
                    "User-Agent"
                }) defaults.put(key, "fixture");
        check(
                Cms.inheritedHeaders("https://source.test/a", "https://SOURCE.test:443/b", defaults)
                                .size()
                        == 6,
                "default port and case origin match");
        check(
                Cms.inheritedHeaders("https://source.test/a", "http://source.test/b", defaults)
                                .size()
                        == 2,
                "scheme boundary");
        check(
                Cms.inheritedHeaders("https://source.test/a", "https://source.test:444/b", defaults)
                                .size()
                        == 2,
                "port boundary");
        Cms.Site secure = site("https://source.test/api", null);
        secure.headers.putAll(defaults);
        Cms.Episode original = new Cms.Episode();
        original.url = "https://source.test/old.m3u8";
        original.headers.put("Cookie", "fixture-original");
        Cms.Episode media =
                MediaOptions.episode(
                        secure,
                        original,
                        new JSONObject()
                                .put("url", "https://cdn.test/a.m3u8")
                                .put(
                                        "header",
                                        new JSONObject().put("Authorization", "fixture-result")));
        check(
                media.headers.size() == 3
                        && "fixture-result".equals(media.headers.get("Authorization"))
                        && !media.headers.containsKey("Cookie"),
                "production media normalization preserves only explicit CDN credential");
        CatPawHost host = new CatPawHost(context);
        String logical = host.installDrpy(manifest);
        File stored = new File(files, "catpaw/" + new URI(logical).getHost() + "/drpy.json");
        check(
                Files.readAllBytes(stored.toPath()).length
                                == manifest.toString().getBytes("UTF-8").length
                        && host.installDrpy(manifest).equals(logical),
                "manifest stable reopen");
        check(
                new URI(logical)
                        .getHost()
                        .equals(
                                DrpyEngine.sourceId(
                                        new String(Files.readAllBytes(stored.toPath()), "UTF-8"))),
                "exact UTF8 content address");
        rejects(
                () ->
                        host.installDrpy(
                                new JSONObject(manifest.toString())
                                        .put("origin", "https://user:pass@source.test/x")),
                "credential-bearing manifest rejected");
        rejects(
                () ->
                        host.installDrpy(
                                new JSONObject(manifest.toString()).put("requestTimeoutMs", 16000)),
                "timeout capped");
        rejects(
                () ->
                        host.installDrpy(
                                new JSONObject(manifest.toString())
                                        .put(
                                                "headers",
                                                new JSONObject().put("Host", "other.test"))),
                "transport header forbidden");
        Method stage = CatPawHost.class.getDeclaredMethod("stageDrpyAssets");
        stage.setAccessible(true);
        stage.invoke(host);
        check(
                new File(files, "catpaw/drpy-core.js").length() > 100000,
                "verified production runtime assets staged");
        Files.write(
                new File(work, "assets/catpaw/drpy-core.js").toPath(),
                "tampered".getBytes("UTF-8"));
        try {
            stage.invoke(host);
            throw new AssertionError("tampered asset accepted");
        } catch (InvocationTargetException expected) {
            check(
                    expected.getCause() instanceof IOException,
                    "asset hash enforced before overwrite");
        }
        List<JSONObject> calls = Collections.synchronizedList(new ArrayList<>());
        AtomicInteger releases = new AtomicInteger();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/fixture",
                exchange -> {
                    byte[] response;
                    try {
                        if (exchange.getRequestURI().getPath().endsWith("/_release")) {
                            releases.incrementAndGet();
                            response = "{}".getBytes("UTF-8");
                        } else {
                            if (!exchange.getRequestMethod().equals("POST")
                                    || !exchange.getRequestHeaders()
                                            .getFirst("Content-Type")
                                            .startsWith("application/json"))
                                throw new IOException("request contract");
                            JSONObject body =
                                    new JSONObject(
                                            Cms.read(exchange.getRequestBody(), 1024 * 1024));
                            calls.add(body);
                            response =
                                    (body.getString("method").equals("play")
                                                    ? "{\"url\":\"https://cdn.test/v.m3u8\",\"parse\":0}"
                                                    : "{\"list\":[{\"vod_id\":\"fixture\"}]}")
                                            .getBytes("UTF-8");
                        }
                        exchange.sendResponseHeaders(200, response.length);
                        exchange.getResponseBody().write(response);
                    } catch (Exception error) {
                        exchange.sendResponseHeaders(500, -1);
                    } finally {
                        exchange.close();
                    }
                });
        Field endpoint = CatPawHost.class.getDeclaredField("endpoint");
        endpoint.setAccessible(true);
        server.start();
        endpoint.set(null, "http://127.0.0.1:" + server.getAddress().getPort() + "/fixture");
        try {
            DrpyEngine engine = new DrpyEngine(context, config, site("csp_Drpy", RULE));
            check(
                    new JSONObject(engine.home()).getJSONArray("list").length() == 1,
                    "raw JSON response decoded once");
            engine.homeVideos();
            engine.category("movie", 2, Collections.singletonMap("year", "2026"));
            engine.search("片名", 3);
            engine.detail("video-id");
            engine.player("main", "episode-id");
            check(
                    calls.size() == 6
                            && calls.get(0).getJSONArray("args").getBoolean(0)
                            && calls.get(1).getJSONArray("args").length() == 0,
                    "home ABI");
            check(
                    calls.get(2)
                                    .getJSONArray("args")
                                    .getJSONObject(3)
                                    .getString("year")
                                    .equals("2026")
                            && calls.get(2).getJSONArray("args").getInt(1) == 2,
                    "category filters ABI");
            check(
                    calls.get(3).getJSONArray("args").getInt(2) == 3
                            && calls.get(4).getJSONArray("args").getString(0).equals("video-id")
                            && calls.get(5).getJSONArray("args").length() == 3,
                    "search detail play ABI");
            engine.close();
            engine.close();
            check(releases.get() == 1, "idempotent worker release");
        } finally {
            endpoint.set(null, null);
            server.stop(0);
        }
        Files.write(stored.toPath(), "{}".getBytes("UTF-8"));
        rejects(() -> host.installDrpy(manifest), "stored content integrity");
        System.out.println(
                "native DRPY caller: " + checks + " checks passed (no native Node boot claim)");
    }
}
