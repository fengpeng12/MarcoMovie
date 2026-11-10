package com.pilipala.marcomovie;

import android.app.Application;
import android.app.Instrumentation;
import android.os.Bundle;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.InputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.HttpURLConnection;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import org.json.JSONObject;

/** Exercises shipped QuickJS JNI and JsEngine with local synthetic sources; no remote media. */
public final class SourceHostProbe extends Instrumentation {
    final JSONObject report = new JSONObject();
    final List<File> files = new ArrayList<>();
    final List<JsEngine> engines = new ArrayList<>();
    File folder;
    int checks;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    void check(String name, boolean passed) throws Exception {
        report.put(name, passed);
        if (!passed) throw new AssertionError(name);
        checks++;
    }

    File write(String name, String source) throws Exception {
        File target = new File(folder, name);
        try (FileOutputStream out = new FileOutputStream(target)) {
            out.write(source.getBytes("UTF-8"));
        }
        files.add(target);
        return target;
    }

    JsEngine engine(String name, String source) throws Exception {
        return engine(name, source, 45000);
    }

    JsEngine engine(String name, String source, long timeoutMillis) throws Exception {
        return engine(name, source, timeoutMillis, "ready");
    }

    JsEngine engine(String name, String source, long timeoutMillis, Object extension)
            throws Exception {
        File file = write(name, source);
        Cms.Site site = new Cms.Site();
        site.key = "source-host-probe-" + name;
        site.name = name;
        site.type = 3;
        site.api = Cms.fileUri(file);
        site.ext = extension;
        long started = android.os.SystemClock.elapsedRealtime();
        try {
            JsEngine engine =
                    new JsEngine(
                            (Application) getTargetContext().getApplicationContext(),
                            new Cms.Config(),
                            site,
                            timeoutMillis);
            engines.add(engine);
            return engine;
        } finally {
            if (name.endsWith(".py")) {
                JSONObject times = report.optJSONObject("python_initialization_ms");
                if (times == null) {
                    times = new JSONObject();
                    report.put("python_initialization_ms", times);
                }
                times.put(name, android.os.SystemClock.elapsedRealtime() - started);
            }
            if (name.equals("fixture.py"))
                report.put(
                        "python_html_init_ms", android.os.SystemClock.elapsedRealtime() - started);
        }
    }

    interface CheckedCall {
        void run() throws Exception;
    }

    void fails(String name, String marker, CheckedCall call) throws Exception {
        String error = "";
        try {
            call.run();
        } catch (Exception failure) {
            error = failure.toString();
        }
        check(name, error.contains(marker));
    }

    JSONObject first(String value) throws Exception {
        return new JSONObject(value).getJSONArray("list").getJSONObject(0);
    }

    static final class ProxyResult {
        int status;
        byte[] body;
        String count;
        String range;
        String length;
    }

