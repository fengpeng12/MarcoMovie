package com.pilipala.marcomovie;

/** Only shipped engine. An unsupported SourceEngine is never selected silently. */
public final class JsonCmsEngine implements SourceEngine {
    private final Cms.Site site;

    public JsonCmsEngine(Cms.Site site) {
        if (!site.supported()) throw new IllegalArgumentException("Unsupported source type");
        this.site = site;
    }

    private String detailAction() {
        return site.type == 0 ? "videolist" : "detail";
    }

    public String home() throws Exception {
        return Cms.fetch(Cms.query(site.api, "ac", "list"), site.headers);
    }

    public String category(String id, int page) throws Exception {
        return category(id, page, java.util.Collections.emptyMap());
    }

    public String category(String id, int page, java.util.Map<String, String> filters)
            throws Exception {
        String url = Cms.query(site.api, "ac", detailAction(), "t", id, "pg", "" + page);
        for (java.util.Map.Entry<String, String> entry : filters.entrySet()) {
            // A remote filter schema cannot replace request routing/authentication.
            if (VideoFilters.allowedKey(entry.getKey()))
                url = Cms.query(url, entry.getKey(), entry.getValue());
        }
        return Cms.fetch(url, site.headers);
    }

    public String detail(String id) throws Exception {
        return Cms.fetch(Cms.query(site.api, "ac", detailAction(), "ids", id), site.headers);
    }

    public String search(String keyword, int page) throws Exception {
        return Cms.fetch(
                Cms.query(site.api, "ac", detailAction(), "wd", keyword, "pg", "" + page),
                site.headers);
    }

    public boolean requiresExternalRuntime() {
        return false;
    }
}
