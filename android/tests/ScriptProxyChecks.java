package com.pilipala.marcomovie;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Real loopback router + real shared helper in Node; Android JNI is a separate gate. */
public final class ScriptProxyChecks {
    private static int checks;

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static final class RuntimeFixture implements Closeable {
        final Process process;
        final BufferedReader input;
        final Writer output;

        RuntimeFixture(String node, String script) throws IOException {
            process =
                    new ProcessBuilder(node, "--jitless", script)
                            .redirectError(ProcessBuilder.Redirect.INHERIT)
                            .start();
            input =
                    new BufferedReader(
                            new InputStreamReader(
                                    process.getInputStream(), StandardCharsets.UTF_8));
            output = new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8);
        }

        synchronized Object command(JSONObject command) throws Exception {
            output.write(command.toString() + "\n");
            output.flush();
            String response = input.readLine();
            if (response == null) throw new IOException("fixture runtime exited");
            JSONObject result = new JSONObject(response);
            if (result.has("error")) throw new IOException(result.getString("error"));
            return result.get("value");
        }

        String play(String key, String mode) throws Exception {
            return ((JSONObject)
                            command(
                                    new JSONObject()
                                            .put("op", "play")
                                            .put("key", key)
                                            .put("mode", mode)))
                    .getString("url");
        }

