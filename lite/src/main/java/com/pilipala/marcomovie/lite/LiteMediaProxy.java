// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;
import com.pilipala.source.MediaRequestHeaders;

/**
 * Loopback HTTP media proxy for Android 4.x (API 14+) TVs.
 *
 * <p>Bridges HTTPS supported by the system TLS provider, custom Referer/User-Agent headers, and HLS
 * (.m3u8) segment playlists into a local {@code http://127.0.0.1/} stream consumable by legacy
 * Stagefright {@code MediaPlayer} and {@code IjkMediaPlayer}. Never disables certificate or
 * hostname verification.
 */
public final class LiteMediaProxy {
    public static final int MODE_AUTO = 0;
    public static final int MODE_ALWAYS = 1;
    public static final int MODE_OFF = 2;

    private static LiteMediaProxy instance;
    private final ServerSocket server;
    private final String token = UUID.randomUUID().toString();
    private final ExecutorService pool = Executors.newCachedThreadPool();
    private volatile boolean closed;

    private LiteMediaProxy() throws IOException {
        server = new ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"));
        pool.execute(
                new Runnable() {
                    public void run() {
                        acceptLoop();
                    }
                });
    }

    public static synchronized LiteMediaProxy get() throws IOException {
        if (instance == null || instance.closed) {
            instance = new LiteMediaProxy();
        }
        return instance;
    }

    public int port() {
        return server.getLocalPort();
    }

    public static String wrapIfNeeded(
            String address, Map<String, String> headers, int mode, boolean isIjk) {
        if (address == null || address.length() == 0) return address;
        try {
            String normalized = LiteCatalog.http(address);
            URL u = new URL(normalized);
            String host = u.getHost().toLowerCase(Locale.US);
            boolean isLocal =
                    "127.0.0.1".equals(host) || "localhost".equals(host) || "10.0.2.2".equals(host);
            boolean isHttps = "https".equalsIgnoreCase(u.getProtocol());
            boolean hasCustomHeaders = headers != null && !headers.isEmpty();
            if (mode == MODE_OFF && !(isIjk && isHttps)) {
                return normalized;
            }
            if (mode == MODE_AUTO) {
                if (isLocal && !(isIjk && isHttps)) return normalized;
                if (!isHttps && !hasCustomHeaders) return normalized;
            }
            return get().buildProxyUrl(normalized, headers);
        } catch (Exception ignored) {
            return address;
        }
    }

    public String buildProxyUrl(String targetUrl, Map<String, String> headers) throws Exception {
        String encodedUrl =
                Base64.encodeToString(
                        targetUrl.getBytes("UTF-8"),
                        Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
        String encodedHeaders = "";
        if (headers != null && !headers.isEmpty()) {
            JSONObject obj = new JSONObject();
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey() != null && e.getValue() != null) {
                    obj.put(e.getKey(), e.getValue());
                }
            }
            encodedHeaders =
                    Base64.encodeToString(
                            obj.toString().getBytes("UTF-8"),
                            Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
        }
        String lower = targetUrl.toLowerCase(Locale.US);
        String suffix = "/stream";
        if (lower.contains(".m3u8")) suffix = "/stream.m3u8";
        else if (lower.contains(".mp4")) suffix = "/stream.mp4";
        else if (lower.contains(".ts")) suffix = "/stream.ts";
        return "http://127.0.0.1:"
                + port()
                + "/"
                + token
                + suffix
                + "?u="
                + URLEncoder.encode(encodedUrl, "UTF-8")
                + (encodedHeaders.length() > 0
                        ? "&h=" + URLEncoder.encode(encodedHeaders, "UTF-8")
                        : "");
    }

