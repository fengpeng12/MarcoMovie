package com.pilipala.marcomovie;

import android.content.Context;
import com.pilipala.catpaw.CatPawHost;
import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.lang.reflect.Field;
import java.net.*;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.*;
import org.json.*;

/** Imported artifact integrity, request boundaries and exact fallback policy, without Node/JNI. */
public final class GuardChecks {
    static int checks;

    interface Work {
        void run() throws Exception;
    }

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
    }

    static void rejects(Work work, String name) throws Exception {
        try {
            work.run();
        } catch (IOException expected) {
            checks++;
            return;
        }
        throw new AssertionError(name);
    }

    static void rejectsDeclaration(Work work, String name) throws Exception {
        try {
            work.run();
        } catch (IOException expected) {
            check("插件 MD5 声明无效".equals(expected.getMessage()), name);
            return;
        }
        throw new AssertionError(name);
    }

    static String digest(byte[] bytes, String kind) throws Exception {
        StringBuilder out = new StringBuilder();
        for (byte value : MessageDigest.getInstance(kind).digest(bytes))
            out.append(String.format(Locale.US, "%02x", value & 255));
        return out.toString();
    }

    static byte[] fixture() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(out)) {
            zip.putNextEntry(new ZipEntry("classes.dex"));
            zip.write("synthetic import transport fixture, never executable".getBytes("UTF-8"));
            zip.closeEntry();
        }
        return out.toByteArray();
    }

    static String authenticated(String base, String credentials) {
        return "http://" + credentials + "@" + base.substring("http://".length());
    }

    public static void main(String[] args) throws Exception {
        File work = new File(args[0]);
        File files = new File(work, "files");
        files.mkdirs();
        Context context = new Context(files, new File(work, "assets"));
        byte[] artifact = fixture();
        File local = new File(files, "input.jar");
        Files.write(local.toPath(), artifact);
        String md5 = digest(artifact, "MD5");
        String declaration = local.toURI() + ";md5;" + md5;
        check(CspEngine.obtain(context, declaration).equals(local), "local declared MD5 verified");
        check(
                CspEngine.obtain(context, local.toURI() + ";MD5;" + md5.toUpperCase(Locale.ROOT))
                        .equals(local),
                "uppercase marker and digest verified locally");
        String[] invalidDigests = {
            "", " ", "\t", "\n", " " + md5, md5 + " ", md5 + ";md5;" + md5, md5 + ";MD5;"
        };
        for (String marker : new String[] {";md5;", ";Md5;", ";MD5;"}) {
            for (String suffix : invalidDigests) {
                rejectsDeclaration(
                        () -> CspEngine.obtain(context, local.toURI() + marker + suffix),
                        "explicit local digest rejected without normalization");
            }
        }
        rejects(
                () ->
                        CspEngine.obtain(
                                context,
                                local.toURI() + ";md5;" + "00000000000000000000000000000000"),
                "local MD5 mismatch rejected");
        rejects(
                () -> CspEngine.obtain(context, local.toURI() + ";md5;bad"),
                "invalid MD5 declaration rejected");
        File outside = new File(work, "outside.jar");
        Files.write(outside.toPath(), artifact);
        rejects(
                () -> CspEngine.obtain(context, outside.toURI().toString()),
                "local boundary checked");
        File bad = new File(files, "invalid.jar");
        Files.write(bad.toPath(), new byte[] {1, 2, 3});
        rejects(
                () -> CspEngine.obtain(context, bad.toURI().toString()),
                "malformed archive rejected");
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer other = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String base = "http://127.0.0.1:" + server.getAddress().getPort();
        String second = "http://127.0.0.1:" + other.getAddress().getPort();
        List<String> authorizations = new ArrayList<>();
        List<String> queries = new ArrayList<>();
        com.sun.net.httpserver.HttpHandler jar =
                exchange -> {
                    authorizations.add(exchange.getRequestHeaders().getFirst("Authorization"));
                    queries.add(exchange.getRequestURI().getRawQuery());
                    exchange.sendResponseHeaders(200, artifact.length);
                    exchange.getResponseBody().write(artifact);
                    exchange.close();
                };
        server.createContext("/jar", jar);
        other.createContext("/jar", jar);
        for (String[] route :
                new String[][] {
                    {"/same", "/jar?token=a%2Bb%2F"},
                    {"/cross", second + "/jar"},
                    {"/inject", authenticated(base, "new:login") + "/jar"}
                }) {
            server.createContext(
                    route[0],
                    exchange -> {
                        exchange.getResponseHeaders().set("Location", route[1]);
                        exchange.sendResponseHeaders(302, -1);
                        exchange.close();
                    });
        }
        final String[] result = {
            "{\"version\":1,\"rule\":\"var rule={title:'Fixture',host:'https://media.test'};\",\"origin\":\"https://media.test/\"}"
        };
        final int[] status = {200};
        final String[] drpyResponse = {"{\"error\":\"drpy_verification_required\"}"};
        List<JSONObject> calls = Collections.synchronizedList(new ArrayList<>());
        List<String> requestBodies = Collections.synchronizedList(new ArrayList<>());
        AtomicInteger busyRemaining = new AtomicInteger();
        AtomicBoolean holdNext = new AtomicBoolean();
        CountDownLatch held = new CountDownLatch(1), releaseHeld = new CountDownLatch(1);
        server.createContext(
                "/fixture/_port-bootstrap",
                exchange -> {
                    try {
                        String body = Cms.read(exchange.getRequestBody(), 512);
                        calls.add(new JSONObject(body));
                        requestBodies.add(body);
                        if (holdNext.getAndSet(false)) {
                            held.countDown();
                            try {
                                releaseHeld.await(3, TimeUnit.SECONDS);
                            } catch (InterruptedException interrupted) {
                                Thread.currentThread().interrupt();
                                throw new IOException(interrupted);
                            }
                        }
                        boolean busy = busyRemaining.getAndDecrement() > 0;
                        byte[] response =
                                (busy ? "{\"error\":\"bootstrap_busy\"}" : result[0])
                                        .getBytes("UTF-8");
                        exchange.sendResponseHeaders(busy ? 429 : status[0], response.length);
                        exchange.getResponseBody().write(response);
                    } finally {
                        exchange.close();
                    }
                });
        server.createContext(
                "/fixture/",
                exchange -> {
                    byte[] response = drpyResponse[0].getBytes("UTF-8");
                    exchange.sendResponseHeaders(422, response.length);
                    exchange.getResponseBody().write(response);
                    exchange.close();
                });
        server.start();
        other.start();
        Field endpoint = CatPawHost.class.getDeclaredField("endpoint");
        endpoint.setAccessible(true);
        try {
            CspEngine.obtain(context, authenticated(base, "user:p%2Bss") + "/same;md5;" + md5);
            check(
                    "Basic dXNlcjpwK3Nz".equals(authorizations.get(0))
                            && "token=a%2Bb%2F".equals(queries.get(0)),
                    "Basic and raw query retained on same-origin redirect");
            CspEngine.obtain(context, authenticated(base, "user:pass") + "/cross");
            check(authorizations.get(1) == null, "cross-origin redirect strips Basic");
            rejects(
                    () -> CspEngine.obtain(context, base + "/inject"),
                    "redirect cannot inject new credentials");
            rejects(
                    () ->
                            CspEngine.obtain(
                                    context, base + "/jar;md5;00000000000000000000000000000000"),
                    "download MD5 mismatch rejected");
            String rawAddress = base + "/jar?token=a%2Bb%2F";
            File downloaded =
                    CspEngine.obtain(context, rawAddress + ";MD5;" + md5.toUpperCase(Locale.ROOT));
            check(
                    Arrays.equals(Files.readAllBytes(downloaded.toPath()), artifact),
                    "remote uppercase checksum accepted and verified");
            check(
                    "token=a%2Bb%2F".equals(queries.get(queries.size() - 1)),
                    "raw URL query remains unchanged before checksum marker");
            CspEngine.obtain(context, rawAddress);
            check(
                    "token=a%2Bb%2F".equals(queries.get(queries.size() - 1)),
                    "URL without marker remains unchanged");
            String sha = digest(artifact, "SHA-256");
            int requestCount = queries.size();
            for (String marker : new String[] {";md5;", ";Md5;", ";MD5;"}) {
                for (String suffix : invalidDigests) {
                    String malformed = rawAddress + marker + suffix;
                    File selection =
                            new File(
                                    files,
                                    "csp/selection-"
                                            + CspEngine.hex(malformed.getBytes("UTF-8"))
                                            + ".txt");
                    Files.write(selection.toPath(), sha.getBytes("UTF-8"));
                    rejectsDeclaration(
                            () -> CspEngine.obtain(context, malformed),
                            "invalid remote checksum rejected before populated cache lookup");
                }
            }
            check(
                    queries.size() == requestCount,
                    "invalid declarations never reach the remote server");
            endpoint.set(null, base + "/fixture");
            Cms.Config config = new Cms.Config();
            config.origin = "https://subscription.test/config.php";
            config.spider = declaration;
            Cms.Site site = new Cms.Site();
            site.api = "csp_Dm84Guard";
            site.key = "guard_fixture";
            site.type = 3;
            site.headers.put("Authorization", "fixture-secret");
            site.headers.put("User-Agent", "Fixture");
            AtomicInteger fallbacks = new AtomicInteger();
            GuardEngine.Fallback fallback =
                    () -> {
                        fallbacks.incrementAndGet();
                        return null;
                    };
            SourceEngine engine = GuardEngine.open(context, config, site, fallback);
            check(
                    engine instanceof DrpyEngine && fallbacks.get() == 0,
                    "reviewed result uses real DRPY caller");
            JSONObject request = calls.get(0);
            check(
                    request.length() == 3
                            && request.getInt("version") == 1
                            && request.getString("adapter").equals("dm84-v1")
                            && request.getString("artifactHash")
                                    .equals(digest(artifact, "SHA-256")),
                    "strict capability bootstrap contract");
            for (String[] selected :
                    new String[][] {
                        {"csp_Dm84", "dm84-v1"}, {"csp_Dm84Guard", "dm84-v1"},
                        {"csp_Auete", "auete-v1"}, {"csp_AueteGuard", "auete-v1"},
                        {"csp_Bttwoo", "bttwoo-v1"}, {"csp_BttwooGuard", "bttwoo-v1"},
                        {"csp_T4", "t4-v1"}, {"csp_T4Guard", "t4-v1"}
                    }) {
                Cms.Site alias = new Cms.Site();
                alias.api = selected[0];
                alias.type = 3;
                check(GuardEngine.eligible(alias), "exact Guard alias accepted");
                check(
                        GuardEngine.adapterFor(alias).equals(selected[1]),
                        "alias selects its explicit adapter");
            }
            int beforeAdapters = calls.size();
            Cms.Site unknown = new Cms.Site();
            unknown.type = 3;
            unknown.api = "csp_AueteUnknownGuard";
            check(
                    !GuardEngine.eligible(unknown),
                    "other Guard plugins are not implicitly supported");
            rejects(
                    () -> GuardEngine.open(context, config, unknown, fallback),
                    "unknown alias rejected");
            rejects(
                    () -> new CatPawHost(context).bootstrapGuard(artifact, "auete-v2", null),
                    "unknown adapter rejected before staging or request");
            unknown.api = "csp_BttwooUnknownGuard";
            check(!GuardEngine.eligible(unknown), "Bttwoo prefix does not imply adapter support");
            rejects(
                    () -> GuardEngine.open(context, config, unknown, fallback),
                    "unknown Bttwoo alias rejected");
            rejects(
                    () -> new CatPawHost(context).bootstrapGuard(artifact, "bttwoo-v2", null),
                    "unknown Bttwoo version rejected");
            check(
                    calls.size() == beforeAdapters && fallbacks.get() == 0,
                    "unknown adapters do not invoke host or fallback");
            new CatPawHost(context).bootstrapGuard(artifact, null);
            check(
                    calls.get(calls.size() - 1).getString("adapter").equals("dm84-v1"),
                    "legacy bootstrap overload retains DM84 default");
            Cms.Site auete = new Cms.Site();
            auete.key = site.key;
            auete.api = "csp_AueteGuard";
            auete.type = 3;
            auete.headers.putAll(site.headers);
            JSONObject dm84Result = new JSONObject(result[0]);
            JSONObject aueteResult =
                    new JSONObject(result[0])
                            .put(
                                    "rule",
                                    "var rule={title:'Auete fixture',host:'https://media.test'};");
            result[0] = aueteResult.toString();
            check(
                    GuardEngine.open(context, config, auete, fallback) instanceof DrpyEngine,
                    "Auete uses the independent DRPY caller");
            JSONObject aueteCall = calls.get(calls.size() - 1);
            check(
                    aueteCall.getString("adapter").equals("auete-v1")
                            && aueteCall
                                    .getString("artifactHash")
                                    .equals(request.getString("artifactHash")),
                    "same artifact selects distinct adapter without mixing results");
            Cms.Site dm84Runtime = GuardEngine.portableSite(config, site, dm84Result);
            Cms.Site aueteRuntime = GuardEngine.portableSite(config, auete, aueteResult);
            JSONObject dm84Manifest =
                    DrpyEngine.manifest(
                            config,
                            dm84Runtime,
                            (url, headers) -> {
                                throw new IOException("unexpected fetch");
                            });
            JSONObject aueteManifest =
                    DrpyEngine.manifest(
                            config,
                            aueteRuntime,
                            (url, headers) -> {
                                throw new IOException("unexpected fetch");
                            });
            check(
                    !dm84Manifest.getString("sourceId").equals(aueteManifest.getString("sourceId")),
                    "same owner key origin and artifact have isolated adapter state");
            check(
                    dm84Runtime.key.equals(site.key) && !aueteRuntime.key.equals(site.key),
                    "DM84 identity unchanged while Auete receives an internal namespace");
            check(
                    site.key.equals("guard_fixture")
                            && auete.key.equals(site.key)
                            && site.api.equals("csp_Dm84Guard")
                            && auete.api.equals("csp_AueteGuard"),
                    "original external source and history identities remain unchanged");
            auete.api = "csp_Auete";
            check(
                    GuardEngine.portableSite(config, auete, aueteResult)
                            .key
                            .equals(aueteRuntime.key),
                    "Auete aliases retain one stable internal state namespace");
            Cms.Site bttwoo = new Cms.Site();
            bttwoo.key = site.key;
            bttwoo.api = "csp_BttwooGuard";
            bttwoo.type = 3;
            bttwoo.headers.putAll(site.headers);
            JSONObject bttwooResult = new JSONObject(dm84Result.toString());
            result[0] = bttwooResult.toString();
            check(
                    GuardEngine.open(context, config, bttwoo, fallback) instanceof DrpyEngine,
                    "Bttwoo exact adapter initializes the independent DRPY caller");
            JSONObject bttwooCall = calls.get(calls.size() - 1);
            check(
                    bttwooCall.getString("adapter").equals("bttwoo-v1")
                            && bttwooCall
                                    .getString("artifactHash")
                                    .equals(request.getString("artifactHash")),
                    "same imported artifact selects the Bttwoo adapter explicitly");
            Cms.Site bttwooRuntime = GuardEngine.portableSite(config, bttwoo, bttwooResult);
            JSONObject bttwooManifest =
                    DrpyEngine.manifest(
                            config,
                            bttwooRuntime,
                            (url, headers) -> {
                                throw new IOException("unexpected fetch");
                            });
            check(
                    new HashSet<String>(
                                            Arrays.asList(
                                                    dm84Manifest.getString("sourceId"),
                                                    aueteManifest.getString("sourceId"),
                                                    bttwooManifest.getString("sourceId")))
                                    .size()
                            == 3,
                    "all three adapters isolate state for the same key origin and artifact");
            check(
                    bttwoo.key.equals(site.key)
                            && bttwoo.api.equals("csp_BttwooGuard")
                            && !bttwooRuntime.key.equals(site.key),
                    "Bttwoo internal namespace never mutates original source identity");
            bttwoo.api = "csp_Bttwoo";
            check(
                    GuardEngine.portableSite(config, bttwoo, bttwooResult)
                            .key
                            .equals(bttwooRuntime.key),
                    "Bttwoo aliases use one stable internal namespace");
            int beforeOverrides = calls.size();
            for (Object override :
                    new Object[] {
                        new JSONObject().put("siteUrl", "https://custom.test/"),
                        "{\"siteUrl\":\"https://media.test/\"}"
                    }) {
                for (Cms.Site overridden : new Cms.Site[] {auete, bttwoo}) {
                    overridden.ext = override;
                    check(
                            !GuardEngine.eligible(overridden) && CspEngine.eligible(overridden),
                            "siteUrl override stays on existing Android plugin host");
                    rejects(
                            () -> GuardEngine.open(context, config, overridden, fallback),
                            "override cannot silently run the portable default origin");
                    rejects(
                            () -> GuardEngine.portableSite(config, overridden, dm84Result),
                            "portable conversion cannot discard siteUrl override");
                }
            }
            check(
                    calls.size() == beforeOverrides,
                    "siteUrl override never invokes portable bootstrap");
            auete.ext = new JSONObject().put("siteUrl", "");
            check(GuardEngine.eligible(auete), "empty siteUrl keeps the portable default adapter");
            bttwoo.ext = new JSONObject().put("siteUrl", "");
            check(GuardEngine.eligible(bttwoo), "empty Bttwoo siteUrl keeps portable default");
            result[0] = dm84Result.toString();
            Cms.Site t4 = new Cms.Site();
            t4.key = site.key;
            t4.api = "csp_T4Guard";
            t4.type = 3;
            t4.ext = "ZmFrZQ==";
            check(
                    GuardEngine.open(context, config, t4, fallback) instanceof DrpyEngine,
                    "T4 uses local independent runtime");
            JSONObject t4Call = calls.get(calls.size() - 1);
            check(
                    t4Call.getString("adapter").equals("t4-v1")
                            && t4Call.getString("extension").equals("ZmFrZQ==")
                            && t4Call.length() == 4,
                    "T4 preserves exact extension in bootstrap contract");
            int beforeInvalidExt = calls.size();
            for (String extension :
                    new String[] {null, "", new String(new char[6000]).replace('\0', '汉')}) {
                rejects(
                        () ->
                                new CatPawHost(context)
                                        .bootstrapGuard(artifact, "t4-v1", extension, null),
                        "T4 missing or oversized extension rejected before request");
            }
            rejects(
                    () ->
                            new CatPawHost(context)
                                    .bootstrapGuard(artifact, "dm84-v1", "unexpected", null),
                    "other adapters cannot receive extra configuration");
            check(calls.size() == beforeInvalidExt, "invalid extensions never reach bootstrap");
            File staged = new File(files, "catpaw/imports/" + digest(artifact, "SHA-256") + ".jar");
            check(
                    Arrays.equals(Files.readAllBytes(staged.toPath()), artifact),
                    "exact original bytes staged");
            Cms.Site portable = GuardEngine.portableSite(config, site, new JSONObject(result[0]));
            check(
                    portable.key.equals(site.key)
                            && !portable.headers.containsKey("Authorization")
                            && portable.headers.get("User-Agent").equals("Fixture"),
                    "identity preserved and cross-origin credentials removed");
            config.origin = "https://media.test/config.php";
            check(
                    GuardEngine.portableSite(config, site, new JSONObject(result[0]))
                            .headers
                            .containsKey("Authorization"),
                    "same-origin explicit source credentials retained");
            int beforeBusy = calls.size();
            busyRemaining.set(2);
            check(
                    GuardEngine.open(context, config, site, fallback) instanceof DrpyEngine,
                    "temporary bootstrap busy recovers without native fallback");
            check(
                    calls.size() == beforeBusy + 3 && fallbacks.get() == 0,
                    "only two transient busy responses are retried");
            check(
                    requestBodies.get(beforeBusy).equals(requestBodies.get(beforeBusy + 1))
                            && requestBodies
                                    .get(beforeBusy)
                                    .equals(requestBodies.get(beforeBusy + 2)),
                    "busy retries preserve the exact request bytes and artifact hash");
            status[0] = 429;
            result[0] = "{\"error\":\"bootstrap_busy\"}";
            int beforeTimeout = calls.size();
            long busyStarted = System.nanoTime();
            rejects(
                    () -> GuardEngine.open(context, config, site, fallback),
                    "persistent busy is bounded");
            long elapsedBusy = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - busyStarted);
            check(
                    elapsedBusy >= 1900
                            && elapsedBusy < 5000
                            && calls.size() - beforeTimeout < 20
                            && fallbacks.get() == 0,
                    "busy retries stop within the two-second window without fallback");
            RequestScope backoffScope = new RequestScope();
            AtomicReference<Throwable> cancelled = new AtomicReference<>();
            int beforeCancel = calls.size();
            Thread backoff =
                    new Thread(
                            () -> {
                                try {
                                    backoffScope.call(
                                            () ->
                                                    GuardEngine.open(
                                                            context, config, site, fallback));
                                } catch (Throwable failure) {
                                    cancelled.set(failure);
                                }
                            },
                            "guard-busy-cancel-test");
            backoff.setDaemon(true);
            backoff.start();
            long waitUntil = System.nanoTime() + 2000000000L;
            while (calls.size() == beforeCancel && System.nanoTime() < waitUntil) Thread.sleep(5);
            Thread.sleep(20);
            backoffScope.cancel();
            backoff.join(1000);
            check(
                    !backoff.isAlive() && cancelled.get() instanceof InterruptedIOException,
                    "RequestScope cancellation interrupts busy backoff");
            Thread.sleep(300);
            check(
                    calls.size() == beforeCancel + 1 && fallbacks.get() == 0,
                    "cancelled busy request cannot issue a late retry or fallback");
            status[0] = 200;
            result[0] = dm84Result.toString();
            holdNext.set(true);
            RequestScope socketScope = new RequestScope();
            cancelled.set(null);
            Thread socket =
                    new Thread(
                            () -> {
                                try {
                                    socketScope.call(
                                            () ->
                                                    GuardEngine.open(
                                                            context, config, site, fallback));
                                } catch (Throwable failure) {
                                    cancelled.set(failure);
                                }
                            },
                            "guard-socket-cancel-test");
            socket.setDaemon(true);
            socket.start();
            check(held.await(2, TimeUnit.SECONDS), "bootstrap socket reached the local server");
            socketScope.cancel();
            socket.join(1000);
            boolean socketStopped = !socket.isAlive();
            releaseHeld.countDown();
            socket.join(1000);
            check(
                    socketStopped && cancelled.get() instanceof IOException && fallbacks.get() == 0,
                    "RequestScope cancellation closes the active bootstrap socket");
            check(
                    GuardEngine.open(context, config, site, fallback) instanceof DrpyEngine,
                    "host remains reusable after cancellation");
            CatPawHost localHost = new CatPawHost(context);
            String drpyAddress = localHost.installDrpy(dm84Manifest);
            try {
                localHost.post(drpyAddress, new JSONObject());
                throw new AssertionError("captcha must be explicit");
            } catch (CatPawHost.DrpySourceException expected) {
                check(
                        expected.code.equals("drpy_verification_required")
                                && expected.getMessage().equals("此片源需要完成网站验证码，暂时无法加载"),
                        "real loopback 422 captcha has an allowlisted typed error");
            }
            drpyResponse[0] = "{\"error\":\"drpy_local_proxy_not_supported\"}";
            try {
                localHost.post(drpyAddress, new JSONObject());
                throw new AssertionError("proxy error must be explicit");
            } catch (CatPawHost.DrpySourceException expected) {
                check(
                        expected.code.equals("drpy_local_proxy_not_supported"),
                        "local proxy error stays typed");
            }
            drpyResponse[0] = "{\"error\":\"drpy_filter_not_supported\"}";
            try {
                localHost.post(drpyAddress, new JSONObject());
                throw new AssertionError("unsupported filter must be explicit");
            } catch (CatPawHost.DrpySourceException expected) {
                check(
                        expected.code.equals("drpy_filter_not_supported")
                                && expected.getMessage().equals("此片源不支持当前筛选条件"),
                        "unsupported filter is a fixed typed error, not an empty result");
            }
            for (String errorBody :
                    new String[] {"{\"error\":\"private-error-body\"}", "private-error-body"}) {
                drpyResponse[0] = errorBody;
                try {
                    localHost.post(drpyAddress, new JSONObject());
                    throw new AssertionError("unknown error must fail");
                } catch (IOException expected) {
                    check(
                            !(expected instanceof CatPawHost.DrpySourceException)
                                    && !expected.getMessage().contains("private-error-body"),
                            "unknown DRPY error content is never exposed");
                }
            }
            char[] tooLarge = new char[16385];
            Arrays.fill(tooLarge, 'x');
            drpyResponse[0] = new String(tooLarge);
            rejects(
                    () -> localHost.post(drpyAddress, new JSONObject()),
                    "DRPY error body limited to16KB");
            drpyResponse[0] = "{\"error\":\"drpy_verification_required\"}";
            try {
                localHost.release(drpyAddress);
                throw new AssertionError("non-DRPY route must fail normally");
            } catch (IOException expected) {
                check(
                        !(expected instanceof CatPawHost.DrpySourceException),
                        "typed source error mapping is confined to DRPY route");
            }
            status[0] = 422;
            result[0] = "{\"error\":\"guard_artifact_unsupported\"}";
            GuardEngine.open(context, config, site, fallback);
            check(
                    fallbacks.get() == 1,
                    "exact unsupported artifact falls back to original Android host");
            for (String error :
                    new String[] {
                        "guard_artifact_integrity", "guard_artifact_invalid", "bootstrap_request"
                    }) {
                result[0] = new JSONObject().put("error", error).toString();
                rejects(
                        () -> GuardEngine.open(context, config, site, fallback),
                        "no fallback for " + error);
            }
            check(fallbacks.get() == 1, "integrity errors never invoke fallback");
            status[0] = 200;
            for (String invalid :
                    new String[] {
                        "{}",
                        "[]",
                        "{\"version\":1,\"rule\":\"var rule={};\",\"origin\":\"https://user:pass@media.test/\"}"
                    }) {
                result[0] = invalid;
                rejects(
                        () -> GuardEngine.open(context, config, site, fallback),
                        "malformed bootstrap rejected");
            }
            config.spider = local.toURI() + ";md5;00000000000000000000000000000000";
            int before = calls.size();
            rejects(
                    () -> GuardEngine.open(context, config, site, fallback),
                    "MD5 failure before bootstrap or fallback");
            check(
                    calls.size() == before && fallbacks.get() == 1,
                    "no fallback and no host call after bad imported digest");
            config.spider = declaration;
            endpoint.set(null, null);
            GuardEngine.open(context, config, site, fallback);
            check(
                    fallbacks.get() == 2,
                    "typed pre-start runtime unavailability keeps original Android host");
        } finally {
            endpoint.set(null, null);
            server.stop(0);
            other.stop(0);
        }
        System.out.println(
                "native Guard import: "
                        + checks
                        + " checks passed (no native Node execution claim)");
    }
}
