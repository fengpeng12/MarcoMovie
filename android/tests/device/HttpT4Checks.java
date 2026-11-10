package com.pilipala.marcomovie;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.net.URLDecoder;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/** Public, synthetic HTTP protocol fixture shared by JVM and Android instrumentation. */
public final class HttpT4Checks {
    public interface Check {
        void accept(String name, boolean passed) throws Exception;
    }

    public static void main(String[] args) throws Exception {
        final int[] count = {0};
        run(
                (name, passed) -> {
                    if (!passed) throw new AssertionError(name);
                    count[0]++;
                    System.out.println("PASS " + name);
                });
        System.out.println("T4 protocol checks: " + count[0]);
    }

    static JSONObject request(String value) throws Exception {
        return new JSONObject(value).getJSONObject("request");
    }

    public static void run(Check check) throws Exception {
        try (Fixture fixture = new Fixture()) {
            String config =
                    new JSONObject()
                            .put(
                                    "sites",
                                    new JSONArray()
                                            .put(
                                                    new JSONObject()
                                                            .put("key", "t4-fixture")
                                                            .put("type", 4)
                                                            .put(
                                                                    "api",
                                                                    fixture.origin
                                                                            + "/api.php?token=fixture&ac=old")
                                                            .put(
                                                                    "ext",
                                                                    new JSONObject()
                                                                            .put("catalogue", "中文"))
                                                            .put(
                                                                    "header",
                                                                    new JSONObject()
                                                                            .put(
                                                                                    "Cookie",
                                                                                    "fixture=yes")
                                                                            .put(
                                                                                    "Authorization",
                                                                                    "Fixture token")
                                                                            .put(
                                                                                    "X-Source",
                                                                                    "fixture")
                                                                            .put(
                                                                                    "Origin",
                                                                                    "https://fixture.invalid"))))
                            .toString();
            Cms.Site site = Cms.parseConfig(config, fixture.origin).sites.get(0);
            check.accept("t4_http_selected", HttpT4Engine.eligible(site) && !site.supported());
            HttpT4Engine engine = new HttpT4Engine(site);
            String home = engine.home();
            JSONObject req = request(home),
                    params = req.getJSONObject("params"),
                    headers = req.getJSONObject("headers");
            check.accept(
                    "t4_home_filter",
                    params.getString("filter").equals("true") && !params.has("t"));
            check.accept("t4_endpoint_query_retained", params.getString("token").equals("fixture"));
            check.accept(
                    "t4_structured_extension",
                    new JSONObject(params.getString("extend")).getString("catalogue").equals("中文"));
            check.accept(
                    "t4_import_headers",
                    headers.getString("authorization").equals("Fixture token")
                            && headers.getString("cookie").equals("fixture=yes")
                            && headers.getString("x-source").equals("fixture"));
            check.accept(
                    "t4_home_catalogue",
                    Cms.categories(home).size() == 1 && Cms.listing(home).videos.size() == 1);
            Map<String, String> filters = new LinkedHashMap<>();
            filters.put("class", "剧情&电影");
            filters.put("year", "2026");
            String category = engine.category("分类&?", 3, filters);
            params = request(category).getJSONObject("params");
            check.accept(
                    "t4_category_opaque_id_page",
                    params.getString("t").equals("分类&?") && params.getString("pg").equals("3"));
            check.accept(
                    "t4_category_base64url",
                    params.getString("ext")
                                    .equals("eyJjbGFzcyI6IuWJp-aDhSbnlLXlvbEiLCJ5ZWFyIjoiMjAyNiJ9")
                            || params.getString("ext")
                                    .equals(
                                            "eyJ5ZWFyIjoiMjAyNiIsImNsYXNzIjoi5Ymn5oOFJueUteW9sSJ9"));
            // Decode independently in each runner too; key ordering is not protocol-significant.
            check.accept(
                    "t4_category_replaces_stale_action", params.getString("ac").equals("detail"));
            check.accept("t4_category_pagination", Cms.listing(category).pageCount == 4);
            check.accept(
                    "t4_empty_filters",
                    request(engine.category("1", 1))
                            .getJSONObject("params")
                            .getString("ext")
                            .equals("e30="));
            String opaque = "中文$@@/?x=1&y=2";
            params = request(engine.detail(opaque)).getJSONObject("params");
            check.accept("t4_detail_opaque_id", params.getString("ids").equals(opaque));
            params = request(engine.search("电影 & ?", 2)).getJSONObject("params");
            check.accept(
                    "t4_search_contract",
                    params.getString("wd").equals("电影 & ?")
                            && params.getString("quick").equals("false")
                            && params.getString("pg").equals("2"));
            String play = engine.player("线路&一", opaque);
            params = request(play).getJSONObject("params");
            check.accept(
                    "t4_player_opaque_id_and_flag",
                    params.getString("play").equals(opaque)
                            && params.getString("flag").equals("线路&一"));
            check.accept(
                    "t4_player_result_preserved",
                    new JSONObject(play).getString("url").endsWith("/media.m3u8")
                            && new JSONObject(play)
                                    .getJSONObject("header")
                                    .getString("Referer")
                                    .equals("https://media.invalid/"));
            site.api = fixture.origin + "/echo";
            site.ext = fixture.origin + "/ext";
            engine = new HttpT4Engine(site);
            check.accept(
                    "t4_remote_extension",
                    new JSONObject(
                                    request(engine.detail("1"))
                                            .getJSONObject("params")
                                            .getString("extend"))
                            .getString("remote")
                            .equals("ready"));
            engine.search("x", 1);
            check.accept("t4_remote_extension_cached", fixture.extensions == 1);
            StringBuilder longValue = new StringBuilder();
            for (int i = 0; i < 1200; i++) longValue.append('中');
            site.ext = longValue.toString();
            engine = new HttpT4Engine(site);
            req = request(engine.detail(opaque));
            check.accept(
                    "t4_large_extension_post",
                    req.getString("method").equals("POST")
                            && req.getJSONObject("params").getString("extend").equals(site.ext));
            check.accept(
                    "t4_post_form_ids",
                    req.getJSONObject("params").getString("ids").equals(opaque)
                            && req.getJSONObject("headers")
                                    .getString("content-type")
                                    .startsWith("application/x-www-form-urlencoded"));
            site.api = fixture.origin + "/redirect307";
            check.accept(
                    "t4_post_307_preserves_body",
                    request(new HttpT4Engine(site).detail("redirect"))
                            .getJSONObject("params")
                            .getString("ids")
                            .equals("redirect"));
            site.api = fixture.origin + "/redirect303";
            check.accept(
                    "t4_post_303_becomes_get",
                    request(new HttpT4Engine(site).home()).getString("method").equals("GET"));
            site.api = fixture.origin + "/bad";
            site.ext = "";
            boolean failed = false;
            try {
                new HttpT4Engine(site).home();
            } catch (org.json.JSONException expected) {
                failed = true;
            }
            check.accept("t4_invalid_response_explicit", failed);
        }
    }