    ProxyResult proxyRequest(String address, String method, String range) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setConnectTimeout(3000);
        connection.setReadTimeout(15000);
        connection.setRequestMethod(method);
        if (range != null) connection.setRequestProperty("Range", range);
        try {
            ProxyResult result = new ProxyResult();
            result.status = connection.getResponseCode();
            result.count = connection.getHeaderField("X-Count");
            result.range = connection.getHeaderField("Content-Range");
            result.length = connection.getHeaderField("Content-Length");
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            InputStream input =
                    result.status < 400 ? connection.getInputStream() : connection.getErrorStream();
            if (input != null)
                try (InputStream stream = input) {
                    byte[] buffer = new byte[256];
                    int read;
                    while ((read = stream.read(buffer)) != -1) {
                        if (body.size() + read > 4096)
                            throw new AssertionError("proxy fixture body too large");
                        body.write(buffer, 0, read);
                    }
                }
            result.body = body.toByteArray();
            return result;
        } finally {
            connection.disconnect();
        }
    }

    void exerciseScriptProxy() throws Exception {
        Application app = (Application) getTargetContext().getApplicationContext();
        try (LocalProxy proxy = new LocalProxy(app, new Cms.Config())) {
            String python =
                    "from base.spider import Spider as Base\n"
                            + "class Spider(Base):\n"
                            + "    def init(self, ext):\n"
                            + "        self.base = self.getProxyUrl(); self.count = 0\n"
                            + "    def playerContent(self, flag, id, vipFlags):\n"
                            + "        return {'url':self.base + '&mode=' + id}\n"
                            + "    def localProxy(self, params):\n"
                            + "        self.count += 1\n"
                            + "        headers = {'X-Count':str(self.count)}\n"
                            + "        if params.get('range') == 'bytes=1-2':\n"
                            + "            headers['Content-Range'] = 'bytes 1-2/4'\n"
                            + "            return [206,'application/octet-stream',bytes([255,128]),headers]\n"
                            + "        return [200,'application/octet-stream',bytes([0,255,128,65]),headers]\n";
            JsEngine py = engine("proxy.py", python);
            py.activate();
            String pyUrl = new JSONObject(py.player("Main", "bytes")).getString("url");
            check(
                    "python_proxy_local_route",
                    pyUrl.startsWith(ProxyAddress.base() + "/proxy?do=py&siteKey=")
                            && pyUrl.contains("&_mm_token="));
            ProxyResult first = proxyRequest(pyUrl, "GET", null);
            check(
                    "python_proxy_jni_binary",
                    first.status == 200
                            && Arrays.equals(
                                    first.body, new byte[] {0, (byte) 255, (byte) 128, 65}));
            check(
                    "python_proxy_jni_state",
                    "1".equals(first.count) && "2".equals(proxyRequest(pyUrl, "GET", null).count));
            ProxyResult pyRange = proxyRequest(pyUrl, "GET", "bytes=1-2");
            check(
                    "python_proxy_jni_range",
                    pyRange.status == 206
                            && "bytes 1-2/4".equals(pyRange.range)
                            && Arrays.equals(pyRange.body, new byte[] {(byte) 255, (byte) 128}));
            ProxyResult pyHead = proxyRequest(pyUrl, "HEAD", null);
            check(
                    "python_proxy_jni_head",
                    pyHead.status == 200 && pyHead.body.length == 0 && "4".equals(pyHead.length));
            JsEngine js =
                    engine(
                            "proxy.js",
                            "module.exports={init(){this.base=getProxy();this.count=0;},"
                                    + "play(flag,id){return {url:id==='bytes'?this.base+'&mode='+id:proxyUrl({mode:id})};},"
                                    + "proxy(p){const h={'X-Count':String(++this.count)};"
                                    + "if(p.range==='bytes=1-2'){h['Content-Range']='bytes 1-2/4';return [206,'application/octet-stream',[255,128],h];}"
                                    + "const typed=new Uint8Array([0,255,128,65]);"
                                    + "if(p.mode==='typed')return [200,'application/octet-stream',typed,h];"
                                    + "if(p.mode==='buffer')return [200,'application/octet-stream',typed.buffer,h];"
                                    + "if(p.mode==='flag')return [200,'application/octet-stream',typed,h,2];"
                                    + "if(p.mode==='headers')return [200,'application/octet-stream',typed,false];"
                                    + "return [200,'application/octet-stream','AP+AQQ==',h,1];}};");
            js.activate();
            String jsUrl = new JSONObject(js.player("Main", "bytes")).getString("url");
            check(
                    "js_proxy_local_route",
                    jsUrl.startsWith(ProxyAddress.base() + "/proxy?do=js&site="));
            ProxyResult jsFirst = proxyRequest(jsUrl, "GET", null);
            check(
                    "js_proxy_jni_base64",
                    jsFirst.status == 200
                            && "1".equals(jsFirst.count)
                            && Arrays.equals(
                                    jsFirst.body, new byte[] {0, (byte) 255, (byte) 128, 65}));
            ProxyResult jsRange = proxyRequest(jsUrl, "GET", "bytes=1-2");
            check(
                    "js_proxy_jni_range",
                    jsRange.status == 206
                            && "bytes 1-2/4".equals(jsRange.range)
                            && Arrays.equals(jsRange.body, new byte[] {(byte) 255, (byte) 128}));
            ProxyResult jsHead = proxyRequest(jsUrl, "HEAD", null);
            check(
                    "js_proxy_jni_head",
                    jsHead.status == 200 && jsHead.body.length == 0 && "4".equals(jsHead.length));
            for (String mode : new String[] {"typed", "buffer"}) {
                String url = new JSONObject(js.player("Main", mode)).getString("url");
                ProxyResult result = proxyRequest(url, "GET", null);
                check(
                        "js_proxy_jni_" + mode,
                        result.status == 200
                                && Arrays.equals(
                                        result.body, new byte[] {0, (byte) 255, (byte) 128, 65}));
            }
            for (String mode : new String[] {"flag", "headers"}) {
                String url = new JSONObject(js.player("Main", mode)).getString("url");
                check("js_proxy_jni_rejects_" + mode, proxyRequest(url, "GET", null).status == 502);
            }
            JsEngine replacement = engine("proxy.py", python);
            replacement.activate();
            String replacementUrl =
                    new JSONObject(replacement.player("Main", "bytes")).getString("url");
            check(
                    "python_proxy_replacement_revokes_old",
                    !replacementUrl.equals(pyUrl)
                            && proxyRequest(pyUrl, "GET", null).status == 502);
            check(
                    "python_proxy_replacement_fresh_state",
                    "1".equals(proxyRequest(replacementUrl, "GET", null).count));
            replacement.close();
            check(
                    "python_proxy_close_revokes_url",
                    proxyRequest(replacementUrl, "GET", null).status == 502);
            check(
                    "script_proxy_source_isolation",
                    "8".equals(proxyRequest(jsUrl, "GET", null).count));
            js.close();
            check("js_proxy_close_revokes_url", proxyRequest(jsUrl, "GET", null).status == 502);
        }
    }

    void exerciseNativeDeadlines() throws Exception {
        Application app = (Application) getTargetContext().getApplicationContext();
        try (LocalProxy proxy = new LocalProxy(app, new Cms.Config())) {
            JsEngine looping =
                    engine(
                            "deadline.js",
                            "module.exports={play(){return {url:getProxy()};},home(){while(true){}}};",
                            1500);
            looping.activate();
            String oldUrl = new JSONObject(looping.player("Main", "1")).getString("url");
            QueuedSourceEngine queued = new QueuedSourceEngine(looping);
            long started = android.os.SystemClock.elapsedRealtime();
            fails("native_instruction_deadline", "时间限制", queued::home);
            long elapsed = android.os.SystemClock.elapsedRealtime() - started;
            check("native_deadline_before_java_wait", elapsed >= 500 && elapsed < 7000);
            check(
                    "native_deadline_invalidates_cached_source",
                    looping.isClosed() && queued.isWedged());
            check("native_deadline_revokes_proxy", proxyRequest(oldUrl, "GET", null).status == 502);
            // Same logical key, as SourceController recreates after isWedged().
            JsEngine fresh =
                    engine(
                            "deadline.js",
                            "module.exports={home(){return {list:[{vod_id:'fresh'}]}}};",
                            1500);
            fresh.activate();
            check(
                    "native_deadline_recreated_source",
                    first(fresh.home()).getString("vod_id").equals("fresh"));
            Thread.sleep(1600);
            check(
                    "native_deadline_resets_each_operation",
                    first(fresh.home()).getString("vod_id").equals("fresh"));
            fresh.close();
            fresh.close();
            check("native_deadline_close_idempotent", fresh.isClosed());
            fails(
                    "native_module_init_deadline",
                    "时间限制",
                    () -> engine("deadline-init.js", "while(true){};module.exports={};", 1500));

            String name = "deadline-cancel.js";
            byte[] keyHash =
                    java.security.MessageDigest.getInstance("SHA-256")
                            .digest(("source-host-probe-" + name).getBytes("UTF-8"));
            StringBuilder hash = new StringBuilder();
            for (byte value : keyHash) hash.append(String.format(Locale.ROOT, "%02x", value & 255));
            android.content.SharedPreferences storage =
                    app.getSharedPreferences("js-source-" + hash, 0);
            storage.edit().clear().commit();
            JsEngine cancelled =
                    engine(
                            name,
                            "module.exports={home(){local.set('probe','entered','yes');while(true){}}};");
            cancelled.activate();
            RequestScope scope = new RequestScope();
            java.util.concurrent.atomic.AtomicReference<Throwable> error =
                    new java.util.concurrent.atomic.AtomicReference<>();
            Thread request =
                    new Thread(
                            () -> {
                                try {
                                    scope.call(cancelled::home);
                                } catch (Throwable failure) {
                                    error.set(failure);
                                }
                            },
                            "native-deadline-cancel-probe");
            request.setDaemon(true);
            request.start();
            long waitUntil = android.os.SystemClock.elapsedRealtime() + 5000;
            while (!"yes".equals(storage.getString("probe\nentered", ""))
                    && request.isAlive()
                    && android.os.SystemClock.elapsedRealtime() < waitUntil) Thread.sleep(10);
            boolean entered = "yes".equals(storage.getString("probe\nentered", ""));
            scope.cancel();
            request.join(5000);
            check("native_cancel_entered_instruction_loop", entered);
            check(
                    "native_scope_cancel_interrupts_cpu",
                    !request.isAlive()
                            && error.get() != null
                            && error.get().toString().contains("取消"));
            check("native_cancel_source_closed", cancelled.isClosed());
            JsEngine afterCancel =
                    engine(
                            name,
                            "module.exports={home(){return {list:[{vod_id:'after-cancel'}]}}};");
            afterCancel.activate();
            scope.cancel(); // Late cancellation of an old operation must not affect its successor.
            check(
                    "native_cancel_new_source_unaffected",
                    first(afterCancel.home()).getString("vod_id").equals("after-cancel"));
            afterCancel.close();
            storage.edit().clear().commit();
        }
    }

    void exerciseFullSpiderContract() throws Exception {
        String rawExtension = " \n { \"title\" : \"本机配置\" } \t";
        String spiderClass =
                "class CompleteSpider {"
                        + "constructor(){globalThis.created++;this.calls=0;}"
                        + "async init(ext){await Promise.resolve();this.ext=ext;}"
                        + "homeContent(){return {list:[{vod_id:'home'}],ext:this.ext,created:globalThis.created,calls:++this.calls};}"
                        + "categoryContent(id,pg,filtered,extend){if(typeof pg!=='string'||pg!=='2'||extend.type!=='opaque')throw Error('category ABI');this.calls++;return {list:[{vod_id:pg}]};}"
                        + "searchContent(word,quick,pg){if(typeof pg!=='string'||pg!=='3')throw Error('search ABI');this.calls++;return {list:[{vod_id:pg}]};}"
                        + "detailContent(ids){if(!Array.isArray(ids)||ids.length!==1||ids[0]!=='42')throw Error('detail ABI');this.calls++;return {list:[{vod_id:ids[0]}]};}"
                        + "playerContent(flag,id,vips){if(!Array.isArray(vips))throw Error('player ABI');return {url:'https://fixture.invalid/'+id+'.mp4',calls:++this.calls};}"
                        + "}";
        for (String kind : new String[] {"cjs", "esm"}) {
            String source =
                    "globalThis.created=0;\n"
                            + (kind.equals("cjs") ? "module.exports=" : "export default ")
                            + spiderClass
                            + ";";
            JsEngine full =
                    engine(
                            "complete-" + kind + (kind.equals("cjs") ? ".js" : ".mjs"),
                            source,
                            45000,
                            rawExtension);
            JSONObject first = new JSONObject(full.home()), second = new JSONObject(full.home());
            check(
                    "complete_" + kind + "_raw_ext_instance_state",
                    first.getString("ext").equals(rawExtension)
                            && first.getInt("created") == 1
                            && first.getInt("calls") == 1
                            && second.getInt("created") == 1
                            && second.getInt("calls") == 2);
            java.util.Map<String, String> filters = new java.util.LinkedHashMap<>();
            filters.put("type", "opaque");
            check(
                    "complete_" + kind + "_string_pages",
                    first(full.category("movie", 2, filters)).getString("vod_id").equals("2")
                            && first(full.search("fixture", 3)).getString("vod_id").equals("3"));
            JSONObject detail = first(full.detail("42")),
                    player = new JSONObject(full.player("Main", "42"));
            check(
                    "complete_" + kind + "_detail_array_player_state",
                    detail.getString("vod_id").equals("42")
                            && player.getString("url").equals("https://fixture.invalid/42.mp4")
                            && player.getInt("calls") == 6);
            full.close();
        }
        JsEngine mixed =
                engine(
                        "complete-short-priority.js",
                        "module.exports={init(ext){this.ext=ext;},home(){return {list:[{vod_id:'short',kind:typeof this.ext}]};},"
                                + "homeContent(){throw Error('wrong alias');},category(id,pg){return {list:[{vod_id:typeof pg}]};},"
                                + "categoryContent(){throw Error('wrong category alias');}};",
                        45000,
                        new JSONObject().put("key", "value"));
        check(
                "complete_short_names_keep_legacy_contract",
                first(mixed.home()).getString("kind").equals("object")
                        && first(mixed.home()).getString("vod_id").equals("short")
                        && first(mixed.category("movie", 2)).getString("vod_id").equals("number"));
        mixed.close();
        JsEngine objectExt =
                engine(
                        "complete-object-ext.js",
                        "module.exports={init(ext){this.ext=ext;},homeContent(){return {list:[{vod_id:typeof this.ext,key:JSON.parse(this.ext).key}]};}};",
                        45000,
                        new JSONObject().put("key", "value"));
        check(
                "complete_object_extension_serialized",
                first(objectExt.home()).getString("vod_id").equals("string")
                        && first(objectExt.home()).getString("key").equals("value"));
        objectExt.close();
        JsEngine cat =
                engine(
                        "complete-cat.js",
                        "function __jsEvalReturn(){return {init(cfg){if(cfg.stype!==3||cfg.skey!=='source-host-probe-complete-cat.js'||typeof cfg.ext!=='string')throw Error('cat init');this.cfg=cfg;},"
                                + "homeContent(){return {list:[{vod_id:this.cfg.ext}]};},"
                                + "detailContent(ids){if(!Array.isArray(ids)||ids.length!==1||typeof ids[0]!=='string')throw Error('cat detail');return {list:[{vod_id:ids[0]}]};}};}",
                        45000,
                        rawExtension);
        check(
                "complete_cat_keeps_init_metadata_and_array",
                first(cat.home()).getString("vod_id").equals(rawExtension)
                        && first(cat.detail("42")).getString("vod_id").equals("42"));
        cat.close();
    }

    /** Two loopback requests only; independent of device Wi-Fi and mobile data. */
    static final class CatvodHttpServer implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"));
        final Thread thread;
        volatile Throwable error;
        volatile boolean closing;
        volatile boolean destroyRequested;

        CatvodHttpServer() throws Exception {
            listener.setSoTimeout(10000);
            thread =
                    new Thread(
                            () -> {
                                while (!closing) {
                                    try (Socket socket = listener.accept()) {
                                        socket.setSoTimeout(3000);
                                        InputStream input = socket.getInputStream();
                                        ByteArrayOutputStream header = new ByteArrayOutputStream();
                                        int end = 0;
                                        while (end != 0x0d0a0d0a) {
                                            int value = input.read();
                                            if (value < 0 || header.size() >= 8192)
                                                throw new IOException(
                                                        "invalid HTTP fixture headers");
                                            header.write(value);
                                            end = (end << 8) | value;
                                        }
                                        String[] lines =
                                                new String(header.toByteArray(), "US-ASCII")
                                                        .split("\r\n");
                                        String[] first = lines[0].split(" ");
                                        int length = 0;
                                        String cookie = "", type = "";
                                        for (String line : lines) {
                                            String lower = line.toLowerCase(Locale.ROOT);
                                            if (lower.startsWith("content-length:"))
                                                length =
                                                        Integer.parseInt(line.substring(15).trim());
                                            if (lower.startsWith("cookie:"))
                                                cookie = line.substring(7).trim();
                                            if (lower.startsWith("content-type:"))
                                                type = line.substring(13).trim();
                                        }
                                        if (length < 0 || length > 4096)
                                            throw new IOException("fixture request too large");
                                        byte[] body = new byte[length];
                                        for (int offset = 0; offset < length; ) {
                                            int n = input.read(body, offset, length - offset);
                                            if (n < 0)
                                                throw new IOException("truncated fixture body");
                                            offset += n;
                                        }
                                        if (first[1].equals("/destroy")) destroyRequested = true;
                                        if (first[1].equals("/slow")) {
                                            Thread.sleep(180);
                                            continue;
                                        }
                                        boolean binary = first[1].equals("/binary");
                                        JSONObject response =
                                                new JSONObject()
                                                        .put("method", first[0])
                                                        .put("body", new String(body, "UTF-8"))
                                                        .put("cookie", cookie)
                                                        .put("type", type);
                                        byte[] reply =
                                                binary
                                                        ? body
                                                        : response.toString().getBytes("UTF-8");
                                        OutputStream output = socket.getOutputStream();
                                        output.write(
                                                ("HTTP/1.1 200 OK\r\nContent-Type: "
                                                                + (binary
                                                                        ? "application/octet-stream"
                                                                        : "application/json; charset=utf-8")
                                                                + "\r\nContent-Length: "
                                                                + reply.length
                                                                + "\r\nConnection: close\r\n"
                                                                + (first[1].equals("/seed")
                                                                        ? "Set-Cookie: legacy=retained; Path=/\r\n"
                                                                        : "")
                                                                + "\r\n")
                                                        .getBytes("US-ASCII"));
                                        output.write(reply);
                                        output.flush();
                                    } catch (Throwable failure) {
                                        if (!closing) error = failure;
                                        return;
                                    }
                                }
                            },
                            "catvod-loopback");
            thread.setDaemon(true);
            thread.start();
        }

        @Override
        public void close() throws Exception {
            closing = true;
            listener.close();
            thread.join(1000);
        }
    }

    void exerciseCatvodContract() throws Exception {
        Application app = (Application) getTargetContext().getApplicationContext();
        try (CatvodHttpServer server = new CatvodHttpServer();
                LocalProxy proxy = new LocalProxy(app, new Cms.Config())) {
            String base = "http://127.0.0.1:" + server.listener.getLocalPort();
            int unavailable;
            try (ServerSocket closedPort =
                    new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
                unavailable = closedPort.getLocalPort();
            }
            write("catvod.js", "throw Error('local file must not override app catvod');");
            write(
                    "catvod-helper.mjs",
                    "import {net,md5X,sha256X} from 'catvod';export const nested=(u,o)=>net.json(u,o);export const digests=()=>[md5X('abc'),sha256X('abc')];");
            String source =
                    "import {Spider,net} from 'catvod';\nimport {nested,digests} from './catvod-helper.mjs';\n"
                            + "export default class Local extends Spider {#state=7;init(ext){this.config=JSON.parse(ext);}"
                            + "async homeContent(){const b=this.config.base;"
                            + "const json=await nested(b+'/json',{method:'POST',data:{title:'本机'}});"
                            + "const form=await net.json(b+'/form',{method:'POST',postType:'form',data:{q:' a b '}});"
                            + "const binary=await net.req(b+'/binary',{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:[0,255,128,65],buffer:3});"
                            + "req(b+'/seed');const old=JSON.parse(req(b+'/echo').content);"
                            + "const clean=await net.json(b+'/echo');const explicit=await net.json(b+'/echo',{headers:{Cookie:'explicit=yes'}});"
                            + "const options=await net.json(b+'/echo',{method:'OPTIONS'});"
                            + "const failed=await net.req(this.config.unavailable,{timeout:200});let jsonThrows=false;try{await net.json(this.config.unavailable,{timeout:200});}catch(e){jsonThrows=true;}"
                            + "const timeout=await net.req(b+'/slow',{timeout:1000,callTimeout:50});"
                            + "let remoteProxy=false;try{this.proxyUrl({},false);}catch(e){remoteProxy=true;}"
                            + "return {json,form,bytes:Array.from(new Uint8Array(binary.content)),isBuffer:binary.content instanceof ArrayBuffer,old:old.cookie,clean:clean.cookie,explicit:explicit.cookie,method:options.method,failed:!!failed.error,jsonThrows,timeout:!!timeout.error,remoteProxy,hashes:digests(),key:this.siteKey,state:this.#state};}"
                            + "playerContent(){const previous=globalThis.__proxyAddress;try{globalThis.__proxyAddress='https://fixture.invalid/not-local';return {url:this.proxyUrl({ticket:'local'})};}finally{globalThis.__proxyAddress=previous;}}"
                            + "proxy(p){return [200,'application/octet-stream',new Uint8Array([0,255,128,65]).buffer,{'X-Count':String(this.#state)}];}"
                            + "async destroy(){await net.req(this.config.base+'/destroy');while(true){}}}";
            JSONObject extension =
                    new JSONObject()
                            .put("base", base)
                            .put("unavailable", "http://127.0.0.1:" + unavailable + "/offline");
            JsEngine engine = engine("catvod-main.mjs", source, 45000, extension);
            JSONObject home = new JSONObject(engine.home());
            check(
                    "catvod_nested_module_class_identity",
                    home.getInt("state") == 7 && home.getString("key").matches("[0-9a-f]{32}"));
            check(
                    "catvod_json_utf8_post",
                    new JSONObject(home.getJSONObject("json").getString("body"))
                                    .getString("title")
                                    .equals("本机")
                            && home.getJSONObject("json")
                                    .getString("type")
                                    .startsWith("application/json"));
            check(
                    "catvod_form_post",
                    home.getJSONObject("form").getString("body").equals("q=a%20b")
                            && home.getJSONObject("form")
                                    .getString("type")
                                    .equals("application/x-www-form-urlencoded"));
            check(
                    "catvod_binary_arraybuffer_roundtrip",
                    home.getBoolean("isBuffer")
                            && home.getJSONArray("bytes").toString().equals("[0,255,128,65]"));
            check(
                    "catvod_cookie_isolated_from_legacy_req",
                    home.getString("old").contains("legacy=retained")
                            && home.getString("clean").isEmpty()
                            && home.getString("explicit").equals("explicit=yes"));
            check("catvod_options_method", home.getString("method").equals("OPTIONS"));
            check(
                    "catvod_transport_error_contract",
                    home.getBoolean("failed")
                            && home.getBoolean("jsonThrows")
                            && home.getBoolean("timeout"));
            check(
                    "catvod_crypto_and_local_proxy_contract",
                    home.getJSONArray("hashes")
                                    .getString(0)
                                    .equals("900150983cd24fb0d6963f7d28e17f72")
                            && home.getJSONArray("hashes")
                                    .getString(1)
                                    .equals(
                                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                            && home.getBoolean("remoteProxy"));
            engine.activate();
            String address = new JSONObject(engine.player("line", "id")).getString("url");
            ProxyResult proxied = proxyRequest(address, "GET", null);
            check(
                    "catvod_proxy_retains_instance_and_binary",
                    proxied.status == 200
                            && "7".equals(proxied.count)
                            && Arrays.equals(
                                    proxied.body, new byte[] {0, (byte) 255, (byte) 128, 65}));
            java.lang.reflect.Field field = JsEngine.class.getDeclaredField("executor");
            field.setAccessible(true);
            java.util.concurrent.ExecutorService executor =
                    (java.util.concurrent.ExecutorService) field.get(engine);
            long started = System.nanoTime();
            engine.close();
            engine.close();
            boolean released = executor.awaitTermination(3, java.util.concurrent.TimeUnit.SECONDS);
            long elapsed =
                    java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
            check("catvod_destroy_cpu_bounded_once", released && elapsed >= 250 && elapsed < 3000);
            check(
                    "catvod_destroy_cannot_network_or_keep_proxy",
                    !server.destroyRequested
                            && proxyRequest(address, "GET", null).status == 502
                            && server.error == null);
            JsEngine next =
                    engine(
                            "catvod-next.mjs",
                            "import {Spider} from 'catvod';export default class extends Spider {homeContent(){return {key:this.siteKey};}}");
            check(
                    "catvod_next_source_has_separate_identity",
                    !new JSONObject(next.home()).getString("key").equals(home.getString("key")));
            JsEngine failure =
                    engine(
                            "catvod-failure.mjs",
                            "import {Spider} from 'catvod';export default class extends Spider {homeContent(){throw Error('catvod fixture failure');}playerContent(){return {url:this.proxyUrl()};}destroy(){while(true){}}}");
            failure.activate();
            String failedAddress = new JSONObject(failure.player("line", "id")).getString("url");
            String message = "";
            try {
                failure.home();
            } catch (Exception expected) {
                message = expected.toString();
            }
            java.util.concurrent.ExecutorService failedExecutor =
                    (java.util.concurrent.ExecutorService) field.get(failure);
            check(
                    "catvod_unhandled_failure_closes_source",
                    message.contains("catvod fixture failure")
                            && failure.isClosed()
                            && failedExecutor.awaitTermination(
                                    3, java.util.concurrent.TimeUnit.SECONDS)
                            && proxyRequest(failedAddress, "GET", null).status == 502);
        }
    }

    static final class PythonSessionServer implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 2, InetAddress.getByName("127.0.0.1"));
        final Thread thread;
        volatile Throwable error;
        volatile String cookie = "";
        volatile String sessionHeader = "";
        volatile int requests;

        PythonSessionServer() throws Exception {
            listener.setSoTimeout(10000);
            thread =
                    new Thread(
                            () -> {
                                try {
                                    for (int index = 0; index < 2; index++) {
                                        try (Socket socket = listener.accept()) {
                                            socket.setSoTimeout(3000);
                                            BufferedReader reader =
                                                    new BufferedReader(
                                                            new InputStreamReader(
                                                                    socket.getInputStream(),
                                                                    "UTF-8"));
                                            String line = reader.readLine();
                                            String expected =
                                                    index == 0
                                                            ? "GET /login "
                                                            : "GET /auth/resource ";
                                            if (line == null || !line.startsWith(expected))
                                                throw new IllegalStateException(
                                                        "unexpected local session path");
                                            int size = line.length(), count = 0;
                                            while ((line = reader.readLine()) != null
                                                    && !line.isEmpty()) {
                                                size += line.length();
                                                if (++count > 64 || size > 8192)
                                                    throw new IllegalStateException(
                                                            "oversized local request");
                                                String lower = line.toLowerCase(Locale.ROOT);
                                                if (index == 1 && lower.startsWith("cookie:"))
                                                    cookie = line.substring(7).trim();
                                                if (index == 1 && lower.startsWith("x-session:"))
                                                    sessionHeader = line.substring(10).trim();
                                            }
                                            String body =
                                                    index == 0
                                                            ? "{}"
                                                            : "{\"list\":[{\"vod_id\":\"session\",\"vod_name\":\"Authenticated local session\"}]}";
                                            byte[] bytes = body.getBytes("UTF-8");
                                            String headers =
                                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                                                            + bytes.length
                                                            + "\r\nConnection: close\r\n";
                                            if (index == 0)
                                                headers +=
                                                        "Set-Cookie: sid=fixture; Path=/auth; HttpOnly\r\nSet-Cookie: foreign=reject; Domain=unrelated.invalid; Path=/\r\n";
                                            OutputStream output = socket.getOutputStream();
                                            output.write((headers + "\r\n").getBytes("UTF-8"));
                                            output.write(bytes);
                                            output.flush();
                                            requests++;
                                        }
                                    }
                                } catch (Throwable failure) {
                                    error = failure;
                                }
                            },
                            "python-session-loopback");
            thread.setDaemon(true);
        }

        @Override
        public void close() throws Exception {
            listener.close();
            thread.join(1000);
        }
    }

    /** Reads raw request bytes, without a character reader consuming the binary body. */
    static final class PythonBinaryServer implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 2, InetAddress.getByName("127.0.0.1"));
        final Thread thread;
        volatile Throwable error;
        volatile byte[] uploaded;
        volatile byte[] empty;
        volatile int requests;

        PythonBinaryServer() throws Exception {
            listener.setSoTimeout(10000);
            thread =
                    new Thread(
                            () -> {
                                try {
                                    for (int index = 0; index < 2; index++) {
                                        try (Socket socket = listener.accept()) {
                                            socket.setSoTimeout(3000);
                                            InputStream input = socket.getInputStream();
                                            ByteArrayOutputStream header =
                                                    new ByteArrayOutputStream();
                                            int end = 0;
                                            while (end != 0x0d0a0d0a) {
                                                int value = input.read();
                                                if (value < 0 || header.size() >= 8192)
                                                    throw new IllegalStateException(
                                                            "incomplete binary request headers");
                                                header.write(value);
                                                end = (end << 8) | value;
                                            }
                                            String[] lines =
                                                    new String(header.toByteArray(), "US-ASCII")
                                                            .split("\r\n");
                                            String expected =
                                                    index == 0 ? "POST /upload " : "POST /empty ";
                                            if (!lines[0].startsWith(expected))
                                                throw new IllegalStateException(
                                                        "unexpected binary request path");
                                            int length = -1;
                                            for (String line : lines)
                                                if (line.toLowerCase(Locale.ROOT)
                                                        .startsWith("content-length:"))
                                                    length =
                                                            Integer.parseInt(
                                                                    line.substring(15).trim());
                                            if (length != (index == 0 ? 4 : 0))
                                                throw new IllegalStateException(
                                                        "unexpected binary content length "
                                                                + length);
                                            byte[] body = new byte[length];
                                            for (int offset = 0; offset < length; ) {
                                                int read =
                                                        input.read(body, offset, length - offset);
                                                if (read < 0)
                                                    throw new IllegalStateException(
                                                            "incomplete binary request body");
                                                offset += read;
                                            }
                                            if (index == 0) uploaded = body;
                                            else empty = body;
                                            String reply =
                                                    index == 0
                                                            ? "{\"bytes\":[0,255,128,65]}"
                                                            : "{\"bytes\":[]}";
                                            byte[] bytes = reply.getBytes("UTF-8");
                                            OutputStream output = socket.getOutputStream();
                                            output.write(
                                                    ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                                                                    + bytes.length
                                                                    + "\r\nConnection: close\r\n\r\n")
                                                            .getBytes("US-ASCII"));
                                            output.write(bytes);
                                            output.flush();
                                            requests++;
                                        }
                                    }
                                } catch (Throwable failure) {
                                    error = failure;
                                }
                            },
                            "python-binary-loopback");
            thread.setDaemon(true);
        }

        @Override
        public void close() throws Exception {
            listener.close();
            thread.join(1000);
        }
    }

    void exerciseLiveDirectories() throws Exception {
        File list = write("live-list.txt", "自有频道,#genre#\n测试,https://fixture.invalid/live.m3u8\n");
        String ext =
                android.util.Base64.encodeToString(
                        Cms.fileUri(list).getBytes("UTF-8"), android.util.Base64.NO_WRAP);
        String origin = Cms.fileUri(new File(folder, "config.json"));
        String proxy = "proxy://do=live&type=txt&ext=" + ext;
        String config =
                "{\"lives\":[{\"group\":\"目录\",\"ua\":\"Local-UA\",\"channels\":[{\"name\":\"本地直播\",\"urls\":[\""
                        + proxy
                        + "\"]},{\"name\":\"直接频道\",\"url\":\"https://fixture.invalid/direct.m3u8\"}]}]}";
        List<LiveCatalog.Source> sources = LiveCatalog.sources(config, origin);
        check("live_wrapper_split", sources.size() == 2 && sources.get(0).inline == null);
        LiveCatalog.Catalog catalogue = LiveCatalog.load(sources.get(0));
        check(
                "live_wrapper_local_package",
                catalogue.channelCount() == 1 && catalogue.groups.get(0).name.equals("自有频道"));
        check(
                "live_wrapper_header",
                catalogue
                        .groups
                        .get(0)
                        .channels
                        .get(0)
                        .streams
                        .get(0)
                        .headers
                        .get("User-Agent")
                        .equals("Local-UA"));
        check(
                "live_wrapper_preserves_inline",
                LiveCatalog.load(sources.get(1)).groups.get(0).channels.get(0).name.equals("直接频道"));
        LiveCatalog.Source loopback = new LiveCatalog.Source();
        loopback.url = "http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + ext;
        loopback.origin = origin;
        check(
                "live_wrapper_no_jar_required",
                !loopback.isLocalProxy() && LiveCatalog.load(loopback).channelCount() == 1);
        loopback.origin = "https://fixture.invalid/config.json";
        boolean rejected = false;
        try {
            LiveCatalog.load(loopback);
        } catch (IOException expected) {
            rejected = true;
        }
        check("live_remote_wrapper_cannot_read_local_file", rejected);
        try (LocalProxy local =
                new LocalProxy(
                        (Application) getTargetContext().getApplicationContext(),
                        new Cms.Config())) {
            JsEngine live =
                    engine(
                            "live-catalogue.js",
                            "module.exports={n:0,play(){return {url:proxyUrl({})};},proxy(p){"
                                    + "const h=JSON.parse(p['request-headers']);"
                                    + "if(p.origin!=='https://origin.test'||p.host!=='upstream.test'||"
                                    + "h.origin!==p.origin||h.host!==p.host)throw Error('live header mismatch');"
                                    + "return [200,'text/plain','Native,#genre#\\nChannel'+(++this.n)+',https://fixture.invalid/live.m3u8\\n'];}};");
            live.activate();
            String address = new JSONObject(live.player("", "catalogue")).getString("url");
            LiveCatalog.Source plugin = new LiveCatalog.Source();
            plugin.url = "proxy://" + new URL(address).getQuery();
            plugin.headers.put("oRiGiN", "https://origin.test");
            plugin.headers.put("hOsT", "upstream.test");
            check("live_plugin_scheme_starts_host", plugin.isLocalProxy());
            plugin.url = LocalProxy.rewrite(plugin.url);
            LiveCatalog.Catalog fromPlugin = LiveCatalog.load(plugin);
            check(
                    "live_plugin_native_catalogue_headers",
                    fromPlugin.groups.get(0).channels.get(0).name.equals("Channel1"));
            check(
                    "live_plugin_remote_channel_headers",
                    fromPlugin
                            .groups
                            .get(0)
                            .channels
                            .get(0)
                            .streams
                            .get(0)
                            .headers
                            .equals(plugin.headers));
            check(
                    "live_plugin_reload_preserves_instance",
                    LiveCatalog.load(plugin).groups.get(0).channels.get(0).name.equals("Channel2"));
        }
    }

    void exerciseLiveContent() throws Exception {
        Application app = (Application) getTargetContext().getApplicationContext();
        File jsFile =
                write(
                        "live-content.js",
                        "module.exports=class {init(ext){this.ext=ext;this.n=0;}"
                                + "async liveContent(url){if(this.ext!=='local-extension')throw Error('ext lost');"
                                + "if(url==='live:json')return [{name:'JS',channels:[{name:'JSON',url:'https://fixture.invalid/live.m3u8'}]}];"
                                + "if(url!=='live:txt')throw Error('input changed');"
                                + "return 'JS,#genre#\\nChannel'+(++this.n)+',https://fixture.invalid/live.m3u8';}};");
        File pyFile =
                write(
                        "live-content.py",
                        "class Spider:\n"
                                + "    def init(self, ext):\n        self.ext = ext\n"
                                + "    def liveContent(self, url):\n"
                                + "        assert self.ext == 'local-extension'\n"
                                + "        if url == 'live:json':\n"
                                + "            return [{'name':'PY','channels':[{'name':'JSON','url':'https://fixture.invalid/live.m3u8'}]}]\n"
                                + "        assert url == 'live:txt'\n"
                                + "        return 'PY,#genre#\\nPython,https://fixture.invalid/live.m3u8'\n");
        String config =
                new JSONObject()
                        .put(
                                "lives",
                                new org.json.JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "Same")
                                                        .put("api", Cms.fileUri(jsFile))
                                                        .put("ext", "local-extension")
                                                        .put("url", "live:txt"))
                                        .put(
                                                new JSONObject()
                                                        .put("name", "Same")
                                                        .put("api", Cms.fileUri(pyFile))
                                                        .put("ext", "local-extension")
                                                        .put("url", "live:txt")))
                        .toString();
        List<LiveCatalog.Source> sources =
                LiveCatalog.sources(config, Cms.fileUri(new File(folder, "config.json")));
        check(
                "live_api_config_selects_isolated_engines",
                sources.size() == 2
                        && !sources.get(0).plugin.key.equals(sources.get(1).plugin.key));
        for (int i = 0; i < sources.size(); i++) {
            LiveCatalog.Source source = sources.get(i);
            JsEngine raw = new JsEngine(app, new Cms.Config(), source.plugin);
            engines.add(raw);
            raw.activate();
            QueuedSourceEngine queued = new QueuedSourceEngine(raw);
            LiveCatalog.PluginLoader loader = (site, url) -> queued.liveContent(url);
            LiveCatalog.Catalog text = LiveCatalog.load(source, loader);
            check(
                    i == 0 ? "live_api_js_text" : "live_api_python_text",
                    text.channelCount() == 1
                            && text.groups.get(0).name.equals(i == 0 ? "JS" : "PY"));
            if (i == 0)
                check(
                        "live_api_js_state_retained",
                        LiveCatalog.load(source, loader)
                                .groups
                                .get(0)
                                .channels
                                .get(0)
                                .name
                                .equals("Channel2"));
            source.url = "live:json";
            check(
                    i == 0 ? "live_api_js_json" : "live_api_python_json",
                    LiveCatalog.load(source, loader)
                            .groups
                            .get(0)
                            .channels
                            .get(0)
                            .name
                            .equals("JSON"));
        }
        File jar = new File(folder, "live-fixture.jar");
        files.add(jar);
        try (InputStream in = getContext().getAssets().open("live-fixture.jar");
                FileOutputStream out = new FileOutputStream(jar)) {
            byte[] bytes = new byte[4096];
            int n;
            while ((n = in.read(bytes)) != -1) out.write(bytes, 0, n);
        }
        String jarConfig =
                new JSONObject()
                        .put("spider", Cms.fileUri(jar))
                        .put(
                                "lives",
                                new org.json.JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "JAR")
                                                        .put("api", "csp_LiveFixture")
                                                        .put("ext", "local-extension")
                                                        .put("url", "live:txt")))
                        .toString();
        LiveCatalog.Source source =
                LiveCatalog.sources(jarConfig, Cms.fileUri(new File(folder, "config.json"))).get(0);
        CspEngine nativeEngine = new CspEngine(app, new Cms.Config(), source.plugin);
        QueuedSourceEngine queued = new QueuedSourceEngine(nativeEngine);
        try {
            LiveCatalog.PluginLoader loader = (site, url) -> queued.liveContent(url);
            check(
                    "live_api_jar_text",
                    LiveCatalog.load(source, loader)
                            .groups
                            .get(0)
                            .channels
                            .get(0)
                            .name
                            .equals("Channel1"));
            check(
                    "live_api_jar_state_retained",
                    LiveCatalog.load(source, loader)
                            .groups
                            .get(0)
                            .channels
                            .get(0)
                            .name
                            .equals("Channel2"));
            source.url = "live:json";
            check(
                    "live_api_jar_json",
                    LiveCatalog.load(source, loader)
                            .groups
                            .get(0)
                            .channels
                            .get(0)
                            .name
                            .equals("JSON"));
        } finally {
            queued.close();
        }
        boolean rejected = false;
        Cms.Site plain = new Cms.Site();
        plain.type = 1;
        plain.api = "https://fixture.invalid/api";
        try {
            new JsonCmsEngine(plain).liveContent("live:txt");
        } catch (IOException expected) {
            rejected = true;
        }
        check("live_api_missing_method_explicit", rejected);
    }

    @Override
    public void onStart() {
        try {
            folder =
                    new File(
                            getTargetContext().getFilesDir(),
                            "source-host-probe-" + System.nanoTime());
            if (!folder.mkdir()) throw new IllegalStateException("fixture directory unavailable");
            exerciseLiveDirectories();
            exerciseLiveContent();
            write("data.json", "{\"title\":\"Local fixture\"}");
            write("helper.js", "exports.echo = value => Promise.resolve(value);");
            JsEngine js =
                    engine(
                            "index.js",
                            "const data=require('./data.json'), helper=require('./helper');"
                                    + "module.exports={"
                                    + "async init(ext){this.ready=await helper.echo(ext);},"
                                    + "async home(){await Promise.resolve();return {list:[{vod_id:this.ready,vod_name:data.title}]};},"
                                    + "async search(word,quick,page){return {list:[{vod_id:String(page),vod_name:await helper.echo(word)}]};},"
                                    + "async detail(id){return {list:[{vod_id:await helper.echo(id),vod_play_from:'Main',vod_play_url:'Film$fixture'}]};},"
                                    + "async play(flag,id){return {url:'https://fixture.invalid/'+await helper.echo(id)+'.mp4',header:{Referer:'https://fixture.invalid/'}};}"
                                    + "};");
            check(
                    "commonjs_async_init_before_home",
                    first(js.home()).getString("vod_id").equals("ready"));
            check(
                    "commonjs_json_dependency",
                    first(js.home()).getString("vod_name").equals("Local fixture"));
            JSONObject search = first(js.search("中文", 3));
            check(
                    "commonjs_async_search",
                    search.getString("vod_name").equals("中文")
                            && search.getString("vod_id").equals("3"));
            check("commonjs_async_detail", first(js.detail("42")).getString("vod_id").equals("42"));
            JSONObject play = new JSONObject(js.player("Main", "42"));
            check(
                    "commonjs_async_play",
                    play.getString("url").equals("https://fixture.invalid/42.mp4")
                            && play.getJSONObject("header")
                                    .getString("Referer")
                                    .equals("https://fixture.invalid/"));
            fails("missing_method_reported", "homeVod", () -> js.homeVideos());

            JsEngine named =
                    engine(
                            "named.mjs",
                            "export async function home(){return {list:[{vod_id:'named'}]}};");
            check(
                    "named_export_without_init",
                    first(named.home()).getString("vod_id").equals("named"));
            JsEngine errors =
                    engine(
                            "errors.js",
                            "module.exports={home:async()=>{throw Error('fixture rejection')},search:()=>new Promise(()=>{})};");
            fails("async_rejection_preserved", "fixture rejection", () -> errors.home());
            fails(
                    "pending_promise_fails_without_spin",
                    "did not settle",
                    () -> errors.search("x", 1));
            fails(
                    "async_init_failure_preserved",
                    "fixture init failure",
                    () ->
                            engine(
                                    "init-error.js",
                                    "module.exports={init:async()=>{throw Error('fixture init failure')},home:()=>({})};"));

            JsEngine py =
                    engine(
                            "fixture.py",
                            "from base.spider import Spider as Base\n"
                                    + "from bs4 import BeautifulSoup\n"
                                    + "import re, json\n"
                                    + "class Spider(Base):\n"
                                    + "    def init(self, ext): self.ready = ext\n"
                                    + "    def homeContent(self, filter):\n"
                                    + "        self.soup = BeautifulSoup('<div class=slide><a href=\"/a?x=1&amp;y=2\"> One &amp; <em>二</em> </a></div><div class=duplicate>bad</div>', 'html.parser')\n"
                                    + "        link = self.soup.select_one('.slide:not(.duplicate) a')\n"
                                    + "        return {'list':[{'vod_id':self.ready,'vod_name':'Python'}], 'html':link.get_text(' ', strip=True), 'href':link.get('href'), 'regex':re.sub(r'[#\\s]+', ' ', '## A 线').strip()}\n"
                                    + "    def searchContent(self, key, quick, pg='1'): return {'list':[{'vod_id':pg,'vod_name':key}], 'signed':json.dumps({'z':'中文','a':9007199254740993123456789},sort_keys=True,ensure_ascii=False,separators=(',',':')), 'big':str(json.loads('9007199254740993123456789'))}\n"
                                    + "    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_play_from':'Main','vod_play_url':'Film$fixture'}]}\n"
                                    + "    def playerContent(self, flag, id, vip): return {'url':'https://fixture.invalid/'+id+'.mp4'}\n");
            check("python_init_home", first(py.home()).getString("vod_id").equals("ready"));
            JSONObject html = new JSONObject(py.home());
            check("python_html_selector_text", html.getString("html").equals("One & 二"));
            check("python_html_entity_attribute", html.getString("href").equals("/a?x=1&y=2"));
            check("python_regex_substitution", html.getString("regex").equals("A 线"));
            check("python_search", first(py.search("中文", 2)).getString("vod_name").equals("中文"));
            JSONObject jsonResult = new JSONObject(py.search("中文", 2));
            check(
                    "python_json_signed_payload",
                    jsonResult
                            .getString("signed")
                            .equals("{\"a\":9007199254740993123456789,\"z\":\"中文\"}"));
            check(
                    "python_json_big_integer",
                    jsonResult.getString("big").equals("9007199254740993123456789"));
            JsEngine streams =
                    engine(
                            "streams.py",
                            "import io, json\n"
                                    + "class Spider:\n"
                                    + "    def homeContent(self, filter):\n"
                                    + "        text = io.StringIO(); json.dump({'name':'中文'}, text, ensure_ascii=False); text.seek(0)\n"
                                    + "        binary = io.BytesIO(bytes([0,255,128,65])); binary.seek(1); binary.write(b'X'); binary.seek(0)\n"
                                    + "        error = io.UnsupportedOperation('fixture')\n"
                                    + "        return {'text':json.load(text)['name'], 'bytes':list(binary.read()), 'exceptions':isinstance(error,OSError) and isinstance(error,ValueError)}\n");
            JSONObject streamResult = new JSONObject(streams.home());
            check("python_io_json_text", streamResult.getString("text").equals("中文"));
            check(
                    "python_io_binary",
                    streamResult.getJSONArray("bytes").toString().equals("[0,88,128,65]"));
            check("python_io_exception_bases", streamResult.getBoolean("exceptions"));
            check("python_detail", first(py.detail("42")).getString("vod_id").equals("42"));
            check(
                    "python_play",
                    new JSONObject(py.player("Main", "42"))
                            .getString("url")
                            .equals("https://fixture.invalid/42.mp4"));
            try (PythonSessionServer server = new PythonSessionServer()) {
                String base = "http://127.0.0.1:" + server.listener.getLocalPort();
                JsEngine session =
                        engine(
                                "session.py",
                                "import requests\n"
                                        + "class Spider:\n"
                                        + "    def homeContent(self, filter):\n"
                                        + "        with requests.Session() as s:\n"
                                        + "            s.headers.update({'X-Session':'local-fixture'})\n"
                                        + "            r = s.get('"
                                        + base
                                        + "/login', timeout=3)\n"
                                        + "            assert r.cookies.get('sid') == 'fixture'\n"
                                        + "            cookie = list(s.cookies)[0]\n"
                                        + "            assert cookie.name == 'sid' and cookie.value == 'fixture'\n"
                                        + "            assert cookie.domain == '127.0.0.1' and cookie.path == '/auth'\n"
                                        + "            assert not cookie.secure and cookie.expires is None and not cookie.domain_specified\n"
                                        + "            assert dict(s.cookies) == {'sid':'fixture'}\n"
                                        + "            return s.get('"
                                        + base
                                        + "/auth/resource', timeout=3).json()\n");
                // Do not spend the listener's accept deadline initializing the Python VM.
                server.thread.start();
                try {
                    check(
                            "python_session_real_http",
                            first(session.home()).getString("vod_id").equals("session"));
                } catch (Throwable failure) {
                    report.put("python_session_fixture_requests", server.requests);
                    report.put("python_session_fixture_error", String.valueOf(server.error));
                    throw failure;
                }
                server.thread.join(1000);
                check(
                        "python_session_cookie_scope",
                        server.requests == 2
                                && server.error == null
                                && server.cookie.equals("sid=fixture"));
                check(
                        "python_session_headers_persist",
                        server.sessionHeader.equals("local-fixture"));
            }
            try (PythonBinaryServer server = new PythonBinaryServer()) {
                String base = "http://127.0.0.1:" + server.listener.getLocalPort();
                JsEngine binary =
                        engine(
                                "binary.py",
                                "import requests\n"
                                        + "class Spider:\n"
                                        + "    def homeContent(self, filter):\n"
                                        + "        data = bytes([0,255,128,65])\n"
                                        + "        r = requests.post('"
                                        + base
                                        + "/upload',data=data,timeout=3,headers={'Content-Type':'application/octet-stream'})\n"
                                        + "        assert r.json()['bytes'] == list(data)\n"
                                        + "        assert requests.post('"
                                        + base
                                        + "/empty',data=b'',timeout=3).json()['bytes'] == []\n"
                                        + "        return {'list':[{'vod_id':'binary','vod_name':'Binary upload verified'}]}\n");
                server.thread.start();
                try {
                    check(
                            "python_binary_real_http",
                            first(binary.home()).getString("vod_id").equals("binary"));
                } catch (Throwable failure) {
                    report.put("python_binary_fixture_requests", server.requests);
                    report.put("python_binary_fixture_error", String.valueOf(server.error));
                    throw failure;
                }
                server.thread.join(1000);
                check(
                        "python_binary_exact_bytes",
                        server.requests == 2
                                && server.error == null
                                && Arrays.equals(
                                        server.uploaded,
                                        new byte[] {0, (byte) 255, (byte) 128, 65}));
                check("python_empty_binary_body", server.empty != null && server.empty.length == 0);
            }
            exerciseScriptProxy();
            exerciseNativeDeadlines();
            exerciseFullSpiderContract();
            exerciseCatvodContract();
            HttpT4Checks.run(this::check);
            report.put("passed", true);
        } catch (Throwable failure) {
            android.util.Log.e("SourceHostProbe", "source fixture failed", failure);
            try {
                report.put("passed", false).put("error", failure.toString());
            } catch (Exception ignored) {
            }
        } finally {
            for (JsEngine engine : engines) engine.close();
            for (File file : files) file.delete();
            if (folder != null) folder.delete();
        }
        try {
            report.put("checks", checks);
        } catch (Exception ignored) {
        }
        Bundle result = new Bundle();
        result.putString("result", report.toString());
        sendStatus(0, result);
        finish(android.app.Activity.RESULT_OK, new Bundle());
    }
}
