package com.pilipala.marcomovie;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.system.Os;
import android.system.OsConstants;
import com.pilipala.catpaw.CatPawHost;
import java.io.*;
import java.net.*;
import java.util.*;
import org.json.*;

/** Real embedded Node/JNI and production DRPY/CatPaw callers, with loopback fixtures only. */
public final class NativeSourceProbe extends Instrumentation {
    final JSONObject result = new JSONObject();
    final List<String> requests = Collections.synchronizedList(new ArrayList<>());
    ServerSocket server;
    volatile boolean running;
    String origin;
    int expectedPageSize;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        expectedPageSize = Integer.parseInt(args.getString("page_size", "4096"));
        start();
    }

    void check(String key, boolean pass) throws Exception {
        result.put(key, pass);
        if (!pass) throw new AssertionError(key);
    }

    void fixtures() throws Exception {
        server = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
        origin = "http://127.0.0.1:" + server.getLocalPort();
        running = true;
        new Thread(
                        () -> {
                            while (running) {
                                try (Socket socket = server.accept()) {
                                    socket.setSoTimeout(5000);
                                    BufferedReader reader =
                                            new BufferedReader(
                                                    new InputStreamReader(
                                                            socket.getInputStream(), "UTF-8"));
                                    String first = reader.readLine();
                                    if (first == null) continue;
                                    String path = first.split(" ")[1];
                                    requests.add(path);
                                    while (true) {
                                        String line = reader.readLine();
                                        if (line == null || line.isEmpty()) break;
                                    }
                                    String data;
                                    if (path.startsWith("/detail/42"))
                                        data =
                                                new JSONObject()
                                                        .put("vod_id", origin + "/detail/42")
                                                        .put("vod_name", "Fixture detail")
                                                        .put("vod_play_from", "fixture")
                                                        .put(
                                                                "vod_play_url",
                                                                "Episode$" + origin + "/resolve")
                                                        .toString();
                                    else if (path.equals("/resolve"))
                                        data =
                                                new JSONObject()
                                                        .put("parse", 0)
                                                        .put("url", origin + "/never-download.mp4")
                                                        .put(
                                                                "header",
                                                                new JSONObject()
                                                                        .put("X-Fixture", "ok"))
                                                        .toString();
                                    else {
                                        String title = "HTML fixture";
                                        if (path.startsWith("/search?")) {
                                            for (String item :
                                                    path.substring(path.indexOf('?') + 1)
                                                            .split("&"))
                                                if (item.startsWith("wd="))
                                                    title =
                                                            URLDecoder.decode(
                                                                    item.substring(3), "UTF-8");
                                        }
                                        if (path.contains("area=local")) title += "local";
                                        data =
                                                "<article class='item'><a href='/detail/42'><h3>"
                                                        + title
                                                        + "</h3><img src='/poster.png'></a><span>test</span></article>";
                                    }
                                    byte[] body = data.getBytes("UTF-8");
                                    OutputStream output = socket.getOutputStream();
                                    output.write(
                                            ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: "
                                                            + body.length
                                                            + "\r\n\r\n")
                                                    .getBytes("US-ASCII"));
                                    output.write(body);
                                    output.flush();
                                } catch (Exception error) {
                                    if (running)
                                        android.util.Log.e(
                                                "NativeSourceProbe", "loopback fixture", error);
                                }
                            }
                        },
                        "native-source-fixture")
                .start();
    }

    String rule() throws Exception {
        return "const rule="
                + new JSONObject()
                        .put("title", "Synthetic fixture")
                        .put("host", origin)
                        .put("homeUrl", "/home")
                        .put("url", "/category/fyclass?page=fypage&fyfilter")
                        .put("filter_url", "area={{fl.area}}")
                        .put("class_name", "Films")
                        .put("class_url", "films")
                        .put("searchable", 2)
                        .put("filterable", 1)
                        .put("推荐", ".item;h3&&Text;img&&src;span&&Text;a&&href")
                        .put("一级", ".item;h3&&Text;img&&src;span&&Text;a&&href")
                        .put("searchUrl", "/search?wd=**&page=fypage")
                        .put("搜索", "*")
                        .put("二级", "js:VOD=JSON.parse(request(input));")
                        .put("play_parse", true)
                        .put("lazy", "js:input=JSON.parse(request(input));")
                        .toString()
                + ";";
    }

    @Override
    public void onStart() {
        DrpyEngine drpy = null;
        CatPawHost host = new CatPawHost(getTargetContext());
        String bundleAddress = null;
        try {
            result.put("page_size", Os.sysconf(OsConstants._SC_PAGESIZE));
            check("expected_page_size", Os.sysconf(OsConstants._SC_PAGESIZE) == expectedPageSize);
            fixtures();
            Context context = getTargetContext();
            Cms.Config config = new Cms.Config();
            config.origin = origin + "/config.json";
            Cms.Site site = new Cms.Site();
            site.key = "native-drpy-fixture";
            site.type = 3;
            site.api = "csp_Drpy";
            site.playUrl = "";
            site.ext = rule();
            drpy = new DrpyEngine(context, config, site);
            check(
                    "drpy_native_home",
                    new JSONObject(drpy.home())
                            .getJSONArray("class")
                            .getJSONObject(0)
                            .getString("type_id")
                            .equals("films"));
            check(
                    "drpy_native_home_html",
                    new JSONObject(drpy.homeVideos())
                            .getJSONArray("list")
                            .getJSONObject(0)
                            .getString("vod_name")
                            .equals("HTML fixture"));
            JSONObject listing =
                    new JSONObject(
                            drpy.category("films", 2, Collections.singletonMap("area", "local")));
            check(
                    "drpy_native_filter_template",
                    listing.getJSONArray("list")
                            .getJSONObject(0)
                            .getString("vod_name")
                            .equals("HTML fixturelocal"));
            check(
                    "drpy_native_unicode_search",
                    new JSONObject(drpy.search("中文", 1))
                            .getJSONArray("list")
                            .getJSONObject(0)
                            .getString("vod_name")
                            .equals("中文"));
            check(
                    "drpy_native_detail",
                    new JSONObject(drpy.detail(origin + "/detail/42"))
                            .getJSONArray("list")
                            .getJSONObject(0)
                            .getString("vod_name")
                            .equals("Fixture detail"));
            JSONObject play = new JSONObject(drpy.player("fixture", origin + "/resolve"));
            check(
                    "drpy_native_play",
                    play.getInt("parse") == 0
                            && play.getString("url").equals(origin + "/never-download.mp4")
                            && play.getJSONObject("header").getString("X-Fixture").equals("ok"));
            check("no_media_download", !requests.contains("/never-download.mp4"));
            drpy.close();
            drpy = new DrpyEngine(context, config, site);
            check("drpy_release_and_reopen", new JSONObject(drpy.home()).has("class"));
            String bundle =
                    "const http=require('node:http');exports.start=async()=>{const ignored=catDartServerPort();const server=catServerFactory((req,res)=>{res.setHeader('Content-Type','application/json');const base='http://127.0.0.1:'+server.address().port;if(req.url==='/t4')res.end(JSON.stringify({sites:[{key:'fixture',name:'Fixture',type:4,api:base+'/api/fixture'}]}));else res.end(JSON.stringify({list:[{vod_id:'native',vod_name:'Native CatPaw fixture'}]}));});await new Promise(resolve=>server.listen(9321,'0.0.0.0',resolve));};";
            JSONObject imported = new JSONObject(host.install(bundle));
            bundleAddress = imported.getJSONArray("sites").getJSONObject(0).getString("api");
            check(
                    "catpaw_native_import",
                    bundleAddress.startsWith("catpaw://") && !bundleAddress.contains("127.0.0.1"));
            check(
                    "catpaw_native_worker",
                    new JSONObject(host.read(bundleAddress))
                            .getJSONArray("list")
                            .getJSONObject(0)
                            .getString("vod_name")
                            .equals("Native CatPaw fixture"));
            host.release(bundleAddress);
            check(
                    "catpaw_release_and_reopen",
                    new JSONObject(host.read(bundleAddress)).getJSONArray("list").length() == 1);
            result.put("passed", true);
        } catch (Throwable failure) {
            try {
                result.put("passed", false).put("error", failure.toString());
            } catch (Exception ignored) {
            }
            android.util.Log.e("NativeSourceProbe", "native source regression", failure);
        } finally {
            if (drpy != null) drpy.close();
            try {
                if (bundleAddress != null) host.release(bundleAddress);
            } catch (Exception ignored) {
            }
            running = false;
            try {
                if (server != null) server.close();
            } catch (Exception ignored) {
            }
        }
        Bundle summary = new Bundle();
        summary.putString("result", result.toString());
        sendStatus(0, summary);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