    static final class Fixture implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
        final String origin = "http://127.0.0.1:" + listener.getLocalPort();
        final Thread thread;
        volatile boolean closed;
        volatile int extensions;

        Fixture() throws Exception {
            thread =
                    new Thread(
                            () -> {
                                while (!closed)
                                    try (Socket socket = listener.accept()) {
                                        socket.setSoTimeout(5000);
                                        BufferedReader in =
                                                new BufferedReader(
                                                        new InputStreamReader(
                                                                socket.getInputStream(), "UTF-8"));
                                        String[] start = in.readLine().split(" ");
                                        Map<String, String> headers = new LinkedHashMap<>();
                                        String line;
                                        while ((line = in.readLine()) != null && !line.isEmpty()) {
                                            int colon = line.indexOf(':');
                                            headers.put(
                                                    line.substring(0, colon)
                                                            .toLowerCase(Locale.ROOT),
                                                    line.substring(colon + 1).trim());
                                        }
                                        URI uri = new URI(start[1]);
                                        Map<String, String> params = decode(uri.getRawQuery());
                                        int length =
                                                headers.containsKey("content-length")
                                                        ? Integer.parseInt(
                                                                headers.get("content-length"))
                                                        : 0;
                                        StringBuilder body = new StringBuilder();
                                        for (int i = 0; i < length; i++) {
                                            int next = in.read();
                                            if (next < 0) break;
                                            body.append((char) next);
                                        }
                                        params.putAll(decode(body.toString()));
                                        String output;
                                        if (uri.getPath().equals("/ext")) {
                                            extensions++;
                                            output = "{\"remote\":\"ready\"}";
                                        } else if (uri.getPath().equals("/bad"))
                                            output = "<html>failed</html>";
                                        else
                                            output =
                                                    new JSONObject()
                                                            .put(
                                                                    "request",
                                                                    new JSONObject()
                                                                            .put("method", start[0])
                                                                            .put(
                                                                                    "params",
                                                                                    new JSONObject(
                                                                                            params))
                                                                            .put(
                                                                                    "headers",
                                                                                    new JSONObject(
                                                                                            headers)))
                                                            .put(
                                                                    "class",
                                                                    new JSONArray(
                                                                            "[{\"type_id\":\"1\",\"type_name\":\"电影\"}]"))
                                                            .put(
                                                                    "list",
                                                                    new JSONArray(
                                                                            "[{\"vod_id\":\"1\",\"vod_name\":\"Fixture\"}]"))
                                                            .put("page", 3)
                                                            .put("pagecount", 4)
                                                            .put("parse", 0)
                                                            .put("url", origin + "/media.m3u8")
                                                            .put(
                                                                    "header",
                                                                    new JSONObject()
                                                                            .put(
                                                                                    "Referer",
                                                                                    "https://media.invalid/"))
                                                            .toString();
                                        byte[] data = output.getBytes("UTF-8");
                                        int status =
                                                uri.getPath().equals("/redirect307")
                                                        ? 307
                                                        : uri.getPath().equals("/redirect303")
                                                                ? 303
                                                                : 200;
                                        String head =
                                                "HTTP/1.1 "
                                                        + status
                                                        + " OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                                                        + data.length
                                                        + (status != 200
                                                                ? "\r\nLocation: /echo"
                                                                : "")
                                                        + "\r\n\r\n";
                                        socket.getOutputStream().write(head.getBytes("UTF-8"));
                                        socket.getOutputStream().write(data);
                                    } catch (Exception error) {
                                        if (!closed) throw new RuntimeException(error);
                                    }
                            },
                            "t4-http-fixture");
            thread.setDaemon(true);
            thread.start();
        }

        static Map<String, String> decode(String text) throws Exception {
            Map<String, String> out = new LinkedHashMap<>();
            if (text != null && !text.isEmpty())
                for (String part : text.split("&")) {
                    String[] pair = part.split("=", 2);
                    out.put(
                            URLDecoder.decode(pair[0], "UTF-8"),
                            URLDecoder.decode(pair.length == 2 ? pair[1] : "", "UTF-8"));
                }
            return out;
        }

        public void close() throws Exception {
            closed = true;
            listener.close();
            thread.join(6000);
        }
    }
}
