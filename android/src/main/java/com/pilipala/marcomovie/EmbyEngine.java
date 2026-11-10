package com.pilipala.marcomovie;

import com.pilipala.emby.*;
import org.json.*;

final class EmbyEngine implements SourceEngine {
    private final EmbyLibrary library;

    EmbyEngine(MainActivity activity, Cms.Site site) throws Exception {
        library = EmbyAccounts.open(activity, site.api);
    }

    static void connect(MainActivity a) {
        EmbyAccounts.connect(
                a,
                site ->
                        SourceController.mergeOrSaveConfig(
                                a,
                                Cms.parseConfig(
                                        new JSONObject()
                                                .put("sites", new JSONArray().put(site))
                                                .toString(),
                                        ""),
                                "",
                                true));
    }

    public String home() throws Exception {
        return library.home().toString();
    }

    public String homeVideos() throws Exception {
        return library.list("", "", 1).toString();
    }

    public String category(String id, int page) throws Exception {
        return library.list(id, "", page).toString();
    }

    public String search(String term, int page) throws Exception {
        return library.list("", term, page).toString();
    }

    public String detail(String id) throws Exception {
        return library.detail(id).toString();
    }

    public String player(String flag, String id) throws Exception {
        return library.resolve(id, false).toString();
    }

    public boolean requiresExternalRuntime() {
        return false;
    }
}