    private void acceptLoop() {
        while (!closed) {
            try {
                final Socket client = server.accept();
                pool.execute(
                        new Runnable() {
                            public void run() {
                                handleClient(client);
                            }
                        });
            } catch (Exception e) {
                if (closed) break;
            }
        }
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(128);
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') return new String(out.toByteArray(), "US-ASCII").trim();
            if (out.size() >= 8192) throw new IOException("Header line too long");
            out.write(c);
        }
        if (out.size() > 0) return new String(out.toByteArray(), "US-ASCII").trim();
        throw new EOFException();
    }

    private void handleClient(Socket client) {
        try {
            client.setSoTimeout(15000);
            InputStream in = client.getInputStream();
            String requestLine = readLine(in);
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) {
                sendSimpleError(client, 400, "Bad Request");
                return;
            }
            String method = parts[0].toUpperCase(Locale.US);
            String pathAndQuery = parts[1];
            String rangeHeader = null;
            for (int i = 0; i < 48; i++) {
                String h = readLine(in);
                if (h.length() == 0) break;
                int colon = h.indexOf(':');
                if (colon > 0) {
                    String k = h.substring(0, colon).trim().toLowerCase(Locale.US);
                    String v = h.substring(colon + 1).trim();
                    if ("range".equals(k)) rangeHeader = v;
                }
            }
            if (!("GET".equals(method) || "HEAD".equals(method))) {
                sendSimpleError(client, 405, "Method Not Allowed");
                return;
            }
            String prefix = "/" + token + "/";
            if (!pathAndQuery.startsWith(prefix)) {
                sendSimpleError(client, 403, "Forbidden");
                return;
            }
            int qIdx = pathAndQuery.indexOf('?');
            if (qIdx < 0) {
                sendSimpleError(client, 400, "Missing query");
                return;
            }
            String query = pathAndQuery.substring(qIdx + 1);
            String uParam = null, hParam = null;
            for (String kv : query.split("&")) {
                int eq = kv.indexOf('=');
                if (eq > 0) {
                    String k = kv.substring(0, eq);
                    String v = URLDecoder.decode(kv.substring(eq + 1), "UTF-8");
                    if ("u".equals(k)) uParam = v;
                    else if ("h".equals(k)) hParam = v;
                }
            }
            if (uParam == null || uParam.length() == 0) {
                sendSimpleError(client, 400, "Missing url");
                return;
            }
            String targetUrl =
                    LiteCatalog.http(
                            new String(
                                    Base64.decode(
                                            uParam,
                                            Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING),
                                    "UTF-8"));
            Map<String, String> headers = new LinkedHashMap<String, String>();
            if (hParam != null && hParam.length() > 0) {
                JSONObject obj =
                        new JSONObject(
                                new String(
                                        Base64.decode(
                                                hParam,
                                                Base64.URL_SAFE
                                                        | Base64.NO_WRAP
                                                        | Base64.NO_PADDING),
                                        "UTF-8"));
                java.util.Iterator<String> it = obj.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    headers.put(k, obj.optString(k, ""));
                }
            }
            proxyUpstream(client, "HEAD".equals(method), targetUrl, headers, rangeHeader);
        } catch (Exception ignored) {
        } finally {
            try {
                client.close();
            } catch (Exception ignored) {
            }
        }
    }

    private void proxyUpstream(
            Socket client,
            boolean headOnly,
            String targetUrl,
            Map<String, String> headers,
            String rangeHeader)
            throws Exception {
        String current = targetUrl;
        Map<String, String> activeHeaders = headers;
        for (int redirects = 0; redirects < 6; redirects++) {
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            if (c instanceof javax.net.ssl.HttpsURLConnection) {
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            }
            c.setConnectTimeout(10000);
            c.setReadTimeout(15000);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", "MarcoMovie-Lite/0.5");
            c.setRequestProperty("Accept-Encoding", "identity");
            if (activeHeaders != null) {
                for (Map.Entry<String, String> e : activeHeaders.entrySet()) {
                    c.setRequestProperty(e.getKey(), e.getValue());
                }
            }
            if (rangeHeader != null && rangeHeader.length() > 0) {
                c.setRequestProperty("Range", rangeHeader);
            }
            try {
                int status = c.getResponseCode();
                if (status >= 300 && status < 400) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) throw new IOException("Redirect missing Location");
                    String next = LiteCatalog.http(new URL(new URL(current), loc).toString());
                    URL before = new URL(current), after = new URL(next);
                    if ("https".equalsIgnoreCase(before.getProtocol())
                            && "http".equalsIgnoreCase(after.getProtocol())) {
                        throw new IOException("Downgrade redirect rejected");
                    }
                    activeHeaders = MediaRequestHeaders.forTarget(activeHeaders, current, next);
                    current = next;
                    continue;
                }
                if (status < 200 || status >= 300) {
                    sendSimpleError(client, status, "Upstream Error");
                    return;
                }
                String contentType = c.getContentType();
                if (contentType == null || contentType.length() == 0) {
                    contentType = "application/octet-stream";
                }
                boolean isM3u8 =
                        current.toLowerCase(Locale.US).contains(".m3u8")
                                || contentType.toLowerCase(Locale.US).contains("mpegurl");
                OutputStream out = client.getOutputStream();
                if (isM3u8 && rangeHeader == null) {
                    InputStream in = c.getInputStream();
                    ByteArrayOutputStream buf = new ByteArrayOutputStream();
                    byte[] chunk = new byte[8192];
                    int n;
                    while ((n = in.read(chunk)) != -1) {
                        if (buf.size() + n > LiteCatalog.MAX_BYTES) {
                            throw new IOException("M3U8 playlist too large");
                        }
                        buf.write(chunk, 0, n);
                    }
                    String text = new String(buf.toByteArray(), "UTF-8");
                    if (text.trim().startsWith("#EXTM3U")) {
                        String rewritten = rewriteM3u8(text, current, activeHeaders);
                        byte[] payload = rewritten.getBytes("UTF-8");
                        String resp =
                                "HTTP/1.1 200 OK\r\n"
                                        + "Content-Type: application/vnd.apple.mpegurl\r\n"
                                        + "Content-Length: "
                                        + payload.length
                                        + "\r\n"
                                        + "Connection: close\r\n\r\n";
                        out.write(resp.getBytes("US-ASCII"));
                        if (!headOnly) out.write(payload);
                        out.flush();
                        return;
                    }
                    byte[] rawBytes = buf.toByteArray();
                    String resp =
                            "HTTP/1.1 200 OK\r\n"
                                    + "Content-Type: "
                                    + contentType
                                    + "\r\n"
                                    + "Content-Length: "
                                    + rawBytes.length
                                    + "\r\n"
                                    + "Connection: close\r\n\r\n";
                    out.write(resp.getBytes("US-ASCII"));
                    if (!headOnly) out.write(rawBytes);
                    out.flush();
                    return;
                }
                StringBuilder hdr = new StringBuilder();
                hdr.append("HTTP/1.1 ")
                        .append(status == 206 ? "206 Partial Content" : "200 OK")
                        .append("\r\n");
                hdr.append("Content-Type: ").append(contentType).append("\r\n");
                String contentRange = c.getHeaderField("Content-Range");
                if (contentRange != null) {
                    hdr.append("Content-Range: ").append(contentRange).append("\r\n");
                }
                String acceptRanges = c.getHeaderField("Accept-Ranges");
                hdr.append("Accept-Ranges: ")
                        .append(acceptRanges != null ? acceptRanges : "bytes")
                        .append("\r\n");
                int contentLen = c.getContentLength();
                if (contentLen >= 0) {
                    hdr.append("Content-Length: ").append(contentLen).append("\r\n");
                }
                hdr.append("Connection: close\r\n\r\n");
                out.write(hdr.toString().getBytes("US-ASCII"));
                if (!headOnly) {
                    InputStream in = c.getInputStream();
                    byte[] buf = new byte[16384];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        out.write(buf, 0, n);
                    }
                }
                out.flush();
                return;
            } finally {
                c.disconnect();
            }
        }
        sendSimpleError(client, 502, "Too many redirects");
    }

    public String rewriteM3u8(String m3u8Text, String baseUrl, Map<String, String> headers)
            throws Exception {
        StringBuilder out = new StringBuilder(m3u8Text.length() + 512);
        URL base = new URL(baseUrl);
        String[] lines = m3u8Text.split("\r?\n");
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i].trim();
            if (line.length() == 0) continue;
            if (line.startsWith("#")) {
                int uriStart = line.indexOf("URI=\"");
                if (uriStart > 0) {
                    int valStart = uriStart + 5;
                    int valEnd = line.indexOf('"', valStart);
                    if (valEnd > valStart) {
                        String rawUri = line.substring(valStart, valEnd);
                        try {
                            String resolved =
                                    LiteCatalog.http(new URL(base, rawUri).toString());
                            String proxied = childProxyUrl(baseUrl, resolved, headers);
                            line =
                                    line.substring(0, valStart)
                                            + proxied
                                            + line.substring(valEnd);
                        } catch (Exception ignored) {
                        }
                    }
                }
                out.append(line).append('\n');
            } else {
                try {
                    String resolved = LiteCatalog.http(new URL(base, line).toString());
                    out.append(childProxyUrl(baseUrl, resolved, headers)).append('\n');
                } catch (Exception invalid) {
                    out.append(line).append('\n');
                }
            }
        }
        return out.toString();
    }

    private String childProxyUrl(String parent, String child, Map<String, String> headers)
            throws Exception {
        URL before = new URL(parent), after = new URL(child);
        if ("https".equalsIgnoreCase(before.getProtocol())
                && !"https".equalsIgnoreCase(after.getProtocol())) {
            // Keep a blocked local URL so callers cannot fall back to the raw child.
            return buildProxyUrl("http://127.0.0.1:" + port() + "/blocked-downgrade", Collections.<String,String>emptyMap());
        }
        return buildProxyUrl(child, MediaRequestHeaders.forTarget(headers, parent, child));
    }

    private static void sendSimpleError(Socket client, int code, String message)
            throws IOException {
        byte[] body = message.getBytes("UTF-8");
        OutputStream out = client.getOutputStream();
        out.write(
                ("HTTP/1.1 "
                                + code
                                + " "
                                + message
                                + "\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: "
                                + body.length
                                + "\r\n\r\n")
                        .getBytes("US-ASCII"));
        out.write(body);
        out.flush();
    }

    public void close() {
        closed = true;
        try {
            server.close();
        } catch (Exception ignored) {
        }
        pool.shutdownNow();
    }
}
