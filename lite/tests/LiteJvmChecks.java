// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.GZIPOutputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONArray;
import org.json.JSONObject;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

public final class LiteJvmChecks {
    private static int checks = 0;

    private static void check(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError("Check failed: " + label);
        }
        checks++;
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (int i = 0; i < bytes.length; i++) {
            String h = Integer.toHexString(bytes[i] & 0xff);
            if (h.length() == 1) sb.append('0');
            sb.append(h);
        }
        return sb.toString();
    }

    private static String readHttp(String urlStr, String rangeHeader) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        if (rangeHeader != null) conn.setRequestProperty("Range", rangeHeader);
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        int code = conn.getResponseCode();
        InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (in != null) {
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            in.close();
        }
        conn.disconnect();
        return code + ":" + new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        testConfigDecodingAndSites();
        testXmlAndJsonCmsParsing();
        testLiveParsing();
        testStoreJsonPersistence();
        testEpisodeGroupingAndPlayerHelpers();
        testMediaProxyLoopback();
        System.out.println("PASS " + checks + " TV Lite JVM checks");
    }

    private static void testConfigDecodingAndSites() throws Exception {
        String rawJson = "{\"sites\":["
            + "{\"key\":\"json_cms\",\"name\":\"JSON源\",\"type\":1,\"api\":\"http://127.0.0.1:9/api.php/provide/vod/\",\"ua\":\"CustomUA/1.0\",\"ext\":{\"headers\":{\"Referer\":\"http://ref.example/\"}}},"
            + "{\"key\":\"xml_cms\",\"name\":\"XML源\",\"type\":0,\"api\":\"http://127.0.0.1:9/api.php/provide/vod/at/xml/\"}"
            + "],\"lives\":[{\"name\":\"测试直播\",\"url\":\"http://127.0.0.1:9/live.txt\",\"ua\":\"LiveUA/2.0\"}]}";

        // 1. Plain JSON config
        List<LiteCatalog.Site> plainSites = LiteCatalog.parse(rawJson, "http://127.0.0.1:9/config.json");
        check(plainSites.size() == 2, "plain config sites count");
        check(plainSites.get(0).supported && plainSites.get(0).type == 1, "type 1 JSON CMS supported");
        check("CustomUA/1.0".equals(plainSites.get(0).headers.get("User-Agent")), "site custom UA extracted");
        check("http://ref.example/".equals(plainSites.get(0).headers.get("Referer")), "site ext.headers extracted");
        check(plainSites.get(1).supported && plainSites.get(1).type == 0, "type 0 XML CMS supported");

        // 2. GZIP compressed config
        ByteArrayOutputStream gzBuffer = new ByteArrayOutputStream();
        GZIPOutputStream gz = new GZIPOutputStream(gzBuffer);
        gz.write(rawJson.getBytes(StandardCharsets.UTF_8));
        gz.close();
        String decodedGzip = LiteCatalog.decodeText(gzBuffer.toByteArray());
        check(LiteCatalog.parse(decodedGzip, "http://127.0.0.1:9/config.gz").size() == 2, "GZIP config decoded");

        // 3. '**' Base64 config
        String b64Config = "prefix**" + java.util.Base64.getEncoder().encodeToString(rawJson.getBytes(StandardCharsets.UTF_8));
        check(LiteCatalog.parse(b64Config, "http://127.0.0.1:9/config.b64").size() == 2, "** Base64 config decoded");

        // 4. '2423' Hex-AES-128-CBC config (13-byte IV in 26-char hex tail, right-padded with '0' to 16 bytes)
        String keyStr = "mysecretkey12345"; // 16 chars
        String iv13 = "1234567890abc";      // 13 chars -> 26 hex chars
        String iv16 = "1234567890abc000";   // padded to 16 bytes
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(
            Cipher.ENCRYPT_MODE,
            new SecretKeySpec(keyStr.getBytes(StandardCharsets.UTF_8), "AES"),
            new IvParameterSpec(iv16.getBytes(StandardCharsets.UTF_8))
        );
        byte[] encrypted = cipher.doFinal(rawJson.getBytes(StandardCharsets.UTF_8));
        String hexPayload = "2423"
            + toHex(keyStr.getBytes(StandardCharsets.UTF_8))
            + "2324"
            + toHex(encrypted)
            + toHex(iv13.getBytes(StandardCharsets.UTF_8));
        check(LiteCatalog.parse(hexPayload, "http://127.0.0.1:9/config.2423").size() == 2, "2423 Hex-AES config decoded");

        // 5. Live sources extracted from config
        List<LiteCatalog.LiveSource> liveSources = LiteCatalog.parseLives(rawJson, "http://127.0.0.1:9/config.json");
        check(liveSources.size() == 1 && "http://127.0.0.1:9/live.txt".equals(liveSources.get(0).url), "live source parsed");
        check("LiveUA/2.0".equals(liveSources.get(0).headers.get("User-Agent")), "live source UA parsed");
    }

    private static void testXmlAndJsonCmsParsing() throws Exception {
        String xmlList = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<rss version=\"5.1\">"
            + "<class><ty id=\"1\">电影</ty><ty id=\"2\">剧集</ty></class>"
            + "<list page=\"1\" pagecount=\"4\" pagesize=\"20\" recordcount=\"80\">"
            + "<video><id>101</id><name><![CDATA[测试XML电影]]></name><type>电影</type><pic>http://127.0.0.1:9/poster.jpg</pic><note><![CDATA[HD高清]]></note><year>2025</year><area>中国</area></video>"
            + "</list></rss>";

        JSONObject parsedPage = LiteCatalog.parseCmsResponse(xmlList);
        check(parsedPage.optInt("pagecount") == 4, "XML pageCount parsed");
        List<LiteCatalog.Category> cats = LiteCatalog.categories(xmlList);
        check(cats.size() == 2 && "电影".equals(cats.get(0).name), "XML categories parsed");
        JSONArray list = LiteCatalog.list(xmlList);
        check(list.length() == 1 && "101".equals(list.getJSONObject(0).optString("vod_id")), "XML video item id parsed");
        check("测试XML电影".equals(list.getJSONObject(0).optString("vod_name")), "XML CDATA title parsed");
        check("HD高清".equals(list.getJSONObject(0).optString("vod_remarks")), "XML CDATA note parsed");
        check("2025".equals(list.getJSONObject(0).optString("vod_year")) && "中国".equals(list.getJSONObject(0).optString("vod_area")), "XML year and area parsed");

        String xmlDetail = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<rss version=\"5.1\"><list page=\"1\" pagecount=\"1\">"
            + "<video><id>101</id><name><![CDATA[测试XML电影]]></name><pic>http://127.0.0.1:9/poster.jpg</pic>"
            + "<type>电影</type><year>2025</year><area>中国</area><actor><![CDATA[演员A,演员B]]></actor><director><![CDATA[导演X]]></director>"
            + "<des><![CDATA[这是一部用于TV端XML解析验证的影片。]]></des>"
            + "<dl><dd flag=\"m3u8线路\"><![CDATA[第01集$http://127.0.0.1:9/ep1.m3u8#第02集$http://127.0.0.1:9/ep2.m3u8]]></dd>"
            + "<dd flag=\"备用MP4\"><![CDATA[正片$http://127.0.0.1:9/movie.mp4]]></dd></dl>"
            + "</video></list></rss>";

        JSONObject detailItem = LiteCatalog.list(xmlDetail).getJSONObject(0);
        check("101".equals(detailItem.optString("vod_id")) && "测试XML电影".equals(detailItem.optString("vod_name")), "XML detail id and name");
        check("演员A,演员B".equals(detailItem.optString("vod_actor")) && "导演X".equals(detailItem.optString("vod_director")), "XML actor and director");
        check("这是一部用于TV端XML解析验证的影片。".equals(detailItem.optString("vod_content")), "XML synopsis parsed");
        check("m3u8线路$$$备用MP4".equals(detailItem.optString("vod_play_from")), "XML dd flag lines joined with $$$");
        check(detailItem.optString("vod_play_url").contains("ep1.m3u8") && detailItem.optString("vod_play_url").contains("$$$"), "XML dd episode URLs joined with $$$");
    }

    private static void testLiveParsing() throws Exception {
        String txtContent = "央视频道,#genre#\n"
            + "CCTV-1综合,http://127.0.0.1:9/cctv1.m3u8\n"
            + "CCTV-5体育,http://127.0.0.1:9/cctv5.m3u8\n"
            + "卫视频道,#genre#\n"
            + "湖南卫视,http://127.0.0.1:9/hunan.m3u8#http://127.0.0.1:9/hunan_backup.m3u8\n";
        List<LiteCatalog.LiveGroup> txtGroups = LiteCatalog.parseLiveContent(txtContent);
        check(txtGroups.size() == 2, "TXT live groups count");
        check("央视频道".equals(txtGroups.get(0).name) && txtGroups.get(0).channels.size() == 2, "TXT group 1 channels");
        check("卫视频道".equals(txtGroups.get(1).name) && txtGroups.get(1).channels.get(0).urls.size() == 2, "TXT multi-source URLs preserved");

        String m3uContent = "#EXTM3U\n"
            + "#EXTINF:-1 group-title=\"纪录频道\",CCTV-9纪录\n"
            + "#EXTVLCOPT:http-user-agent=M3uPlayer/1.0\n"
            + "http://127.0.0.1:9/cctv9.m3u8\n"
            + "#EXTINF:-1 group-title=\"纪录频道\",探索频道\n"
            + "http://127.0.0.1:9/discovery.m3u8\n";
        List<LiteCatalog.LiveGroup> m3uGroups = LiteCatalog.parseLiveContent(m3uContent);
        check(m3uGroups.size() == 1 && "纪录频道".equals(m3uGroups.get(0).name), "M3U group-title parsed");
        check(m3uGroups.get(0).channels.size() == 2 && "CCTV-9纪录".equals(m3uGroups.get(0).channels.get(0).name), "M3U channels parsed");
        check("M3uPlayer/1.0".equals(m3uGroups.get(0).channels.get(0).headers.get("User-Agent")), "M3U EXTVLCOPT UA header parsed");

        LiteCatalog.LiveSource proxySource = new LiteCatalog.LiveSource();
        proxySource.name = "内置代理直播";
        proxySource.url = "proxy://do=live&type=txt&ext=" + java.util.Base64.getUrlEncoder().encodeToString(txtContent.getBytes(StandardCharsets.UTF_8));
        List<LiteCatalog.LiveGroup> proxyGroups = LiteCatalog.fetchLiveGroups(proxySource);
        check(proxyGroups.size() == 2 && proxyGroups.get(0).channels.size() == 2, "proxy:// base64 live source parsed");
    }

    private static void testStoreJsonPersistence() {
        String historyRaw = "[]";
        LiteStore.HistoryEntry h1 = new LiteStore.HistoryEntry();
        h1.siteKey = "cms1";
        h1.siteName = "CMS一";
        h1.siteApi = "http://127.0.0.1:9/cms1";
        h1.vodId = "v1";
        h1.vodName = "仙逆";
        h1.lineName = "线路A";
        h1.epName = "第12集";
        h1.epUrl = "http://127.0.0.1:9/v1_12.m3u8";
        h1.positionMs = 125000;
        h1.durationMs = 1440000;
        h1.updatedAt = 1000L;

        LiteStore.HistoryEntry h2 = new LiteStore.HistoryEntry();
        h2.siteKey = "cms2";
        h2.siteName = "CMS二";
        h2.siteApi = "http://127.0.0.1:9/cms2";
        h2.vodId = "v2";
        h2.vodName = "凡人修仙传";
        h2.lineName = "线路B";
        h2.epName = "第05集";
        h2.epUrl = "http://127.0.0.1:9/v2_05.m3u8";
        h2.positionMs = 65000;
        h2.durationMs = 1200000;
        h2.updatedAt = 2000L;

        historyRaw = LiteStore.recordHistoryJson(historyRaw, h1);
        historyRaw = LiteStore.recordHistoryJson(historyRaw, h2);
        List<LiteStore.HistoryEntry> history = LiteStore.parseHistoryJson(historyRaw);
        check(history.size() == 2 && "v2".equals(history.get(0).vodId), "history most recent first");

        // Updating v1 moves it to index 0 and deduplicates
        h1.positionMs = 300000;
        h1.updatedAt = 3000L;
        historyRaw = LiteStore.recordHistoryJson(historyRaw, h1);
        history = LiteStore.parseHistoryJson(historyRaw);
        check(history.size() == 2 && "v1".equals(history.get(0).vodId) && history.get(0).positionMs == 300000, "history deduplicated & updated");

        // Favorites JSON
        String favRaw = "[]";
        LiteStore.FavoriteEntry fav = new LiteStore.FavoriteEntry();
        fav.siteKey = "cms1";
        fav.siteName = "CMS一";
        fav.vodId = "v1";
        fav.vodName = "仙逆";
        fav.vodRemarks = "更新至50集";
        fav.addedAt = 3000L;

        check(!LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "initially not favorite");
        favRaw = LiteStore.toggleFavoriteJson(favRaw, fav);
        check(LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "containsFavorite true after add");
        check(LiteStore.parseFavoritesJson(favRaw).size() == 1, "parseFavoritesJson size 1");
        favRaw = LiteStore.toggleFavoriteJson(favRaw, fav);
        check(!LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "containsFavorite false after second toggle");
    }

    private static void testEpisodeGroupingAndPlayerHelpers() {
        // Build 220 episodes to verify no 150-episode hard truncation
        StringBuilder raw = new StringBuilder();
        for (int i = 1; i <= 220; i++) {
            if (i > 1) raw.append('#');
            raw.append("第").append(i).append("集$http://127.0.0.1:9/ep").append(i).append(".m3u8");
        }
        List<LiteActivity.EpisodeItem> episodes = LiteActivity.parseLineEpisodes(raw.toString());
        check(episodes.size() == 220, "all 220 episodes preserved without 150 truncation");
        check("第1集".equals(episodes.get(0).name) && "http://127.0.0.1:9/ep220.m3u8".equals(episodes.get(219).url), "episode names and URLs parsed");

        // Time formatting
        check("02:05".equals(LiteActivity.formatTime(125000)), "formatTime MM:SS");
        check("1:05:00".equals(LiteActivity.formatTime(3900000)), "formatTime H:MM:SS");

        // Aspect ratio calculation
        int[] fit = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 800, 0);
        check(fit[0] == 1920 && fit[1] == 800, "aspect mode 0 fit preserves 2.40:1 letterbox");
        int[] fill = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 800, 1);
        check(fill[0] == 1920 && fill[1] == 1080, "aspect mode 1 fill stretches full container");
        int[] r43 = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 1080, 3);
        check(r43[0] == 1440 && r43[1] == 1080, "aspect mode 3 4:3 pillarboxes to 1440x1080");

        // Long-press seek acceleration
        check(LiteActivity.computeLongPressSeekStepMs(0) == 15000, "seek repeat 0 = 15s");
        check(LiteActivity.computeLongPressSeekStepMs(3) == 25000, "seek repeat 3 = 25s");
        check(LiteActivity.computeLongPressSeekStepMs(7) == 45000, "seek repeat 7 = 45s");
        check(LiteActivity.computeLongPressSeekStepMs(12) == 75000, "seek repeat 12 = 75s");
        check(LiteActivity.computeLongPressSeekStepMs(20) == 120000, "seek repeat 20 = 120s");
    }

    private static void testMediaProxyLoopback() throws Exception {
        final byte[] mp4Bytes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".getBytes(StandardCharsets.UTF_8);
        final String[] lastUa = new String[1];
        final String[] lastRef = new String[1];

        HttpServer upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final int upstreamPort = upstream.getAddress().getPort();
        upstream.createContext("/video.mp4", new HttpHandler() {
            @Override
            public void handle(HttpExchange ex) {
                try {
                    lastUa[0] = ex.getRequestHeaders().getFirst("User-Agent");
                    lastRef[0] = ex.getRequestHeaders().getFirst("Referer");
                    String range = ex.getRequestHeaders().getFirst("Range");
                    int start = 0;
                    int end = mp4Bytes.length - 1;
                    int code = 200;
                    if (range != null && range.startsWith("bytes=")) {
                        String[] parts = range.substring(6).split("-", 2);
                        start = Integer.parseInt(parts[0]);
                        if (parts.length > 1 && !parts[1].isEmpty()) {
                            end = Integer.parseInt(parts[1]);
                        }
                        code = 206;
                        ex.getResponseHeaders().set("Content-Range", "bytes " + start + "-" + end + "/" + mp4Bytes.length);
                    }
                    byte[] slice = Arrays.copyOfRange(mp4Bytes, start, end + 1);
                    ex.getResponseHeaders().set("Content-Type", "video/mp4");
                    ex.getResponseHeaders().set("Accept-Ranges", "bytes");
                    ex.sendResponseHeaders(code, slice.length);
                    OutputStream os = ex.getResponseBody();
                    os.write(slice);
                    os.close();
                } catch (Exception ignored) {
                }
            }
        });
        upstream.createContext("/hls/master.m3u8", new HttpHandler() {
            @Override
            public void handle(HttpExchange ex) {
                try {
                    String m3u8 = "#EXTM3U\n"
                        + "#EXT-X-VERSION:3\n"
                        + "#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\"\n"
                        + "#EXTINF:4.0,\n"
                        + "seg001.ts\n";
                    byte[] body = m3u8.getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "application/vnd.apple.mpegurl");
                    ex.sendResponseHeaders(200, body.length);
                    OutputStream os = ex.getResponseBody();
                    os.write(body);
                    os.close();
                } catch (Exception ignored) {
                }
            }
        });
        upstream.start();

        try {
            Map<String, String> customHeaders = new HashMap<String, String>();
            customHeaders.put("User-Agent", "ProxyTestUA/1.0");
            customHeaders.put("Referer", "http://origin.example/");

            // 1. Proxy URL wrapping in MODE_ALWAYS or HTTPS
            String rawMp4Url = "http://127.0.0.1:" + upstreamPort + "/video.mp4";
            String proxiedMp4 = LiteMediaProxy.wrapIfNeeded(rawMp4Url, customHeaders, LiteMediaProxy.MODE_ALWAYS, false);
            check(proxiedMp4.startsWith("http://127.0.0.1:") && !proxiedMp4.equals(rawMp4Url), "wrapIfNeeded MODE_ALWAYS wraps local URL");
            String autoHttps = LiteMediaProxy.wrapIfNeeded("https://example.invalid/live.m3u8", null, LiteMediaProxy.MODE_AUTO, false);
            check(autoHttps.startsWith("http://127.0.0.1:"), "wrapIfNeeded MODE_AUTO wraps remote HTTPS URL");

            // 2. Invalid token returns 403 Forbidden
            String badTokenUrl = "http://127.0.0.1:" + LiteMediaProxy.get().port() + "/wrong-token/stream.mp4?u=abc";
            check(readHttp(badTokenUrl, null).startsWith("403:"), "proxy rejects wrong token with 403");

            // 3. Byte-range request through proxy forwards Range & custom headers
            String rangeResp = readHttp(proxiedMp4, "bytes=10-15");
            check("206:ABCDEF".equals(rangeResp), "proxy forwards 206 Partial Content byte range");
            check("ProxyTestUA/1.0".equals(lastUa[0]) && "http://origin.example/".equals(lastRef[0]), "proxy injects custom UA and Referer");

            // 4. M3U8 playlist rewriting rewrites relative segments and EXT-X-KEY URI to loopback proxy
            String rawM3u8Url = "http://127.0.0.1:" + upstreamPort + "/hls/master.m3u8";
            String proxiedM3u8 = LiteMediaProxy.get().buildProxyUrl(rawM3u8Url, customHeaders);
            String m3u8Resp = readHttp(proxiedM3u8, null);
            check(m3u8Resp.startsWith("200:"), "proxy serves rewritten M3U8");
            check(m3u8Resp.contains("URI=\"http://127.0.0.1:") && m3u8Resp.contains("/stream.ts?u="), "proxy rewrites EXT-X-KEY URI and relative .ts segment URLs");
        } finally {
            LiteMediaProxy.get().close();
            upstream.stop(0);
        }
    }
}
