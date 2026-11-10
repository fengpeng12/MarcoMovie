package com.github.catvod.spider;

/** Independent fixture for the liveContent host ABI, with no network requests. */
public final class LiveFixture extends com.github.catvod.crawler.Spider {
    private String extension;
    private int calls;

    public void init(android.content.Context context, String ext) {
        extension = ext;
    }

    public String liveContent(String url) throws Exception {
        if (!"local-extension".equals(extension)) throw new Exception("extension lost");
        calls++;
        if ("live:json".equals(url))
            return "[{\"name\":\"JAR\",\"channels\":[{\"name\":\"JSON\",\"url\":\"https://fixture.invalid/live.m3u8\"}]}]";
        if (!"live:txt".equals(url)) throw new Exception("input changed");
        return "JAR,#genre#\nChannel" + calls + ",https://fixture.invalid/live.m3u8";
    }
}
