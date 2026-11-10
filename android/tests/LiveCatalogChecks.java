import com.pilipala.marcomovie.LiveCatalog;
import java.nio.file.*;
import java.util.*;
import java.io.*;

public final class LiveCatalogChecks {
    static int count;

    static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
        System.out.println("PASS " + message);
        count++;
    }

    static LiveCatalog.Channel first(LiveCatalog.Catalog c) {
        return c.groups.get(0).channels.get(0);
    }

    public static void main(String[] args) throws Exception {
        pluginCatalogues();
        Map<String, String> inherited = new LinkedHashMap<>();
        String wrapper = "proxy://do=live&type=txt&ext=aHR0cHM6Ly9saXN0LnRlc3QvbGl2ZS50eHQ=";
        List<LiveCatalog.Source> wrapped =
                LiveCatalog.sources(
                        "{\"lives\":[{\"group\":\"频道组\",\"ua\":\"Group-UA\",\"channels\":["
                                + "{\"name\":\"目录\",\"urls\":[\""
                                + wrapper
                                + "\",\"https://video.test/direct.m3u8\"]},"
                                + "{\"name\":\"普通频道\",\"url\":\"https://video.test/other.m3u8\"}]}]}",
                        "https://list.test/config.json");
        check(
                wrapped.size() == 2
                        && wrapped.get(0).url.equals(wrapper)
                        && wrapped.get(0).name.equals("目录")
                        && wrapped.get(0).inline == null,
                "legacy TVBox catalogue wrapper becomes its own selectable source");
        check(
                wrapped.get(0).headers.get("User-Agent").equals("Group-UA")
                        && !wrapped.get(0).isLocalProxy(),
                "directory wrapper inherits headers and does not require a plugin host");
        LiveCatalog.Catalog ordinary = LiveCatalog.load(wrapped.get(1));
        check(
                ordinary.channelCount() == 2
                        && ordinary.streamCount() == 2
                        && ordinary.groups.get(0).name.equals("频道组"),
                "extracting directories preserves ordinary channels and legacy group name");
        List<LiveCatalog.Source> plugin =
                LiveCatalog.sources(
                        "{\"lives\":[{\"name\":\"插件\",\"url\":\"http://127.0.0.1:9978/proxy?do=custom&type=txt&ext=owned\"}]}",
                        "");
        check(plugin.get(0).isLocalProxy(), "custom plugin proxy remains a plugin source");
        plugin.get(0).url = "proxy://do=custom&type=txt&ext=owned";
        check(plugin.get(0).isLocalProxy(), "custom proxy scheme starts the local plugin host");
        for (String other :
                new String[] {
                    "http://127.0.0.1:1234/proxy?do=custom",
                    "http://127.0.0.1:9978/proxy-other?do=custom",
                    "https://list.test/proxy?do=custom"
                }) {
            plugin.get(0).url = other;
            check(!plugin.get(0).isLocalProxy(), "unrelated endpoint does not start a plugin host");
        }
        for (String invalid :
                new String[] {
                    "",
                    "@@@",
                    "Z===",
                    "aHR0cHM6Ly9saXN0LnRlc3Qv&ext=duplicate",
                    "ZmlsZTovLy90bXAvbG9jYWwudHh0",
                    "cHJveHk6Ly9kbz1saXZlJnR5cGU9dHh0"
                }) {
            LiveCatalog.Source source = new LiveCatalog.Source();
            source.url = "proxy://do=live&type=txt&ext=" + invalid;
            source.origin = "https://list.test/config.json";
            boolean rejected = false;
            try {
                LiveCatalog.load(source);
            } catch (IOException expected) {
                rejected = expected.getMessage().contains("ext");
            }
            check(rejected, "invalid, recursive or remote-to-local directory reference rejected");
        }
        List<LiveCatalog.Source> declared =
                LiveCatalog.sources(
                        "{\"lives\":[{\"name\":\"Owned\",\"url\":\"list.php\",\"origin\":\"https://origin.test\"}]}",
                        "https://list.test/config.json");
        check(
                declared.get(0).headers.get("Origin").equals("https://origin.test"),
                "TVBox source origin becomes request header");
        LiveCatalog.Catalog originCatalogue =
                LiveCatalog.parse(
                        "{\"groups\":[{\"name\":\"Owned\",\"origin\":\"https://origin.test\",\"channels\":[{\"name\":\"Test\",\"url\":\"https://video.test/live.m3u8\"}]}]}",
                        "https://list.test/config.json",
                        inherited);
        check(
                first(originCatalogue)
                        .streams
                        .get(0)
                        .headers
                        .get("Origin")
                        .equals("https://origin.test"),
                "TVBox group origin inherited by stream");
        inherited.put("User-Agent", "Source-UA");
        String m3u =
                "\uFEFF#EXTM3U x-tvg-url=\"https://epg.test/e.xml\"\n#EXTINF:-1 tvg-id=\"c1\" tvg-logo=\"../logo.png\" group-title=\"News, World\" http-user-agent=\"Channel-UA\",News, live\n#EXTVLCOPT:http-referrer=https://ref.test/\n#KODIPROP:inputstream.adaptive.manifest_type=hls\n../live/a.m3u8\n#EXTINF:-1 group-title=\"Second\",Other\nhttps://video.test/x.m3u8\n";
        LiveCatalog.Catalog c =
                LiveCatalog.parse(m3u, "https://list.test/lists/index.m3u", inherited);
        LiveCatalog.Channel channel = first(c);
        LiveCatalog.Stream stream = channel.streams.get(0);
        check(
                c.groups.size() == 2 && c.channelCount() == 2,
                "M3U grouping and commas inside metadata");
        check(
                channel.name.equals("News, live") && channel.id.equals("c1"),
                "M3U display name and tvg id");
        check(
                channel.logo.equals("https://list.test/logo.png")
                        && stream.url.equals("https://list.test/live/a.m3u8"),
                "relative image and stream URL resolution");
        check(
                stream.headers.get("User-Agent").equals("Channel-UA")
                        && stream.headers.get("Referer").equals("https://ref.test/"),
                "M3U channel header override and VLC referrer");
        check(
                c.groups
                                .get(1)
                                .channels
                                .get(0)
                                .streams
                                .get(0)
                                .headers
                                .get("User-Agent")
                                .equals("Source-UA")
                        && !c.groups
                                .get(1)
                                .channels
                                .get(0)
                                .streams
                                .get(0)
                                .headers
                                .containsKey("Referer"),
                "per-channel headers do not leak into next channel");
        check(
                stream.options.get("inputstream.adaptive.manifest_type").equals("hls")
                        && c.options.containsKey("x-tvg-url"),
                "preserve player metadata and EPG declaration");
        c =
                LiveCatalog.parse(
                        "新闻,#genre#\n测试,http://stream.test/a#https://backup.test/b\n有片段,http://stream.test/a#keep\n选项,https://stream.test/p|User-Agent=UA%2F1&Referer=https%3A%2F%2Fr.test%2F\n",
                        null, inherited);
        check(
                c.groups.get(0).name.equals("新闻") && first(c).streams.size() == 2,
                "TXT group and alternative stream URLs");
        check(
                c.groups.get(0).channels.get(1).streams.get(0).url.endsWith("#keep"),
                "URL fragment preserved instead of split");
        check(
                c.groups
                        .get(0)
                        .channels
                        .get(2)
                        .streams
                        .get(0)
                        .headers
                        .get("User-Agent")
                        .equals("UA/1"),
                "URL pipe options percent decoded");
        c =
                LiveCatalog.parse(
                        "{\"groups\":[{\"name\":\"电视\",\"ua\":\"Group-UA\",\"channels\":[{\"name\":\"A\",\"urls\":[\"a.m3u8\",{\"name\":\"备用\",\"url\":\"b.m3u8\",\"headers\":{\"Referer\":\"https://r.test/\"}}]}]}]}",
                        "https://list.test/index.json",
                        inherited);
        check(
                c.groups.get(0).name.equals("电视") && first(c).streams.size() == 2,
                "TVBox inline groups and array URLs");
        check(
                first(c).streams.get(1).label.equals("备用")
                        && first(c).streams.get(1).headers.get("User-Agent").equals("Group-UA"),
                "inline alternative metadata and inherited headers");
        check(
                first(c).streams.get(1).headers.get("Referer").equals("https://r.test/"),
                "inline per-stream header");
        boolean failed = false;
        try {
            LiveCatalog.parse("<!doctype html><html>upstream error</html>", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "HTML error response is rejected");
        failed = false;
        try {
            LiveCatalog.parse("#EXTM3U\n#EXTINF:-1,Missing", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "empty M3U never reported as parsed channel");
        failed = false;
        try {
            LiveCatalog.parse(
                    "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "HLS media segments are not mistaken for live channels");
        c = LiveCatalog.parse("A,http://media.test/v?token=x$2", null, inherited);
        check(
                first(c).streams.get(0).url.endsWith("token=x$2"),
                "dollar in URL query remains intact");
        if (args.length > 1) {
            String base = args[1];
            LiveCatalog.Source s = new LiveCatalog.Source();
            s.url = base + "redirect";
            s.timeoutMs = 4000;
            c = LiveCatalog.load(s);
            check(
                    first(c).streams.get(0).url.equals(base + "media/test.m3u8"),
                    "HTTP relative redirect resolves playlist stream against final URL");
            s.url = base + "failure";
            failed = false;
            try {
                LiveCatalog.load(s);
            } catch (IOException e) {
                failed = e.getMessage().contains("503");
            }
            check(failed, "HTTP failure status retained");
            s.url = base + "loop";
            failed = false;
            try {
                LiveCatalog.load(s);
            } catch (IOException e) {
                failed = e.getMessage().contains("重定向");
            }
            check(failed, "redirect loop bounded");
        }
        System.out.println("OK " + count + " live checks");
    }

    static void pluginCatalogues() throws Exception {
        String raw =
                "{\"spider\":\"./global.jar;md5;abc\",\"lives\":["
                        + "{\"name\":\"Same\",\"api\":\"./source.js\",\"ext\":\"../data.json\",\"ua\":\"Live-UA\",\"groups\":[]},"
                        + "{\"name\":\"Same\",\"api\":\"csp_Live\",\"jar\":\"./own.jar\",\"url\":\"opaque-input\",\"ext\":{\"mode\":1}}]}";
        List<LiveCatalog.Source> sources =
                LiveCatalog.sources(raw, "https://list.test/folder/config.json");
        check(
                sources.size() == 2 && sources.get(0).url.isEmpty(),
                "api-only live source retained without a catalogue URL");
        LiveCatalog.Source js = sources.get(0), jar = sources.get(1);
        check(
                js.plugin.api.equals("https://list.test/folder/source.js")
                        && js.plugin.ext.equals("https://list.test/data.json")
                        && js.plugin.jar.equals("https://list.test/folder/global.jar;md5;abc"),
                "live plugin resolves API ext and inherited JAR against subscription");
        check(
                jar.plugin.api.equals("csp_Live")
                        && jar.plugin.jar.equals("https://list.test/folder/own.jar")
                        && jar.plugin.ext instanceof org.json.JSONObject,
                "live plugin keeps explicit JAR and structured extension");
        check(
                !js.plugin.key.equals(jar.plugin.key)
                        && js.plugin.key.startsWith("live-plugin:")
                        && js.plugin.key.equals(
                                LiveCatalog.sources(raw, "https://list.test/folder/config.json")
                                        .get(0)
                                        .plugin
                                        .key),
                "same-name live plugins have stable isolated engine identities");
        LiveCatalog.Catalog catalogue =
                LiveCatalog.load(
                        jar,
                        (site, url) -> {
                            if (site != jar.plugin || !url.equals("opaque-input"))
                                throw new AssertionError("dispatch changed");
                            return "Plugin,#genre#\nLocal,https://media.test/a.m3u8";
                        });
        check(
                catalogue.channelCount() == 1 && catalogue.groups.get(0).name.equals("Plugin"),
                "liveContent text reaches ordinary catalogue reader");
        catalogue =
                LiveCatalog.load(
                        js,
                        (site, url) ->
                                "[{\"name\":\"JSON\",\"channels\":[{\"name\":\"Local\",\"url\":\"https://media.test/a.m3u8\"}]}]");
        check(
                first(catalogue).streams.get(0).headers.get("User-Agent").equals("Live-UA"),
                "liveContent JSON inherits source headers");
        boolean missing = false;
        try {
            LiveCatalog.load(js);
        } catch (IOException error) {
            missing = error.getMessage().contains("引擎");
        }
        check(missing, "plugin catalogue never falls back to downloading its input URL");
        boolean failed = false;
        try {
            LiveCatalog.load(
                    js,
                    (site, url) -> {
                        throw new IOException("fixture-failure");
                    });
        } catch (IOException error) {
            failed = error.getMessage().equals("fixture-failure");
        }
        check(failed, "plugin failure remains visible instead of a blank list");
    }
}
