package com.pilipala.marcomovie;

import java.io.*;
import java.net.URI;
import java.nio.file.Files;
import java.util.zip.*;
import java.nio.charset.StandardCharsets;

public final class LocalPackageChecks {
    private static byte[] zip(String... pairs) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(out)) {
            for (int i = 0; i < pairs.length; i += 2) {
                zip.putNextEntry(new ZipEntry(pairs[i]));
                zip.write(pairs[i + 1].getBytes(StandardCharsets.UTF_8));
                zip.closeEntry();
            }
        }
        return out.toByteArray();
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        String config =
                "{\"sites\":[{\"key\":\"test\",\"type\":3,\"api\":\"./modules/test.mjs\",\"ext\":\"./rules.txt\"}]}";
        byte[] valid =
                zip(
                        "nested/config.json",
                        config,
                        "nested/modules/test.mjs",
                        "export default {}",
                        "nested/rules.txt",
                        "ok");
        LocalSourcePackage imported = LocalSourcePackage.open(root, valid);
        Cms.Site reopened = Cms.parseConfig(imported.config.raw, imported.origin).sites.get(0);
        File module = new File(new URI(reopened.api));
        if (!reopened.api.startsWith("file:///")
                || !module.isFile()
                || !new File(new URI((String) reopened.ext)).isFile())
            throw new AssertionError("packaged resources cannot be reopened");
        for (byte[] invalid :
                new byte[][] {
                    zip("config.json", config),
                    zip("../escape", "bad"),
                    zip("a.json", config, "b.json", config)
                }) {
            try {
                LocalSourcePackage.open(root, invalid);
                throw new AssertionError("invalid package accepted");
            } catch (IOException expected) {
            }
            if (!module.isFile()) throw new AssertionError("previous package was removed");
        }
        if (!LocalSourcePackage.open(root, valid).origin.equals(imported.origin))
            throw new AssertionError("unstable package id");
        LocalSourcePackage py =
                LocalSourcePackage.open(
                        root,
                        zip(
                                "bundle/main.py",
                                "from helper import title\nclass Spider:\n def homeContent(self): return {}",
                                "bundle/helper.py",
                                "title = 'fixture'",
                                "bundle/config.json",
                                "{\"fixture\":true}"));
        if (!py.origin.endsWith("/bundle/main.py")
                || py.config.sites.size() != 1
                || !py.config.sites.get(0).api.equals(py.origin)
                || !new File(new File(new URI(py.origin)).getParentFile(), "helper.py").isFile())
            throw new AssertionError("standalone Python ZIP or helper module missing");
        LocalSourcePackage js =
                LocalSourcePackage.open(
                        root,
                        zip(
                                "bundle/index.js",
                                "module.exports = {home(){return {class:[]}}}",
                                "bundle/helpers.js",
                                "exports.name='fixture';"));
        if (!js.origin.endsWith("/bundle/index.js")
                || !js.config.sites.get(0).api.equals(js.origin))
            throw new AssertionError("standalone CommonJS ZIP not loaded");
        String drpyConfig =
                "{\"sites\":[{\"key\":\"rule\",\"type\":3,\"api\":\"csp_Drpy\",\"ext\":{\"rule\":\"./rules/main.js\"}}]}";
        LocalSourcePackage drpy =
                LocalSourcePackage.open(
                        root,
                        zip(
                                "config.json",
                                drpyConfig,
                                "rules/main.js",
                                "let rule={host:'https://example.test'};"));
        if (!drpy.origin.endsWith("/config.json")
                || !drpy.config.sites.get(0).api.equals("csp_Drpy"))
            throw new AssertionError("explicit DRPY package descriptor lost");
        for (String missing :
                new String[] {
                    drpyConfig,
                    drpyConfig.replace("./rules/main.js", "../outside.js"),
                    drpyConfig.replace("{\"rule\":\"./rules/main.js\"}", "\"missing.js\"")
                }) {
            try {
                LocalSourcePackage.open(root, zip("config.json", missing));
                throw new AssertionError("DRPY package escaped or missing entry accepted");
            } catch (IOException expected) {
            }
        }
        String arrayConfig =
                "[{\"key\":\"configured\",\"name\":\"Configured JS\",\"type\":3,"
                        + "\"api\":\"./main.js\",\"ext\":{\"fixture\":true}}]";
        LocalSourcePackage configuredArray =
                LocalSourcePackage.open(
                        root,
                        zip(
                                "config.json",
                                arrayConfig,
                                "main.js",
                                "module.exports={home(){return {}}}"));
        Cms.Site arraySite = configuredArray.config.sites.get(0);
        Cms.Site arrayReopened =
                Cms.parseConfig(configuredArray.config.raw, configuredArray.origin).sites.get(0);
        if (!configuredArray.origin.endsWith("/config.json")
                || !arraySite.key.equals("configured")
                || !arraySite.api.endsWith("/main.js")
                || !((org.json.JSONObject) arraySite.ext).getBoolean("fixture")
                || !arrayReopened.api.equals(arraySite.api)
                || !((org.json.JSONObject) arrayReopened.ext).getBoolean("fixture"))
            throw new AssertionError("root site array loses configuration or script ext on reopen");
        for (String helper :
                new String[] {
                    "[]",
                    "[\"value\"]",
                    "[{\"title\":\"helper\"}]",
                    "[{\"api\":17}]",
                    "[{\"api\":\"./index.js\"},{\"title\":\"helper\"}]"
                }) {
            LocalSourcePackage helperArray =
                    LocalSourcePackage.open(
                            root,
                            zip(
                                    "config.json",
                                    helper,
                                    "index.js",
                                    "module.exports={home(){return {}}}"));
            if (!helperArray.origin.endsWith("/index.js"))
                throw new AssertionError("helper JSON array incorrectly chosen as subscription");
        }
        LocalSourcePackage live =
                LocalSourcePackage.open(
                        root,
                        zip(
                                "lists/tv.m3u",
                                "#EXTM3U\n#EXTINF:-1 tvg-logo=\"../logo.png\",Local\n../video.mp4\n",
                                "video.mp4",
                                "fixture bytes",
                                "logo.png",
                                "fixture image"));
        LiveCatalog.Source source = new LiveCatalog.Source();
        source.url = live.origin;
        LiveCatalog.Catalog channels = LiveCatalog.load(source);
        if (live.config != null
                || live.liveChannels != 1
                || channels.channelCount() != 1
                || !channels.groups
                        .get(0)
                        .channels
                        .get(0)
                        .streams
                        .get(0)
                        .url
                        .startsWith("file:///"))
            throw new AssertionError("standalone playlist ZIP cannot reopen local media");
        for (byte[] invalid :
                new byte[][] {
                    zip(
                            "a.py",
                            "class Spider:\n def homeContent(self): return {}",
                            "b.py",
                            "class Spider:\n def homeContent(self): return {}"),
                    zip("a/index.js", "export default {}", "b/index.js", "export default {}"),
                    zip("tv.m3u", "#EXTM3U\n#EXTINF:-1,Missing\nmissing.mp4\n"),
                    zip("tv.m3u", "#EXTM3U\n#EXTINF:-1,Outside\n../../secret.mp4\n")
                }) {
            try {
                LocalSourcePackage.open(root, invalid);
                throw new AssertionError("ambiguous or incomplete fallback accepted");
            } catch (IOException expected) {
            }
        }
        String php = "https://example.test/subscription.php?format=raw";
        String embedded =
                "{\"sites\":[{\"type\":3,\"api\":\"source.js\",\"ext\":{\"script\":\"module.exports={};\"}}]}";
        if (Cms.looksLikeJsSpider(embedded, "")
                || Cms.looksLikeJsSpider("<html>module.exports={}</html>", php))
            throw new AssertionError(
                    "JSON config or HTML page incorrectly treated as executable script");
        for (String script :
                new String[] {
                    "module.exports = {home(){return {}}};",
                    "exports.home = function(){return {}};",
                    "exports['home'] = function(){return {}};",
                    "export async function home(){return {}}",
                    "export{home}from'./source.mjs';",
                    "export*from'./source.mjs';"
                }) {
            Cms.Config parsedScript = Cms.parseConfig(script, php);
            if (parsedScript.sites.size() != 1
                    || !parsedScript.sites.get(0).api.equals(php)
                    || !((org.json.JSONObject) parsedScript.sites.get(0).ext)
                            .getString("_mm_entrySource")
                            .equals(script))
                throw new AssertionError("PHP-returned JS entry or verified source was lost");
        }
        String direct = "{\"name\":\"单来源\",\"type\":1,\"api\":\"./api.php\"}";
        for (String encoding : new String[] {"UTF-16LE", "UTF-16BE"}) {
            String decoded = Cms.document(("\ufeff" + direct).getBytes(encoding));
            if (!Cms.parseConfig(decoded, php)
                    .sites
                    .get(0)
                    .api
                    .equals("https://example.test/api.php"))
                throw new AssertionError("UTF16 BOM single-source JSON decode failed");
        }
        System.out.println(
                "PASS JSON/JS/PY/playlist ZIP reopen, helpers and relative resources, missing/outside/ambiguous entry rejection, immutable reimport, content-first PHP and UTF16 JSON");
    }
}