        public void close() throws IOException {
            output.close();
            process.destroy();
        }
    }

    static final class Response {
        int status;
        final Map<String, String> headers = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        byte[] body;
    }

    private static Response fetch(String address, String method, String... headers)
            throws Exception {
        HttpURLConnection request = (HttpURLConnection) new URL(address).openConnection();
        request.setConnectTimeout(3000);
        request.setReadTimeout(5000);
        request.setInstanceFollowRedirects(false);
        request.setRequestMethod(method);
        for (int i = 0; i < headers.length; i += 2)
            request.setRequestProperty(headers[i], headers[i + 1]);
        try {
            Response result = new Response();
            result.status = request.getResponseCode();
            for (Map.Entry<String, List<String>> entry : request.getHeaderFields().entrySet())
                if (entry.getKey() != null)
                    result.headers.put(entry.getKey(), entry.getValue().get(0));
            InputStream stream =
                    result.status >= 400 ? request.getErrorStream() : request.getInputStream();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            if (stream != null)
                try (InputStream body = stream) {
                    byte[] buffer = new byte[1024];
                    for (int n; (n = body.read(buffer)) != -1; ) bytes.write(buffer, 0, n);
                }
            result.body = bytes.toByteArray();
            return result;
        } finally {
            request.disconnect();
        }
    }

    private static Object[] decode(Object body, Object... tail) throws Exception {
        JSONArray result = new JSONArray().put(200).put("application/octet-stream").put(body);
        for (Object item : tail) result.put(item);
        return JsEngine.decodeProxyResponse(result.toString());
    }

    private static int rawStatus(String address, String... headers) throws Exception {
        URL url = new URL(address);
        try (Socket socket = new Socket("127.0.0.1", url.getPort())) {
            socket.setSoTimeout(5000);
            StringBuilder request = new StringBuilder("GET " + url.getFile() + " HTTP/1.1\r\n");
            boolean host = false;
            for (int i = 0; i < headers.length; i += 2) {
                if (headers[i].equalsIgnoreCase("host")) host = true;
                request.append(headers[i]).append(": ").append(headers[i + 1]).append("\r\n");
            }
            if (!host) request.append("Host: 127.0.0.1:").append(url.getPort()).append("\r\n");
            socket.getOutputStream()
                    .write(
                            request.append("Connection: close\r\n\r\n")
                                    .toString()
                                    .getBytes(StandardCharsets.ISO_8859_1));
            return Integer.parseInt(
                    new BufferedReader(
                                    new InputStreamReader(
                                            socket.getInputStream(), StandardCharsets.ISO_8859_1))
                            .readLine()
                            .split(" ")[1]);
        }
    }

    private static void invalid(String json) throws Exception {
        try {
            JsEngine.decodeProxyResponse(json);
            throw new AssertionError("invalid response accepted");
        } catch (IOException expected) {
            checks++;
        }
    }

    private static String base(LocalProxy server, String kind, String key) {
        return LocalProxy.address()
                + "/proxy?do="
                + kind
                + (kind.equals("py") ? "&siteKey=" : "&site=")
                + key
                + "&_mm_token="
                + server.token;
    }

    private static void liveCatalogueHeaders() throws Exception {
        try (LocalProxy server =
                new LocalProxy(
                        null,
                        new Cms.Config(),
                        params -> {
                            JSONObject headers = new JSONObject(params.get("request-headers"));
                            if (!"https://origin.test".equals(params.get("origin"))
                                    || !"upstream.test".equals(params.get("host"))
                                    || !"upstream.test".equals(params.get("Host"))
                                    || !"https://origin.test".equals(headers.optString("origin"))
                                    || !"upstream.test".equals(headers.optString("host")))
                                throw new IOException("upstream headers changed before callback");
                            return new Object[] {
                                200,
                                "text/plain",
                                "Owned,#genre#\nChannel,https://media.test/live.m3u8\n"
                            };
                        })) {
            LiveCatalog.Source source = new LiveCatalog.Source();
            source.url = "proxy://do=js&site=cccccccccccccccccccccccccccccccc";
            source.headers.put("oRiGiN", "https://origin.test");
            source.headers.put("hOsT", "upstream.test");
            source.headers.put("User-Agent", "Catalogue-UA");
            check(source.isLocalProxy(), "plugin catalogue scheme selects local host");
            source.url = LocalProxy.rewrite(source.url);
            Map<String, String> original = new LinkedHashMap<>(source.headers);
            LiveCatalog.Catalog result = LiveCatalog.load(source);
            check(
                    result.channelCount() == 1,
                    "live reader reaches local callback with upstream Origin and Host");
            check(
                    source.headers.equals(original),
                    "local catalogue load leaves source headers intact");
            check(
                    result.groups.get(0).channels.get(0).streams.get(0).headers.equals(original),
                    "remote channel inherits upstream headers without internal transport names");
            check(
                    rawStatus(source.url, "Origin", "https://origin.test") == 403,
                    "ordinary browser Origin still rejected by local catalogue listener");
            for (String unrelated :
                    new String[] {
                        "https://media.test/proxy?_mm_token=" + server.token,
                        "http://127.0.0.1:1234/proxy?_mm_token=" + server.token,
                        LocalProxy.address() + "/other?_mm_token=" + server.token,
                        source.url.replace(server.token, "wrong"),
                        source.url + "&_mm_token=" + server.token
                    })
                check(
                        ProxyAddress.requestHeaders(unrelated, original).equals(original),
                        "header adaptation is restricted to one authenticated local route");
        }
    }

    public static void main(String[] args) throws Exception {
        liveCatalogueHeaders();
        byte[] expected = new byte[] {0, (byte) 255, (byte) 128, 65};
        check(
                Arrays.equals(
                        (byte[]) decode(new JSONArray().put(0).put(255).put(128).put(65))[2],
                        expected),
                "integer array remains exact binary");
        check(
                Arrays.equals(
                        (byte[])
                                decode(
                                        "data:application/octet-stream;base64,AP+AQ Q==\r\n",
                                        JSONObject.NULL,
                                        1)[2],
                        expected),
                "canonical wrapped Base64 retains bytes");
        check(
                new String((byte[]) decode("中文")[2], StandardCharsets.UTF_8).equals("中文"),
                "text is UTF-8");
        for (String json :
                new String[] {
                    "{}",
                    "[200,\"text/plain\",{}]",
                    "[200,\"text/plain\",null]",
                    "[200.5,\"text/plain\",\"x\"]",
                    "[200,\"text/plain\\r\\nX: bad\",\"x\"]",
                    "[200,\"text/plain\",\"x\",{\"X\":\"bad\\nvalue\"}]",
                    "[200,\"text/plain\",\"x\",{\"X\":\"a\",\"x\":\"b\"}]",
                    "[200,\"text/plain\",\"x\",null,2]",
                    "[200,\"text/plain\",[256]]",
                    "[200,\"text/plain\",[-1]]",
                    "[200,\"text/plain\",\"Zh==\",null,1]"
                }) invalid(json);
        char[] huge = new char[6 * 1024 * 1024 + 1];
        Arrays.fill(huge, 'x');
        invalid(new JSONArray().put(200).put("text/plain").put(new String(huge)).toString());
        try (RuntimeFixture runtime = new RuntimeFixture(args[0], args[1])) {
            String py = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", js = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
            Set<String> active =
                    Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());
            active.add(py);
            active.add(js);
            CountDownLatch entered = new CountDownLatch(1), cancelled = new CountDownLatch(1);
            LocalProxy server =
                    new LocalProxy(
                            null,
                            null,
                            params -> {
                                String key =
                                        params.get(
                                                params.get("do").equalsIgnoreCase("py")
                                                        ? "siteKey"
                                                        : "site");
                                if (!active.contains(key))
                                    throw new IOException("fixture route closed");
                                if ("hold".equals(params.get("mode"))) {
                                    RequestScope.onCancel(cancelled::countDown);
                                    entered.countDown();
                                    Thread.sleep(10000);
                                    return decode("");
                                }
                                Object result =
                                        runtime.command(
                                                new JSONObject()
                                                        .put("op", "proxy")
                                                        .put("key", key)
                                                        .put("params", new JSONObject(params)));
                                return JsEngine.decodeProxyResponse(result.toString());
                            });
            try {
                runtime.command(
                        new JSONObject()
                                .put("op", "init")
                                .put("key", py)
                                .put("kind", "py")
                                .put("helpers", JsEngine.proxyHelpers())
                                .put("base", base(server, "py", py)));
                runtime.command(
                        new JSONObject()
                                .put("op", "init")
                                .put("key", js)
                                .put("kind", "js")
                                .put("helpers", JsEngine.proxyHelpers())
                                .put("base", base(server, "js", js)));
                String pythonUrl = runtime.play(py, "bytes"), jsUrl = runtime.play(js, "bytes");
                Response one = fetch(pythonUrl, "GET");
                check(
                        one.status == 200 && Arrays.equals(one.body, expected),
                        "Python getProxyUrl -> real router -> localProxy exact bytes");
                check(
                        "True".equals(one.headers.get("X-Query-OK")),
                        "Python Unicode and encoded query round trip once");
                Response two = fetch(pythonUrl, "GET");
                check(
                        "2".equals(two.headers.get("X-Count")),
                        "Python callback retains player source state");
                Response jsResult = fetch(jsUrl, "GET");
                check(
                        jsResult.status == 200
                                && Arrays.equals(jsResult.body, expected)
                                && "1".equals(jsResult.headers.get("X-Count")),
                        "JS getProxy -> real router with isolated state");
                for (String mode : new String[] {"typed", "buffer", "view"}) {
                    Response value = fetch(runtime.play(js, mode), "GET");
                    check(
                            value.status == 200 && Arrays.equals(value.body, expected),
                            "JS proxyUrl " + mode + " retains exact byte window");
                }
                check(
                        fetch(runtime.play(js, "flag"), "GET").status == 502,
                        "typed bytes cannot hide invalid encoding flag");
                check(
                        fetch(runtime.play(js, "headers"), "GET").status == 502,
                        "typed bytes cannot hide invalid headers");
                Response manifest = fetch(runtime.play(py, "text"), "GET");
                String text = new String(manifest.body, StandardCharsets.UTF_8);
                check(text.startsWith("#EXTM3U\n# 名称\n"), "Python UTF-8 playlist preserved");
                check(
                        Arrays.equals(
                                fetch(
                                                text.trim()
                                                        .substring(
                                                                text.trim().lastIndexOf('\n') + 1),
                                                "GET")
                                        .body,
                                expected),
                        "playlist child uses same authenticated local callback");
                Response range = fetch(runtime.play(py, "range"), "GET", "Range", "bytes=1-2");
                check(
                        range.status == 206
                                && Arrays.equals(range.body, new byte[] {(byte) 255, (byte) 128})
                                && "2".equals(range.headers.get("Content-Length")),
                        "single Range keeps actual bytes and replaces false Content-Length");
                check(
                        "True".equals(range.headers.get("X-Range-OK"))
                                && "bytes 1-2/4".equals(range.headers.get("Content-Range")),
                        "Range request and response headers retained");
                check(
                        fetch(runtime.play(py, "bad-range"), "GET").status == 502,
                        "inconsistent script Content-Range rejected before response");
                check(
                        fetch(runtime.play(py, "bad-total"), "GET").status == 502,
                        "script range cannot exceed total size");
                Response head = fetch(pythonUrl, "HEAD");
                check(
                        head.status == 200
                                && head.body.length == 0
                                && "4".equals(head.headers.get("Content-Length")),
                        "HEAD retains byte length without sending body");
                check(
                        "321"
                                .equals(
                                        fetch(runtime.play(py, "head-only"), "HEAD")
                                                .headers
                                                .get("Content-Length")),
                        "metadata-only HEAD preserves bounded declared length");
                check(
                        "2"
                                .equals(
                                        fetch(runtime.play(py, "head-range"), "HEAD")
                                                .headers
                                                .get("Content-Length")),
                        "metadata-only partial HEAD derives range length");
                Response hop = fetch(runtime.play(py, "hop"), "GET");
                check(
                        "keep".equals(hop.headers.get("X-Keep"))
                                && !hop.headers.containsKey("X-Private")
                                && !hop.headers.containsKey("Set-Cookie")
                                && !hop.headers.containsKey("Access-Control-Allow-Origin"),
                        "hop headers and cross-source cookies do not escape callback");
                check(
                        fetch(pythonUrl.replace(server.token, "wrong"), "GET").status == 403,
                        "wrong session token rejected");
                check(
                        fetch(pythonUrl.replace("&_mm_token=" + server.token, ""), "GET").status
                                == 403,
                        "missing script token rejected");
                check(
                        fetch(pythonUrl + "&siteKey=" + js, "GET").status == 400,
                        "duplicate routing key rejected");
                check(fetch(pythonUrl, "POST").status == 404, "non GET/HEAD refused");
                check(
                        rawStatus(pythonUrl, "Origin", "https://example.invalid") == 403,
                        "browser cross-origin request rejected");
                check(
                        rawStatus(pythonUrl, "Host", "example.invalid") == 403,
                        "non-loopback Host rejected");
                check(
                        rawStatus(pythonUrl, "Sec-Fetch-Site", "cross-site") == 403,
                        "cross-site browser fetch rejected");
                active.remove(py);
                check(
                        fetch(pythonUrl, "GET").status == 502,
                        "revoked source cannot receive later callbacks");
                check(
                        fetch(jsUrl, "GET").status == 200,
                        "revoking one source preserves other source");
                active.add(py);
                ExecutorService client = Executors.newSingleThreadExecutor();
                try {
                    Future<?> pending =
                            client.submit(
                                    () -> {
                                        try {
                                            fetch(
                                                    pythonUrl.replace("mode=bytes", "mode=hold"),
                                                    "GET");
                                        } catch (Exception expectedClose) {
                                        }
                                    });
                    check(
                            entered.await(3, TimeUnit.SECONDS),
                            "active callback entered before close");
                    server.close();
                    check(
                            cancelled.await(3, TimeUnit.SECONDS),
                            "server close cancels callback request scope");
                    pending.get(3, TimeUnit.SECONDS);
                    check(
                            server.server.isClosed(),
                            "server close terminates active socket and listener");
                } finally {
                    client.shutdownNow();
                }
            } finally {
                server.close();
            }
        }
        System.out.println(
                "OK "
                        + checks
                        + " script proxy checks; real JVM sockets and shared Node helper, no Android JNI/device playback implied");
    }
}
