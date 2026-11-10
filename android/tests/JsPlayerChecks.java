package com.pilipala.marcomovie;

import java.nio.file.*;
import org.json.*;

public final class JsPlayerChecks {
    private static int checks;

    private static void check(boolean pass, String label) {
        if (!pass) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static JSONObject normalize(JSONObject result) throws Exception {
        return new JSONObject(JsEngine.normalizePlayerResult(result.toString()));
    }

    public static void main(String[] args) throws Exception {
        Cms.Site contentScript = new Cms.Site();
        contentScript.type = 3;
        contentScript.api = "https://fixture.invalid/sub.php";
        check(
                !JsEngine.eligible(contentScript),
                "unknown PHP endpoint is not assumed to be JavaScript");
        contentScript.ext =
                new JSONObject()
                        .put("_mm_entrySource", "module.exports={home(){return {list:[]}}}");
        check(
                JsEngine.eligible(contentScript),
                "content-identified JavaScript works from PHP endpoint");
        Cms.Config importedScript =
                Cms.parseConfig(
                        "module.exports={home(){return {list:[]}}}",
                        "https://fixture.invalid/sub.php");
        check(
                JsEngine.eligible(importedScript.sites.get(0)),
                "PHP script import reaches JavaScript host selection");
        check(JsEngine.isEsModule("import'./side.js';"), "compact side-effect import is ESM");
        check(JsEngine.isEsModule("import{home}from'./api.js';"), "compact named import is ESM");
        check(JsEngine.isEsModule("export{home}from'./api.js';"), "compact re-export is ESM");
        check(
                !JsEngine.isEsModule("import('./optional.js');"),
                "dynamic import is not a static declaration");
        check(
                JsEngine.commonJsCandidates("https://fixture.invalid/helper?token=x#part")[1]
                        .equals("https://fixture.invalid/helper.js?token=x#part"),
                "CommonJS suffix is added before query and fragment");
        check(
                JsEngine.commonJsCandidates("https://fixture.invalid/helper.js?token=x").length
                        == 1,
                "explicit CommonJS suffix does not create unrelated fallback requests");
        JSONObject direct =
                new JSONObject(
                        "{\"parse\":1,\"jx\":0,\"url\":\"https://media.example/clip.MP4?token=fixture#part\",\"header\":{\"Referer\":\"https://site.example/\"},\"flag\":\"line\"}");
        check(
                normalize(direct).getInt("parse") == 0,
                "direct media suffix with query and fragment");
        check(
                normalize(direct)
                        .getJSONObject("header")
                        .getString("Referer")
                        .equals("https://site.example/"),
                "per-source header retained");
        direct.put("jx", 1);
        check(normalize(direct).getInt("parse") == 1, "external parser request preserved");
        direct.put("jx", 0).put("playUrl", "https://parser.example/?url=");
        check(normalize(direct).getInt("parse") == 1, "configured parser prefix preserved");
        direct.put("playUrl", "").put("url", "https://site.example/watch?video=clip.mp4");
        check(normalize(direct).getInt("parse") == 1, "media suffix in query is not direct media");
        direct.put("url", "file:///clip.mp4");
        check(normalize(direct).getInt("parse") == 1, "non-HTTP URI preserved");
        direct.put("url", "https://media.example/clip.mp4").remove("jx");
        check(normalize(direct).getInt("parse") == 1, "missing parser intent preserved");
        System.out.println(checks + " JS player checks passed; no live media playback implied.");
    }
}
