package com.pilipala.marcomovie;

import java.nio.file.*;
import java.io.*;
import java.util.*;
import org.json.*;

public final class CompatChecks {
    static int count;

    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        System.out.println("PASS " + label);
        count++;
    }

    public static void main(String[] args) throws Exception {
        Path assets = Paths.get(args[0], "android/src/main/assets/search");
        PhoneticSearchIndex index =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        index.learn("三体");
        index.learn("流浪地球2");
        index.learn("长安十二时辰");
        check(index.expand("st").contains("三体"), "initials match learned real title");
        check(index.expand("santi").contains("三体"), "full pinyin matches same title by default");
        check(index.matches("流浪地球2", "lldq"), "initials prefix supports digits in title");
        check(index.matches("流浪地球2", "liulangdiqiu"), "full pinyin prefix supports title suffix");
        check(index.matches("长安十二时辰", "changanshiershichen"), "polyphonic readings are retained");
        check(index.expand("BATMAN").contains("BATMAN"), "English source query is preserved");
        PhoneticSearchIndex fresh =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        check(fresh.expand("santi").contains("三体"), "full pinyin decoded without learned title");
        check(
                fresh.expand("liulangdiqiu").contains("流浪地球"),
                "phrase decoding joins multiple words");
        check(
                index.expand("三体").equals(Collections.singletonList("三体")),
                "Chinese query is unchanged");
        PhoneticSearchIndex named =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")),
                        Files.newInputStream(assets.resolve("title-phrases.txt")));
        check(
                named.searchTerms("dldl").get(0).equals("斗罗大陆"),
                "fresh initials expand to title without prior browsing");
        check(named.searchTerms("DLDL").contains("DLDL"), "literal acronym is preserved");
        check(
                named.searchTerms("douluodalu").get(0).equals("斗罗大陆"),
                "full pinyin uses same title vocabulary");
        check(
                named.searchTerms("frxxz").contains("凡人修仙传"),
                "other fresh initials use general title vocabulary");
        for (String title : Arrays.asList("斗罗大陆第二季", "斗罗大陆第三季", "斗罗大陆第四季", "斗罗大陆新篇"))
            named.prefer(title);
        check(
                named.searchTerms("dldl").get(0).equals("斗罗大陆"),
                "exact initials outrank recently learned longer titles");
        check(
                named.searchTerms("dldl").size() <= 3
                        && named.searchTerms("dldl")
                                .get(named.searchTerms("dldl").size() - 1)
                                .equals("dldl"),
                "all planned variants and literal fit runner request budget");
        check(named.matches("【动漫】斗罗大陆 第二季", "dldl"), "decorated title is not filtered out");
        check(
                named.searchTerms("未知片名").equals(Collections.singletonList("未知片名")),
                "Chinese input stays unchanged");
        HomeKeyTracker shortcuts = new HomeKeyTracker();
        check(
                !shortcuts.up(100, 0) && !shortcuts.up(300, 0) && shortcuts.up(500, 0),
                "three discrete up taps trigger home shortcut");
        check(!shortcuts.up(600, 1) && !shortcuts.up(700, 2), "held Up does not count as taps");
        shortcuts.reset();
        check(
                !shortcuts.up(100, 0) && !shortcuts.up(1200, 0) && !shortcuts.up(1400, 0),
                "expired tap window resets");
        shortcuts.reset();
        check(!shortcuts.up(1500, 0), "other keys or screen changes reset tap sequence");
        Cms.Site site = new Cms.Site();
        site.headers.put("user-agent", "old");
        Cms.Episode ep = new Cms.Episode();
        ep.name = "episode";
        JSONObject response =
                new JSONObject(
                        "{\"url\":\"https://media.test/movie.mp4\",\"UA\":\"source-agent\",\"header\":{\"Referer\":\"https://catalog.test/\"},\"subt\":[{\"url\":\"subtitle.vtt\",\"name\":\"中文\"}],\"drm\":{\"scheme\":\"widevine\",\"licenseUrl\":\"https://license.test/\"}}");
        Cms.Episode normalized = MediaOptions.episode(site, ep, response);
        check(
                normalized.headers.get("User-Agent").equals("source-agent")
                        && !normalized.headers.containsKey("user-agent"),
                "player UA overrides inherited header case-insensitively");
        check(
                normalized
                        .media
                        .getJSONArray("subtitles")
                        .getJSONObject(0)
                        .getString("url")
                        .equals("https://media.test/subtitle.vtt"),
                "relative source subtitle normalized");
        check(
                normalized.media.getJSONObject("drm").getString("scheme").equals("widevine"),
                "DRM license declaration preserved without bypass");
        check(
                MediaOptions.subtitleMime("x.ASS?token=a", "").equals("text/x-ssa"),
                "external ASS MIME recognized");
        Cms.Episode file = new Cms.Episode();
        file.name = "[7GB] sample HDR.MKV";
        JSONObject relay =
                new JSONObject()
                        .put("url", "http://127.0.0.1:9999/opaque")
                        .put("format", "application/octet-stream");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "original MKV filename does not override opaque relay format");
        relay.put("format", "application/x-mpegURL");
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "declared relay HLS retains Media3 canonical MIME case");
        relay.put("type", 0);
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "numeric source type does not hide declared MIME format");
        relay.put("mimeType", "application/vnd.apple.mpegurl; charset=UTF-8");
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "vendor HLS MIME normalizes with parameters");
        relay.remove("mimeType");
        relay.put("format", "application/octet-stream")
                .put("url", "http://127.0.0.1:9999/stream.m3u8");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "generic source format preserves manifest URL inference");
        relay.put("url", "https://media.test/opaque");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "remote opaque media retains format detection");
        file.name = "第1集";
        relay.put("url", "http://127.0.0.1:9999/opaque");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "unknown local file retains format detection");
        Cms.Video action =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"0000\",\"vod_name\":\"登录\",\"action\":\"LoginShow\"},{\"vod_id\":\"huya_1\",\"vod_tag\":\"folder\"}]}")
                        .videos
                        .get(0);
        check(action.action.equals("LoginShow"), "account action not discarded by CMS parser");
        List<DanmakuData.Comment> comments =
                DanmakuData.parse(
                        "<i><d p=\"1.5,1,25,16711680\">hello</d><d p=\"3,5,25,16777215\"><![CDATA[top & text]]></d></i>");
        check(
                comments.size() == 2
                        && comments.get(0).time == 1500
                        && comments.get(0).color == 0xff0000,
                "Bili XML comment timing and color");
        check(
                comments.get(1).mode == 5 && comments.get(1).text.equals("top & text"),
                "fixed comment mode and CDATA");
        comments = DanmakuData.parse("{\"danmuku\":[[2,1,16777215,\"text\"]]}");
        check(comments.size() == 1 && comments.get(0).time == 2000, "source JSON comments");
        comments =
                DanmakuData.parse(
                        "{\"comments\":[{\"p\":\"4.5,16711680,1,user\",\"m\":\"test\"}]}");
        check(
                comments.get(0).time == 4500 && comments.get(0).color == 0xff0000,
                "Dandan-style comment schema");
        comments =
                DanmakuData.parse(
                        "<i><d p=\"2.0,1,25,16777215\">A & B <3\u0007</d><d p=\"3.0,1,25,16777215\">ok</d></i>");
        check(
                comments.size() == 2 && comments.get(0).text.contains("A & B"),
                "fault-tolerant XML danmaku recovers from unescaped ampersand and control chars");
        comments =
                DanmakuData.parse(
                        "{\"code\":0,\"data\":{\"danmuku\":[[5,1,16777215,\"nested\"]]}}");
        check(
                comments.size() == 1 && comments.get(0).time == 5000,
                "nested data.danmuku JSON schema supported");
        check(
                Cms.isMedia("rtmps://live.example/app/stream")
                        && Cms.isMedia("mmsh://live.example/stream")
                        && Cms.isMedia("proxy://do=live&type=m3u8"),
                "live streaming protocols and proxy scheme recognized as media");
        boolean refused = false;
        try {
            DanmakuData.parse(
                    "<!DOCTYPE i [<!ENTITY x SYSTEM 'file:///private'>]><i><d p=\"0,1,25,1\">&x;</d></i>");
        } catch (IOException expected) {
            refused = true;
        }
        check(refused, "external XML entities rejected");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/proxy?do=a&url=x%2By%3D", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a&url=x%2By%3D"),
                "reserved proxy relocated without altering encoded query");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:-1/proxy?do=a", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a"),
                "unresolved plugin proxy port repaired");
        check(
                ProxyAddress.rewrite("http://localhost:9980/proxy?do=a", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a"),
                "discovery range routes to this application's proxy");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/other", 42123)
                        .equals("http://127.0.0.1:9978/other"),
                "other loopback services left unchanged");
        check(
                ProxyAddress.rewrite("https://media.test:9978/proxy?do=a", 42123)
                        .equals("https://media.test:9978/proxy?do=a"),
                "remote proxy URLs left unchanged");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/proxy?do=a", 42123, "sec123")
                        .equals("http://127.0.0.1:42123/proxy?do=a&_mm_token=sec123"),
                "session token appended when rewriting local proxy URL");
        check(
                ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, "sec123", "sec123", true)
                        && !ProxyAddress.isAllowedRequest(
                                "evil.example:42123", null, null, "sec123", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123",
                                "https://evil.example",
                                null,
                                "sec123",
                                "sec123",
                                false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, "cross-site", "sec123", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, "wrong", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, null, "sec123", true),
                "proxy request guard blocks DNS rebinding, browser CSRF, and bad tokens");
        response.remove("subt");
        response.put("subs", new JSONArray().put(new JSONObject().put("url", "caption.srt")));
        check(
                MediaOptions.episode(site, ep, response)
                        .media
                        .getJSONArray("subtitles")
                        .getJSONObject(0)
                        .getString("url")
                        .endsWith("/caption.srt"),
                "cloud subs alias preserves external captions");
        String history = "[]";
        for (int n = 0; n < 65; n++) {
            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = "source";
            e.id = "id" + n;
            e.title = "Sample";
            e.line = "line";
            e.episode = "episode";
            e.position = 24000;
            e.duration = 120000;
            e.updated = n;
            history = WatchHistory.upsert(history, e);
        }
        List<WatchHistory.Entry> entries = WatchHistory.read(history);
        check(
                entries.size() == 60 && entries.get(0).id.equals("id64"),
                "history keeps latest 60 distinct titles");
        WatchHistory.Entry e = entries.get(12);
        e.position = 45000;
        history = WatchHistory.upsert(history, e);
        entries = WatchHistory.read(history);
        check(
                entries.size() == 60
                        && entries.get(0).id.equals(e.id)
                        && entries.get(0).resume() == 45000,
                "updating a title moves it to front and retains progress");
        check(
                !new JSONObject(history.substring(1, history.indexOf("}") + 1)).has("url"),
                "history does not store expiring playback URL");
        check(
                WatchHistory.read(WatchHistory.remove(history, e.key())).size() == 59,
                "history item removal");
        check(WatchHistory.read("bad JSON").isEmpty(), "invalid history recovers safely");
        e.duration = 120000;
        e.position = 118000;
        check(e.resume() == 0, "finished item restarts from beginning");
        e.duration = 3000;
        e.position = 1200;
        check(e.resume() == 1200, "short clip is not prematurely marked completed");
        e.position = -50;
        history = WatchHistory.upsert("[]", e);
        check(WatchHistory.read(history).get(0).position == 0, "negative history position clamped");
        System.out.println(
                "OK " + count + " compatibility checks; network and playback not implied");
    }
}
