package com.github.catvod.crawler;

import com.google.gson.JsonArray;

/** Host callback ABI expected by Spider.initApi(SpiderApi) in third-party JAR extensions. */
public class SpiderApi {
    public SpiderApi() {}

    public void log(String message) {}

    public String getAddress(boolean local) {
        return "http://127.0.0.1:" + com.pilipala.marcomovie.CspEngine.proxyPort() + "/";
    }

    public String getPort() {
        return String.valueOf(com.pilipala.marcomovie.CspEngine.proxyPort());
    }

    public String multiReq(JsonArray requests) {
        return "";
    }

    public String webParse(String url, String extra) {
        return "";
    }
}
