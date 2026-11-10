package com.pilipala.marcomovie;

import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Short-lived, token-scoped LAN configuration receiver; separate from playback proxy. */
final class ConfigTransferServer implements Closeable {
    interface Importer {
        void apply(String address) throws Exception;
    }

    final ServerSocket socket;
    final String path;
    final long expires;
    final Importer importer;
    volatile boolean closed;
    final AtomicBoolean importing = new AtomicBoolean(), applied = new AtomicBoolean();
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    2,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-config-request");
                        t.setDaemon(true);
                        return t;
                    });

    ConfigTransferServer(Importer handler) throws IOException {
        this(handler, TimeUnit.MINUTES.toMillis(5), new InetSocketAddress("0.0.0.0", 0));
    }

    ConfigTransferServer(Importer handler, long ttl, InetSocketAddress bind) throws IOException {
        importer = handler;
        expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttl);
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder key = new StringBuilder();
        for (byte b : bytes) key.append(String.format(Locale.ROOT, "%02x", b & 255));
        path = "/configure/" + key;
        socket = new ServerSocket();
        socket.bind(bind);
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed)
                                try {
                                    Socket client = socket.accept();
                                    try {
                                        requests.execute(() -> serve(client));
                                    } catch (RejectedExecutionException full) {
                                        client.close();
                                    }
                                } catch (IOException error) {
                                    if (!closed) close();
                                }
                        },
                        "movie-config-listener");
        accept.setDaemon(true);
        accept.start();
    }

    String address(String host) {
        return "http://" + host + ":" + socket.getLocalPort() + path;
    }

    boolean expired() {
        return closed || System.nanoTime() >= expires;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(15000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!peer.isSiteLocalAddress() && !peer.isLoopbackAddress()) {
                reply(out, 403, "text/plain", "仅允许局域网连接");
                return;
            }
            String[] first = line(in, 4096).split(" ");
            if (first.length != 3) return;
            Map<String, String> headers = new HashMap<>();
            int total = 0;
            for (; ; ) {
                String row = line(in, 4096);
                total += row.length();
                if (total > 16384) throw new IOException("Header limit");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0)
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            row.substring(colon + 1).trim());
            }
            if (!first[1].equals(path)) {
                reply(out, 404, "text/plain", "页面不存在");
                return;
            }
            if (expired()) {
                reply(out, 410, "text/plain", "二维码已过期，请在电视上重新打开");
                return;
            }
            String host = headers.containsKey("host") ? headers.get("host") : "";
            String expected = s.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            if (!host.equals(expected)) {
                reply(out, 403, "text/plain", "请使用电视上的二维码地址");
                return;
            }
            if (first[0].equals("GET")) {
                reply(out, 200, "text/html", page(""));
                return;
            }
            if (!first[0].equals("POST")) {
                reply(out, 405, "text/plain", "请求方式不支持");
                return;
            }
            String origin = headers.get("origin");
            if (origin != null && !origin.equals("http://" + host)) {
                reply(out, 403, "text/plain", "页面来源不匹配");
                return;
            }
            String contentType =
                    headers.containsKey("content-type") ? headers.get("content-type") : "";
            if (!contentType.startsWith("application/x-www-form-urlencoded")
                    || headers.containsKey("transfer-encoding")) {
                reply(out, 415, "text/plain", "请使用配置页面提交");
                return;
            }
            int length;
            try {
                String lenVal =
                        headers.containsKey("content-length")
                                ? headers.get("content-length")
                                : "-1";
                length = Integer.parseInt(lenVal);
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 0 || length > 32768) {
                reply(out, 413, "text/plain", "地址过长");
                return;
            }
            byte[] body = new byte[length];
            for (int n = 0; n < length; ) {
                int got = in.read(body, n, length - n);
                if (got < 0) throw new EOFException();
                n += got;
            }
            String address = "";
            for (String pair : new String(body, "UTF-8").split("&")) {
                String[] p = pair.split("=", 2);
                if (URLDecoder.decode(p[0], "UTF-8").equals("address") && p.length == 2)
                    address = URLDecoder.decode(p[1], "UTF-8").trim();
            }
            try {
                URL url = new URL(address);
                if (address.length() > 8192
                        || (!url.getProtocol().equals("http") && !url.getProtocol().equals("https"))
                        || address.indexOf('\r') >= 0
                        || address.indexOf('\n') >= 0) throw new IOException();
            } catch (Exception bad) {
                reply(out, 400, "text/html", page("请输入有效的 HTTP 或 HTTPS 配置地址"));
                return;
            }
            if (applied.get()) {
                reply(out, 409, "text/html", page("电视已完成导入，请关闭此页面"));
                return;
            }
            if (!importing.compareAndSet(false, true)) {
                reply(out, 409, "text/html", page("正在导入，请稍候查看电视"));
                return;
            }
            try {
                if (applied.get()) {
                    reply(out, 409, "text/html", page("电视已完成导入，请关闭此页面"));
                    return;
                }
                if (expired()) throw new IOException();
                importer.apply(address);
                applied.set(true);
                reply(out, 200, "text/html", page("配置已导入电视，可以关闭此页面"));
            } catch (Exception error) {
                reply(out, 400, "text/html", page("导入未完成，请检查配置地址与电视网络后重试"));
            } finally {
                importing.set(false);
            }
        } catch (Exception ignored) {
        }
    }

    static String line(InputStream in, int max) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        for (int c; (c = in.read()) != -1; ) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
            if (b.size() > max) throw new IOException("Line limit");
        }
        return b.toString("ISO-8859-1");
    }

    static void reply(OutputStream out, int code, String type, String text) throws IOException {
        byte[] body = text.getBytes("UTF-8");
        String head =
                "HTTP/1.1 "
                        + code
                        + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'\r\nContent-Type: "
                        + type
                        + "; charset=utf-8\r\nContent-Length: "
                        + body.length
                        + "\r\n\r\n";
        out.write(head.getBytes("US-ASCII"));
        out.write(body);
        out.flush();
    }

    static String page(String note) {
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Marco Movie 配置</title><style>body{margin:0;background:#101013;color:#f5f5f7;font:17px system-ui;padding:28px}main{max-width:520px;margin:8vh auto}h1{font-size:30px}p{line-height:1.7;color:#bfbfc7}input,button{box-sizing:border-box;width:100%;border:0;border-radius:18px;padding:18px;font:inherit;margin:10px 0}input{background:#292930;color:white}button{background:#f5f5f7;color:#101013;font-weight:600}.note{color:#d8e8ff}</style><main><h1>Marco Movie</h1><p>将你自行获取的配置地址粘贴到下方，导入到同一网络中的电视。请保持电视配置页面打开。</p><p class=note>"
                + note
                + "</p><form method=post accept-charset=UTF-8><input name=address type=url required maxlength=8192 autocomplete=off autocapitalize=off spellcheck=false placeholder='粘贴配置地址'><button>导入到电视</button></form><p>本产品仅为工具，不内置影视资源。此页面只在本次扫码配置期间可用。</p></main></html>";
    }

    public void close() {
        closed = true;
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        requests.shutdownNow();
    }
}
