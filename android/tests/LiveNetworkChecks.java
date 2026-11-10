package com.pilipala.marcomovie;

import java.util.concurrent.*;

/** Real HTTP checks for source switching and credential handling on redirects. */
public final class LiveNetworkChecks {
    public static void main(String[] args) throws Exception {
        LiveCatalog.Source source = new LiveCatalog.Source();
        source.url = args[0] + "cross";
        source.headers.put("authorization", "test-auth");
        source.headers.put("cOoKiE", "test-cookie");
        LiveCatalog.Catalog cross = LiveCatalog.load(source);
        if (cross.channelCount() != 1) throw new AssertionError("redirect");
        for (String name : cross.groups.get(0).channels.get(0).streams.get(0).headers.keySet()) {
            if (name.equalsIgnoreCase("Authorization") || name.equalsIgnoreCase("Cookie"))
                throw new AssertionError("removed credentials restored into redirected stream");
        }
        if (!source.headers.containsKey("authorization") || !source.headers.containsKey("cOoKiE"))
            throw new AssertionError("loading mutated source credentials");
        System.out.println("PASS cross-origin redirect removes mixed-case credentials");
        System.out.println(
                "PASS redirected stream does not restore credentials removed from request");
        source.url = args[0] + "list.php";
        LiveCatalog.Catalog utf16 = LiveCatalog.load(source);
        LiveCatalog.Channel channel = utf16.groups.get(0).channels.get(0);
        if (!channel.name.equals("中文频道")
                || !channel.streams.get(0).url.equals(args[0] + "media/video.m3u8"))
            throw new AssertionError("PHP UTF16 playlist or relative stream decode failed");
        System.out.println("PASS PHP endpoint with UTF16 BOM playlist and relative media");
        if (!channel.streams.get(0).headers.equals(source.headers))
            throw new AssertionError("same-origin playlist lost credentials");
        System.out.println("PASS same-origin stream retains explicit source credentials");
        String url = args[0] + "list.php?token=+/?value";
        for (String ext :
                new String[] {
                    java.util.Base64.getEncoder().encodeToString(url.getBytes("UTF-8")),
                    java.util.Base64.getUrlEncoder()
                            .withoutPadding()
                            .encodeToString(url.getBytes("UTF-8")),
                    java.net.URLEncoder.encode(url, "UTF-8")
                }) {
            for (String prefix : new String[] {"proxy://", "http://127.0.0.1:9978/proxy?"}) {
                LiveCatalog.Source wrapped = new LiveCatalog.Source();
                wrapped.url = prefix + "do=live&type=txt&ext=" + ext;
                wrapped.origin = args[0] + "config.json";
                wrapped.headers.put("Origin", "https://origin.test");
                LiveCatalog.Catalog loaded = LiveCatalog.load(wrapped);
                if (loaded.channelCount() != 1
                        || !loaded.origin.equals(url)
                        || !loaded.groups.get(0).channels.get(0).name.equals("中文频道"))
                    throw new AssertionError(
                            "wrapped catalogue did not load or changed literal plus");
                System.out.println(
                        "PASS encoded TVBox directory loads through production HTTP reader");
            }
        }
        LiveCatalog.Source relative = new LiveCatalog.Source();
        relative.url = "proxy://do=live&type=txt&ext=Li9saXN0LnBocA==";
        relative.origin = args[0] + "config.json";
        if (!LiveCatalog.load(relative).origin.equals(args[0] + "list.php"))
            throw new AssertionError("relative wrapped catalogue lost subscription origin");
        System.out.println("PASS relative directory resolves against subscription origin");
        source.url = args[0] + "slow";
        ExecutorService executor = Executors.newSingleThreadExecutor();
        RequestScope scope = new RequestScope();
        CountDownLatch done = new CountDownLatch(1);
        try {
            executor.submit(
                    () -> {
                        try {
                            scope.call(() -> LiveCatalog.load(source));
                        } catch (Exception expected) {
                        } finally {
                            done.countDown();
                        }
                    });
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while (scope.connections.isEmpty() && System.nanoTime() < deadline) Thread.sleep(10);
            if (scope.connections.isEmpty()) throw new AssertionError("socket not registered");
            scope.cancel();
            if (!done.await(3, TimeUnit.SECONDS))
                throw new AssertionError("cancel did not close request");
            System.out.println("PASS source switch closes in-flight live connection");
        } finally {
            executor.shutdownNow();
        }
    }
}
