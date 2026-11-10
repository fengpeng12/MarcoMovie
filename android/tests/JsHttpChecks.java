package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.util.concurrent.TimeUnit;
import org.json.*;

/** Runs the real native host HTTP method; only Android text/base64 calls use JVM shims. */
public final class JsHttpChecks {
    static int checks;
    static Method request;

    static void check(boolean passed, String label) {
        if (!passed) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static JsEngine transport() throws Exception {
        // Do not create QuickJS on a host JVM. The HTTP method only needs these two fields.
        Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
        Field singleton = unsafeClass.getDeclaredField("theUnsafe");
        singleton.setAccessible(true);
        Object unsafe = singleton.get(null);
        JsEngine engine =
                (JsEngine)
                        unsafeClass
                                .getMethod("allocateInstance", Class.class)
                                .invoke(unsafe, JsEngine.class);
        Field cookies = JsEngine.class.getDeclaredField("cookies");
        cookies.setAccessible(true);
        cookies.set(engine, new CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER));
        Field deadline = JsEngine.class.getDeclaredField("deadline");
        deadline.setAccessible(true);
        deadline.setLong(engine, System.nanoTime() + TimeUnit.SECONDS.toNanos(45));
        request = JsEngine.class.getDeclaredMethod("request", String.class, String.class);
        request.setAccessible(true);
        return engine;
    }

    static JSONObject get(JsEngine engine, String url, JSONObject options) throws Exception {
        try {
            return new JSONObject((String) request.invoke(engine, url, options.toString()));
        } catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw failure;
        }
    }

    static JSONObject received(JSONObject response) throws Exception {
        return new JSONObject(response.getString("content"));
    }

    static void redirect(HttpExchange exchange, String target) throws IOException {
        exchange.getResponseHeaders().add("Location", target);
        exchange.getResponseHeaders().add("Set-Cookie", "originSession=fixture; Path=/");
        exchange.sendResponseHeaders(302, -1);
        exchange.close();
    }

    static void echo(HttpExchange exchange) throws IOException {
        JSONObject data = new JSONObject();
        try {
            data.put("target", exchange.getRequestURI().toASCIIString());
            for (String header :
                    new String[] {
                        "Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "X-Fixture"
                    }) {
                String value = exchange.getRequestHeaders().getFirst(header);
                data.put(header, value == null ? "" : value);
            }
        } catch (JSONException error) {
            throw new IOException(error);
        }
        byte[] body = data.toString().getBytes("UTF-8");
        exchange.getResponseHeaders().add("Content-Type", "application/json; charset=UTF-8");
        exchange.sendResponseHeaders(200, body.length);
        try (OutputStream output = exchange.getResponseBody()) {
            output.write(body);
        }
    }

    public static void main(String[] args) throws Exception {
        HttpServer first = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer second = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String origin = "http://127.0.0.1:" + first.getAddress().getPort();
        String other = "http://127.0.0.1:" + second.getAddress().getPort();
        first.createContext(
                "/same", exchange -> redirect(exchange, "/module.js?token=same%2Bvalue"));
        first.createContext(
                "/cross", exchange -> redirect(exchange, other + "/module.js?token=cross"));
        first.createContext("/roundtrip", exchange -> redirect(exchange, other + "/bounce"));
        first.createContext(
                "/credential-redirect",
                exchange ->
                        redirect(
                                exchange,
                                other.replace("http://", "http://new:secret@") + "/module.js"));
        first.createContext("/module.js", JsHttpChecks::echo);
        second.createContext("/module.js", JsHttpChecks::echo);
        second.createContext(
                "/bounce", exchange -> redirect(exchange, origin + "/module.js?token=back"));
        first.start();
        second.start();
        try {
            JsEngine engine = transport();
            String authenticated = origin.replace("http://", "http://us%40er:pa%2Bss@");
            String basic =
                    "Basic "
                            + java.util.Base64.getEncoder()
                                    .encodeToString("us@er:pa+ss".getBytes("UTF-8"));
            JSONObject response = get(engine, authenticated + "/same", new JSONObject());
            JSONObject data = received(response);
            check(
                    data.getString("Authorization").equals(basic),
                    "URL Basic credentials survive same-origin redirect");
            check(
                    data.getString("target").equals("/module.js?token=same%2Bvalue"),
                    "module request query remains byte-for-byte encoded");
            check(
                    !response.getString("url").contains("@"),
                    "response URL contains no username or password");
            check(
                    data.getString("Cookie").contains("originSession=fixture"),
                    "same-origin cookie jar remains usable");
            JSONObject headers =
                    new JSONObject()
                            .put("aUtHoRiZaTiOn", "Bearer fixture")
                            .put("pRoXy-AuThOrIzAtIoN", "Basic proxy-fixture")
                            .put("cOoKiE", "explicitSession=fixture")
                            .put("cOoKiE2", "legacySession=fixture")
                            .put("X-Fixture", "retained");
            JSONObject options = new JSONObject().put("headers", headers);
            data = received(get(engine, authenticated + "/same", options));
            check(
                    data.getString("Authorization").equals("Bearer fixture"),
                    "explicit mixed-case Authorization overrides URL Basic");
            check(
                    data.getString("Cookie").equals("explicitSession=fixture"),
                    "same-origin explicit cookie retained");
            for (String path : new String[] {"/cross", "/roundtrip"}) {
                data = received(get(engine, authenticated + path, options));
                check(
                        data.getString("Authorization").isEmpty()
                                && data.getString("Proxy-Authorization").isEmpty()
                                && data.getString("Cookie").isEmpty()
                                && data.getString("Cookie2").isEmpty(),
                        "all credentials removed after origin change " + path);
                check(
                        data.getString("X-Fixture").equals("retained"),
                        "non-sensitive header retained " + path);
            }
            data = received(get(engine, authenticated + "/cross", new JSONObject()));
            check(
                    data.getString("Authorization").isEmpty() && data.getString("Cookie").isEmpty(),
                    "URL credentials and cookie jar do not cross origins");
            response = get(engine, authenticated + "/same", new JSONObject().put("redirect", 0));
            check(
                    response.getInt("code") == 302 && !response.getString("url").contains("@"),
                    "redirect disabled preserves status and redacts URL credentials");
            boolean denied = false;
            try {
                get(engine, origin + "/credential-redirect", new JSONObject());
            } catch (IOException expected) {
                denied = expected.getMessage().equals("JS 重定向地址不能包含用户名密码");
            }
            check(denied, "redirect cannot inject new URL credentials");
            System.out.println(
                    "OK " + checks + " native JS HTTP checks; no JNI/device playback implied");
        } finally {
            first.stop(0);
            second.stop(0);
        }
    }
}
