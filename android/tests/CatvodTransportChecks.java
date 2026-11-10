package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.util.Base64;
import org.json.*;

/** Actual JsEngine HTTP transport with JVM shims, not a QuickJS/device claim. */
public final class CatvodTransportChecks {
    static int checks;
    static Method request;

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
        System.out.println("PASS " + name);
    }

    static JSONObject options() throws Exception {
        return new JSONObject()
                .put("method", "GET")
                .put("headers", new JSONObject())
                .put("buffer", 2)
                .put("redirect", 1)
                .put("timeout", 1000)
                .put("cookie", false);
    }

    static JSONObject call(JsEngine engine, String url, JSONObject options) throws Exception {
        try {
            return new JSONObject((String) request.invoke(engine, url, options.toString(), true));
        } catch (InvocationTargetException failure) {
            throw (Exception) failure.getCause();
        }
    }

    static JSONObject decoded(JSONObject value) throws Exception {
        return new JSONObject(
                new String(Base64.getDecoder().decode(value.getString("content")), "UTF-8"));
    }

    static void echo(HttpExchange exchange) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        byte[] buffer = new byte[256];
        int count;
        while ((count = exchange.getRequestBody().read(buffer)) >= 0) body.write(buffer, 0, count);
        JSONObject result = new JSONObject();
        result.put("method", exchange.getRequestMethod());
        result.put("body", Base64.getEncoder().encodeToString(body.toByteArray()));
        for (String name : new String[] {"Cookie", "Authorization", "Content-Type"})
            result.put(
                    name,
                    exchange.getRequestHeaders().getFirst(name) == null
                            ? ""
                            : exchange.getRequestHeaders().getFirst(name));
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Set-Cookie", "catvod=must-not-persist; Path=/");
        byte[] bytes = result.toString().getBytes("UTF-8");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    public static void main(String[] args) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer other = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String base = "http://127.0.0.1:" + server.getAddress().getPort();
        String next = "http://127.0.0.1:" + other.getAddress().getPort();
        server.createContext("/echo", CatvodTransportChecks::echo);
        other.createContext("/echo", CatvodTransportChecks::echo);
        server.createContext(
                "/redirect",
                e -> {
                    e.getResponseHeaders().set("Location", next + "/echo");
                    e.getResponseHeaders()
                            .set("Set-Cookie", "redirectCookie=must-not-persist; Path=/");
                    e.sendResponseHeaders(302, -1);
                    e.close();
                });
        server.createContext(
                "/slow",
                e -> {
                    try {
                        Thread.sleep(250);
                        echo(e);
                    } catch (Exception ignored) {
                        e.close();
                    }
                });
        server.start();
        other.start();
        try {
            JsEngine engine = JsHttpChecks.transport();
            request =
                    JsEngine.class.getDeclaredMethod(
                            "request", String.class, String.class, boolean.class);
            request.setAccessible(true);
            JSONObject opts = options().put("method", "OPTIONS");
            check(
                    decoded(call(engine, base + "/echo", opts))
                            .getString("method")
                            .equals("OPTIONS"),
                    "profile OPTIONS supported");
            for (String body : new String[] {"{\"title\":\"本机\"}", "q=a%20b", ""}) {
                opts =
                        options()
                                .put("method", "POST")
                                .put(
                                        "bodyBase64",
                                        Base64.getEncoder().encodeToString(body.getBytes("UTF-8")));
                check(
                        decoded(call(engine, base + "/echo", opts))
                                .getString("body")
                                .equals(opts.getString("bodyBase64")),
                        "exact UTF8/empty request bytes " + body.length());
            }
            opts = options().put("method", "POST").put("bodyBase64", "AP+AQQ==");
            check(
                    decoded(call(engine, base + "/echo", opts))
                            .getString("body")
                            .equals("AP+AQQ=="),
                    "binary 00 ff 80 41 preserved");
            JsHttpChecks.get(engine, base + "/echo", new JSONObject());
            check(
                    decoded(call(engine, base + "/echo", options())).getString("Cookie").isEmpty(),
                    "CatVod does not inherit legacy cookie jar");
            opts = options().put("headers", new JSONObject().put("cookie", "explicit=ok"));
            check(
                    decoded(call(engine, base + "/echo", opts))
                            .getString("Cookie")
                            .equals("explicit=ok"),
                    "explicit cookie preserved");
            JsEngine isolated = JsHttpChecks.transport();
            call(isolated, base + "/echo", options());
            check(
                    JsHttpChecks.received(
                                    JsHttpChecks.get(isolated, base + "/echo", new JSONObject()))
                            .getString("Cookie")
                            .isEmpty(),
                    "profile Set-Cookie does not populate legacy jar");
            opts =
                    options()
                            .put(
                                    "headers",
                                    new JSONObject()
                                            .put("authorization", "Bearer fixture")
                                            .put("cookie", "explicit=ok"));
            JSONObject result = decoded(call(engine, base + "/redirect", opts));
            check(
                    result.getString("Cookie").isEmpty()
                            && result.getString("Authorization").isEmpty(),
                    "cross-origin redirect strips credentials");
            JsEngine redirected = JsHttpChecks.transport();
            call(redirected, base + "/redirect", options());
            check(
                    JsHttpChecks.received(
                                    JsHttpChecks.get(redirected, base + "/echo", new JSONObject()))
                            .getString("Cookie")
                            .isEmpty(),
                    "redirect Set-Cookie does not populate legacy jar");
            check(
                    call(engine, base + "/redirect", options().put("redirect", 0)).getInt("code")
                            == 302,
                    "redirect zero retained");
            long start = System.nanoTime();
            boolean timedOut = false;
            try {
                call(engine, base + "/slow", options().put("callTimeout", 60));
            } catch (IOException expected) {
                timedOut = true;
            }
            check(
                    timedOut && (System.nanoTime() - start) / 1000000 < 1000,
                    "bounded whole-call deadline");
            check(
                    call(engine, base + "/echo", options()).getInt("code") == 200,
                    "transport usable after short deadline");
            JSONObject[] invalid = {
                options().put("cookie", true),
                options().put("buffer", 3),
                options().put("unknown", 1),
                options().put("timeout", 1.5),
                options().put("callTimeout", 0),
                options().put("headers", new JSONObject().put("host", "other")),
                options()
                        .put("method", "POST")
                        .put("bodyBase64", "AP+AQQ==")
                        .put("data", "conflict"),
                options().put("bodyBase64", "AP+AQQ==")
            };
            for (int i = 0; i < invalid.length; i++) {
                boolean denied = false;
                try {
                    call(engine, base + "/echo", invalid[i]);
                } catch (IOException expected) {
                    denied = true;
                }
                check(denied, "invalid normalized option rejected " + i);
            }
            Field timers = JsEngine.class.getDeclaredField("REQUEST_TIMEOUTS");
            timers.setAccessible(true);
            check(
                    ((java.util.concurrent.ScheduledThreadPoolExecutor) timers.get(null))
                            .getQueue()
                            .isEmpty(),
                    "completed request timers release connection references");
            System.out.println(
                    "OK " + checks + " CatVod native HTTP checks; no JNI/device acceptance");
        } finally {
            server.stop(0);
            other.stop(0);
        }
    }
}
