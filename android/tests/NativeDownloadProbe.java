package com.pilipala.marcomovie;

import android.content.Context;
import com.sun.net.httpserver.HttpServer;
import java.io.File;
import java.net.InetSocketAddress;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONObject;

public final class NativeDownloadProbe {
    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        root.mkdirs();
        Context context =
                new Context() {
                    public Context getApplicationContext() {
                        return this;
                    }

                    public File getFilesDir() {
                        return root;
                    }

                    public File getExternalFilesDir(String type) {
                        return new File(root, type);
                    }
                };
        HttpServer origin = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer media = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        Map<String, Map<String, String>> received = new ConcurrentHashMap<>();
        java.util.concurrent.atomic.AtomicBoolean sameOriginAuthenticated =
                new java.util.concurrent.atomic.AtomicBoolean();
        final String destination = "http://127.0.0.1:" + media.getAddress().getPort();
        media.createContext(
                "/",
                exchange -> {
                    Map<String, String> headers = new LinkedHashMap<>();
                    for (String name : new String[] {"Authorization", "Cookie"}) {
                        String value = exchange.getRequestHeaders().getFirst(name);
                        if (value != null) headers.put(name, value);
                    }
                    received.put(exchange.getRequestURI().getPath(), headers);
                    byte[] bytes = "fixture media".getBytes("UTF-8");
                    exchange.getResponseHeaders().set("Content-Type", "video/mp4");
                    exchange.sendResponseHeaders(200, bytes.length);
                    exchange.getResponseBody().write(bytes);
                    exchange.close();
                });
        origin.createContext(
                "/redirect.mp4",
                exchange -> {
                    sameOriginAuthenticated.set(
                            "Bearer review-fixture-only"
                                    .equals(
                                            exchange.getRequestHeaders()
                                                    .getFirst("Authorization")));
                    exchange.getResponseHeaders()
                            .set("Location", destination + "/redirect-target.mp4");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });
        DownloadManager manager = DownloadManager.get(context);
        try {
            origin.start();
            media.start();
            Cms.Site source = new Cms.Site();
            source.key = "fixture-source";
            source.name = "fixture";
            source.type = 1;
            source.api = "http://127.0.0.1:" + origin.getAddress().getPort() + "/api";
            source.headers.put("Authorization", "Bearer review-fixture-only");
            source.headers.put("Cookie", "session=review-fixture-only");
            Cms.Video video = new Cms.Video();
            video.id = "fixture-video";
            video.title = "Fixture";
            Cms.Line line = new Cms.Line();
            line.name = "fixture-line";
            Cms.Episode direct = new Cms.Episode();
            direct.name = "direct";
            direct.url = destination + "/direct.mp4";
            Cms.Episode redirected = new Cms.Episode();
            redirected.name = "redirect";
            redirected.url = "http://127.0.0.1:" + origin.getAddress().getPort() + "/redirect.mp4";
            manager.enqueue(source, video, line, Arrays.asList(direct, redirected));
            long deadline = System.currentTimeMillis() + 10000;
            while (System.currentTimeMillis() < deadline) {
                boolean active = false;
                for (DownloadManager.Task t : manager.snapshot())
                    if (t.state == DownloadManager.RUNNING || t.state == DownloadManager.WAITING)
                        active = true;
                if (!active) break;
                Thread.sleep(20);
            }
            for (DownloadManager.Task t : manager.snapshot())
                if (t.state != DownloadManager.DONE)
                    throw new AssertionError("Fixture download failed: " + t.error);
            System.out.println(
                    new JSONObject()
                            .put("probe", "native-download-origins")
                            .put("completedTasks", manager.snapshot().size())
                            .put("received", received));
            if (!sameOriginAuthenticated.get())
                throw new AssertionError("Same-origin authorization must remain available");
            if (received.size() != 2)
                throw new AssertionError("Fixture did not receive both downloads");
            for (Map<String, String> headers : received.values())
                if (!headers.isEmpty())
                    throw new AssertionError("Source credentials reached a different media origin");
        } finally {
            origin.stop(0);
            media.stop(0);
            manager.pool.shutdownNow();
            manager.saver.shutdown();
            manager.saver.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS);
        }
    }
}
