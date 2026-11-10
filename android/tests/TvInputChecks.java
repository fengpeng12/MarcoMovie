package com.pilipala.marcomovie;

import java.net.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class TvInputChecks {
    static int checks;

    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static int call(String url, String method, String value, String origin) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(3000);
        c.setReadTimeout(5000);
        c.setRequestMethod(method);
        if (origin != null) c.setRequestProperty("Origin", origin);
        if (value != null) {
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            byte[] b = ("address=" + URLEncoder.encode(value, "UTF-8")).getBytes("UTF-8");
            c.setFixedLengthStreamingMode(b.length);
            try (OutputStream out = c.getOutputStream()) {
                out.write(b);
            }
        }
        try {
            return c.getResponseCode();
        } finally {
            c.disconnect();
        }
    }

    public static void main(String[] args) throws Exception {
        AtomicInteger imported = new AtomicInteger();
        try (ConfigTransferServer server =
                new ConfigTransferServer(a -> imported.incrementAndGet())) {
            String url = server.address("127.0.0.1");
            HttpURLConnection page = (HttpURLConnection) new URL(url).openConnection();
            check(
                    "same-origin".equals(page.getHeaderField("Referrer-Policy")),
                    "browser form keeps same-origin Origin");
            page.disconnect();
            check(
                    call(url, "POST", "https://fixture.test/config", "null") == 403,
                    "opaque foreign browser origin rejected");
            check(server.path.matches("/configure/[a-f0-9]{32}"), "unpredictable session path");
            check(call(url, "GET", null, null) == 200, "phone page available");
            check(call(url + "wrong", "GET", null, null) == 404, "wrong token rejected");
            check(call(url, "PUT", null, null) == 405, "unsupported method rejected");
            check(
                    call(url, "POST", "file:///private/config", null) == 400,
                    "non HTTP configuration rejected");
            check(imported.get() == 0, "invalid input does not import");
            check(
                    call(url, "POST", "https://fixture.test/config", "http://other.test") == 403,
                    "foreign browser origin rejected");
            try (Socket client = new Socket("127.0.0.1", server.socket.getLocalPort())) {
                client.setSoTimeout(3000);
                client.getOutputStream()
                        .write(
                                ("GET " + server.path + " HTTP/1.1\r\nHost: other.test\r\n\r\n")
                                        .getBytes("US-ASCII"));
                check(
                        ConfigTransferServer.line(client.getInputStream(), 4096).contains("403"),
                        "foreign Host rejected");
            }
            check(
                    call(
                                    url,
                                    "POST",
                                    "https://fixture.test/config",
                                    new URL(url).getProtocol()
                                            + "://"
                                            + new URL(url).getAuthority())
                            == 200,
                    "valid same-origin browser submission applied");
            check(imported.get() == 1, "one import callback");
            check(
                    call(url, "POST", "https://fixture.test/config", null) == 409,
                    "duplicate successful submission rejected");
        }
        try (ConfigTransferServer expired =
                new ConfigTransferServer(
                        a -> {
                            throw new AssertionError();
                        },
                        20,
                        new InetSocketAddress("127.0.0.1", 0))) {
            Thread.sleep(50);
            check(
                    call(expired.address("127.0.0.1"), "GET", null, null) == 410,
                    "expired session rejected");
        }
        ConfigTransferServer stopped = new ConfigTransferServer(a -> {});
        String old = stopped.address("127.0.0.1");
        stopped.close();
        boolean refused = false;
        try {
            call(old, "GET", null, null);
        } catch (IOException expected) {
            refused = true;
        }
        check(refused, "closed session stops listening");
        try (ConfigTransferServer retry =
                new ConfigTransferServer(
                        a -> {
                            throw new IOException();
                        })) {
            String url = retry.address("127.0.0.1");
            check(
                    call(url, "POST", "https://fixture.test/config", null) == 400
                            && !retry.applied.get(),
                    "failed import remains retryable");
        }
        LiveCatalog.Source source = new LiveCatalog.Source();
        LiveCatalog.Catalog catalog = new LiveCatalog.Catalog();
        for (int g = 0; g < 2; g++) {
            LiveCatalog.Group group = new LiveCatalog.Group();
            for (int n = 0; n < 6; n++) {
                LiveCatalog.Channel ch = new LiveCatalog.Channel();
                ch.name = "样本 " + (g * 6 + n + 1);
                LiveCatalog.Stream stream = new LiveCatalog.Stream();
                stream.url = "https://fixture.test/live";
                ch.streams.add(stream);
                group.channels.add(ch);
            }
            catalog.groups.add(group);
        }
        LiveSession live = new LiveSession(source, catalog);
        check(live.channels.size() == 12, "all groups share channel numbering");
        check(live.step(1) == 0, "no selection starts at first channel");
        live.index = 5;
        check(live.step(1) == 6, "step crosses group boundary");
        live.index = 0;
        check(live.step(-1) == 11, "previous wraps to last");
        live.index = 11;
        check(live.step(1) == 0, "next wraps to first");
        live.digit(1);
        live.digit(2);
        check(live.selectedNumber() == 11, "multi digit number selects channel 12");
        live.clear();
        check(live.digits.isEmpty(), "number input clears");
        live.digit(0);
        check(live.selectedNumber() == -1, "zero is not a channel");
        live.clear();
        live.digit(9);
        live.digit(9);
        check(live.selectedNumber() == -1, "out of range channel rejected");
        live.digit(1);
        check(live.selectedNumber() == 0, "fresh number after maximum digits");
        check(!live.digit(10), "non digit rejected");
        System.out.println("OK " + checks + " phone configuration and live input checks");
    }
}
