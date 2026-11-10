package com.pilipala.emby;

import java.io.*;
import java.net.*;
import java.util.*;
import org.json.*;

/** Emby REST client shared by Android standard and API 14 Lite. */
public final class EmbyLibrary {
    public static final String PREFIX = "emby://account/";
    private static final int PAGE_SIZE = 40;
    private final String base, user, token, device, account;

    public static String accountKey(JSONObject session) throws Exception {
        String identity = normalize(session.getString("base")) + "\n" + session.getString("user");
        byte[] digest =
                java.security.MessageDigest.getInstance("SHA-256")
                        .digest(identity.getBytes("UTF-8"));
        StringBuilder key = new StringBuilder();
        for (byte value : digest) key.append(String.format(Locale.US, "%02x", value & 255));
        return key.toString();
    }

    public Map<String, String> imageHeaders(String address) throws Exception {
        URL url = new URL(address);
        if (!address.substring(
                                0,
                                address.indexOf('#') < 0 ? address.length() : address.indexOf('#'))
                        .startsWith(base + "/Items/")
                || !url.getPath().matches(".*/Items/[a-zA-Z0-9_-]+/Images/Primary"))
            throw new IOException("Emby 海报地址与账户不匹配");
        Map<String, String> h = new HashMap<String, String>();
        h.put("X-Emby-Token", token);
        return h;
    }

    public EmbyLibrary(JSONObject session) throws Exception {
        account = accountKey(session);
        base = normalize(session.getString("base"));
        user = segment(session.getString("user"));
        token = session.getString("token");
        device = session.getString("device");
    }

    static String normalize(String raw) throws Exception {
        URL url = new URL(raw.trim());
        if (!(url.getProtocol().equals("http") || url.getProtocol().equals("https"))
                || url.getHost().length() == 0
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null) throw new IOException("请输入 Emby 服务器根地址");
        String root = url.toExternalForm().replaceAll("/+$", "");
        return root.toLowerCase(Locale.US).endsWith("/emby") ? root : root + "/emby";
    }

    private static String segment(String value) throws IOException {
        if (!value.matches("[a-zA-Z0-9_-]+")) throw new IOException("Emby 媒体或账户编号无效");
        return value;
    }

    private static String encode(String value) throws Exception {
        return URLEncoder.encode(value, "UTF-8");
    }

    private static JSONObject request(String url, String device, String token, JSONObject body)
            throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(10000);
            c.setReadTimeout(15000);
            c.setRequestProperty(
                    "Authorization",
                    "Emby Client=\"Marco Movie\", Device=\"Android\", DeviceId=\""
                            + device
                            + "\", Version=\"1\"");
            if (token.length() > 0) c.setRequestProperty("X-Emby-Token", token);
            c.setRequestProperty("Accept", "application/json");
            if (body != null) {
                c.setRequestMethod("POST");
                c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                c.setDoOutput(true);
                OutputStream stream = c.getOutputStream();
                try {
                    stream.write(body.toString().getBytes("UTF-8"));
                } finally {
                    stream.close();
                }
            }
            int status = c.getResponseCode();
            if (status == 401 || status == 403) throw new IOException("Emby 拒绝访问，请检查账号或重新登录");
            if (status < 200 || status >= 300)
                throw new IOException("Emby 请求失败（HTTP " + status + "）");
            InputStream in = c.getInputStream();
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (out.size() + n > 4 * 1024 * 1024) throw new IOException("Emby 响应过大");
                    out.write(buf, 0, n);
                }
                return out.size() == 0 ? new JSONObject() : new JSONObject(out.toString("UTF-8"));
            } finally {
                in.close();
            }
        } finally {
            c.disconnect();
        }
    }

    public static JSONObject login(String address, String name, String password, String device)
            throws Exception {
        String base = normalize(address);
        JSONObject response =
                request(
                        base + "/Users/AuthenticateByName",
                        device,
                        "",
                        new JSONObject().put("Username", name).put("Pw", password));
        String token = response.getString("AccessToken");
        if (token.length() == 0) throw new IOException("Emby 未返回登录凭据");
        return new JSONObject()
                .put("base", base)
                .put("token", token)
                .put("device", device)
                .put("user", segment(response.getJSONObject("User").getString("Id")));
    }

    public Map<String, String> headersFor(String address) throws Exception {
        Map<String, String> h = new HashMap<String, String>();
        if (address.startsWith(base + "/Videos/")) h.put("X-Emby-Token", token);
        return h;
    }

    private static Map<String, String> query(String raw) throws Exception {
        Map<String, String> values = new LinkedHashMap<String, String>();
        if (raw == null) return values;
        for (String entry : raw.split("&")) {
            String[] pair = entry.split("=", 2);
            values.put(
                    URLDecoder.decode(pair[0], "UTF-8"),
                    pair.length == 2 ? URLDecoder.decode(pair[1], "UTF-8") : "");
        }
        return values;
    }

    private static String queryString(Map<String, String> values) throws Exception {
        StringBuilder out = new StringBuilder();
        for (Map.Entry<String, String> entry : values.entrySet()) {
            if (out.length() > 0) out.append('&');
            out.append(encode(entry.getKey())).append('=').append(encode(entry.getValue()));
        }
        return out.toString();
    }

    public JSONObject resolve(String address, boolean legacyPlayer) throws Exception {
        URI original = new URI(address);
        String prefix = new URI(base).getPath() + "/Videos/";
        if (headersFor(address).isEmpty() || !original.getPath().startsWith(prefix))
            throw new IOException("Emby 播放地址与账户不匹配");
        String rest = original.getPath().substring(prefix.length());
        int end = rest.indexOf('/');
        if (end < 1) throw new IOException("Emby 剧集编号无效");
        String id = segment(rest.substring(0, end));
        Map<String, String> q = query(original.getRawQuery());
        String wanted = q.containsKey("MediaSourceId") ? q.get("MediaSourceId") : id;
        JSONObject profile =
                new JSONObject()
                        .put("Name", "Marco Movie")
                        .put("MaxStreamingBitrate", 80000000)
                        .put(
                                "DirectPlayProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put(
                                                                "Container",
                                                                legacyPlayer
                                                                        ? "mp4,m4v"
                                                                        : "mp4,m4v,mkv,mov,ts")
                                                        .put("VideoCodec", "h264")
                                                        .put("AudioCodec", "aac,mp3")))
                        .put(
                                "TranscodingProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put("Container", "ts")
                                                        .put("Protocol", "hls")
                                                        .put("VideoCodec", "h264")
                                                        .put("AudioCodec", "aac")
                                                        .put("Context", "Streaming")
                                                        .put("MaxAudioChannels", "2")
                                                        .put("MinSegments", 1)));
        JSONObject body =
                new JSONObject()
                        .put("UserId", user)
                        .put("IsPlayback", true)
                        .put("AutoOpenLiveStream", false)
                        .put("EnableDirectPlay", false)
                        .put("EnableDirectStream", true)
                        .put("EnableTranscoding", true)
                        .put("MaxStreamingBitrate", 80000000)
                        .put("DeviceProfile", profile);
        if (!wanted.equals(id)) body.put("MediaSourceId", wanted);
        JSONObject info = request(base + "/Items/" + id + "/PlaybackInfo", device, token, body);
        if (!info.optString("ErrorCode").isEmpty()) throw new IOException("Emby 无法为当前账号或设备提供播放方案");
        JSONArray sources = info.optJSONArray("MediaSources");
        JSONObject source = null;
        if (sources != null)
            for (int i = 0; i < sources.length(); i++) {
                JSONObject candidate = sources.optJSONObject(i);
                if (candidate != null && wanted.equals(candidate.optString("Id")))
                    source = candidate;
            }
        if (source == null && wanted.equals(id) && sources != null && sources.length() > 0)
            source = sources.optJSONObject(0);
        if (source == null || source.optString("Id").isEmpty())
            throw new IOException("Emby 未返回所选媒体版本");
        if (source.optBoolean("RequiresOpening")) throw new IOException("当前 Emby 资源需要实时流打开协议");
        String session = info.optString("PlaySessionId"), sourceId = source.getString("Id");
        if (session.isEmpty()) throw new IOException("Emby 播放会话缺失");
        boolean direct =
                source.optBoolean("SupportsDirectStream")
                        || source.optBoolean("SupportsDirectPlay");
        Map<String, String> params = new LinkedHashMap<String, String>();
        String stream;
        if (direct) {
            stream = base + "/Videos/" + id + "/stream";
            params.put("Static", "true");
        } else {
            if (!source.optBoolean("SupportsTranscoding")
                    || source.optString("TranscodingUrl").isEmpty())
                throw new IOException("Emby 没有可用的直连或转码方案");
            URI target =
                    new URL(new URL(base + "/"), source.getString("TranscodingUrl"))
                            .toURI()
                            .normalize();
            URI server = new URI(base);
            if (!server.getScheme().equalsIgnoreCase(target.getScheme())
                    || !server.getAuthority().equalsIgnoreCase(target.getAuthority())
                    || target.getUserInfo() != null
                    || !target.getPath().startsWith(prefix))
                throw new IOException("Emby 转码地址与服务器不匹配");
            params.putAll(query(target.getRawQuery()));
            for (String key : new ArrayList<String>(params.keySet()))
                if (key.equalsIgnoreCase("api_key") || key.equalsIgnoreCase("x-emby-token"))
                    params.remove(key);
            stream =
                    new URI(target.getScheme(), target.getAuthority(), target.getPath(), null, null)
                            .toString();
        }
        params.put("MediaSourceId", sourceId);
        params.put("PlaySessionId", session);
        params.put("DeviceId", device);
        JSONObject metadata =
                new JSONObject()
                        .put("ItemId", id)
                        .put("MediaSourceId", sourceId)
                        .put("PlaySessionId", session)
                        .put("PlayMethod", direct ? "DirectStream" : "Transcode")
                        .put("CanSeek", true);
        return new JSONObject()
                .put("parse", 0)
                .put("url", stream + "?" + queryString(params))
                .put("header", new JSONObject(headersFor(stream)))
                .put("embySession", metadata);
    }

    public void report(
            JSONObject metadata, String event, long positionMs, boolean paused, boolean stopped)
            throws Exception {
        JSONObject body =
                new JSONObject(metadata.toString())
                        .put("PositionTicks", Math.max(0, positionMs) * 10000L)
                        .put("IsPaused", paused)
                        .put("EventName", event);
        String suffix = stopped ? "/Stopped" : event.equals("Start") ? "" : "/Progress";
        request(base + "/Sessions/Playing" + suffix, device, token, body);
    }

    public Reporter track(JSONObject metadata) {
        return new Reporter(this, metadata);
    }

    /** Coalesces telemetry so slow servers cannot create an unbounded per-player queue. */
    public static final class Reporter implements Runnable {
        private static final java.util.concurrent.ThreadPoolExecutor EXECUTOR =
                new java.util.concurrent.ThreadPoolExecutor(
                        0,
                        1,
                        15,
                        java.util.concurrent.TimeUnit.SECONDS,
                        new java.util.concurrent.ArrayBlockingQueue<Runnable>(32),
                        new java.util.concurrent.ThreadFactory() {
                            public Thread newThread(Runnable work) {
                                Thread t = new Thread(work, "emby-checkin");
                                t.setDaemon(true);
                                return t;
                            }
                        });
        private final EmbyLibrary library;
        private final JSONObject metadata;
        private boolean running, pending, stopped, started, paused;
        private long position, lastUpdate = -10000;
        private final long began = System.nanoTime();
        private String event = "TimeUpdate";

        private Reporter(EmbyLibrary library, JSONObject metadata) {
            this.library = library;
            this.metadata = metadata;
        }

        public synchronized boolean matches(JSONObject other) {
            return !stopped
                    && other != null
                    && metadata.optString("PlaySessionId").equals(other.optString("PlaySessionId"));
        }

        public synchronized void update(long positionMs, boolean isPaused) {
            if (stopped) return;
            position = Math.max(0, positionMs);
            boolean changed = paused != isPaused;
            paused = isPaused;
            long now = (System.nanoTime() - began) / 1000000;
            if (!changed && now - lastUpdate < 10000) return;
            lastUpdate = now;
            event = changed ? (paused ? "Pause" : "Unpause") : "TimeUpdate";
            pending = true;
            schedule();
        }

        public synchronized void stop(long positionMs) {
            if (stopped) return;
            stopped = true;
            position = Math.max(0, positionMs);
            pending = true;
            schedule();
        }

        private void schedule() {
            if (running) return;
            running = true;
            try {
                EXECUTOR.execute(this);
            } catch (java.util.concurrent.RejectedExecutionException busy) {
                running = false;
            }
        }

        public void run() {
            while (true) {
                long at;
                boolean pause, stop;
                String why;
                synchronized (this) {
                    if (!pending) {
                        running = false;
                        return;
                    }
                    pending = false;
                    at = position;
                    pause = paused;
                    stop = stopped;
                    why = started ? event : "Start";
                }
                try {
                    library.report(metadata, why, at, pause, stop);
                    synchronized (this) {
                        if (!stop) started = true;
                    }
                } catch (Exception ignored) {
                    /* Check-in failure must not interrupt local video. */
                }
            }
        }
    }

    private JSONObject get(String path) throws Exception {
        return request(base + path, device, token, null);
    }

    private JSONObject card(JSONObject i) throws Exception {
        String id = segment(i.getString("Id"));
        String tag =
                i.optJSONObject("ImageTags") == null
                        ? ""
                        : i.getJSONObject("ImageTags").optString("Primary");
        return new JSONObject()
                .put("vod_id", id)
                .put("vod_name", i.optString("Name"))
                .put("vod_year", i.optString("ProductionYear"))
                .put("vod_content", i.optString("Overview"))
                .put(
                        "vod_pic",
                        base
                                + "/Items/"
                                + id
                                + "/Images/Primary?maxWidth=500&tag="
                                + encode(tag)
                                + "#mm-emby="
                                + account);
    }

    public JSONObject home() throws Exception {
        JSONArray views = get("/Users/" + user + "/Views").getJSONArray("Items"),
                groups = new JSONArray();
        for (int i = 0; i < views.length(); i++) {
            JSONObject row = views.getJSONObject(i);
            groups.put(
                    new JSONObject()
                            .put("type_id", row.getString("Id"))
                            .put("type_name", row.optString("Name")));
        }
        return new JSONObject().put("class", groups).put("list", new JSONArray());
    }

    public JSONObject list(String parent, String query, int page) throws Exception {
        int start = Math.max(0, page - 1) * PAGE_SIZE;
        String path =
                "/Users/"
                        + user
                        + "/Items?Recursive=true&IncludeItemTypes=Movie,Series,Video&Fields=Overview,ProductionYear&Limit="
                        + PAGE_SIZE
                        + "&StartIndex="
                        + start;
        if (parent.length() > 0) path += "&ParentId=" + segment(parent);
        if (query.length() > 0) path += "&SearchTerm=" + encode(query);
        JSONObject response = get(path);
        JSONArray rows = response.getJSONArray("Items"), cards = new JSONArray();
        for (int i = 0; i < rows.length(); i++) cards.put(card(rows.getJSONObject(i)));
        return new JSONObject()
                .put("list", cards)
                .put("page", page)
                .put(
                        "pagecount",
                        Math.max(
                                page,
                                (response.optInt("TotalRecordCount", start + rows.length())
                                                + PAGE_SIZE
                                                - 1)
                                        / PAGE_SIZE));
    }

    public JSONObject detail(String id) throws Exception {
        JSONObject item =
                get("/Users/" + user + "/Items/" + segment(id) + "?Fields=MediaSources,Overview");
        JSONObject video = card(item);
        List<String> lines = new ArrayList<String>();
        if (item.optString("Type").equals("Series")) {
            int start = 0;
            while (start < 10000) {
                JSONObject page =
                        get(
                                "/Shows/"
                                        + segment(id)
                                        + "/Episodes?UserId="
                                        + user
                                        + "&Fields=MediaSources&Limit=200&StartIndex="
                                        + start);
                JSONArray episodes = page.getJSONArray("Items");
                for (int i = 0; i < episodes.length(); i++)
                    addEpisode(lines, episodes.getJSONObject(i));
                start += episodes.length();
                if (episodes.length() == 0 || start >= page.optInt("TotalRecordCount", start))
                    break;
            }
        } else addEpisode(lines, item);
        StringBuilder flat = new StringBuilder();
        for (String e : lines) {
            if (flat.length() > 0) flat.append('#');
            flat.append(e);
        }
        return new JSONObject()
                .put(
                        "list",
                        new JSONArray()
                                .put(
                                        video.put("vod_play_from", "Emby")
                                                .put("vod_play_url", flat.toString())));
    }

    private void addEpisode(List<String> episodes, JSONObject item) throws Exception {
        String id = segment(item.getString("Id")), source = id;
        JSONArray media = item.optJSONArray("MediaSources");
        if (media != null && media.length() > 0)
            source = media.getJSONObject(0).optString("Id", id);
        String label = item.optString("Name", "正片").replace('#', '＃').replace('$', '＄');
        if (item.has("ParentIndexNumber") && item.has("IndexNumber"))
            label =
                    "S"
                            + item.getInt("ParentIndexNumber")
                            + "E"
                            + item.getInt("IndexNumber")
                            + " "
                            + label;
        episodes.add(
                label
                        + "$"
                        + base
                        + "/Videos/"
                        + id
                        + "/stream?Static=true&MediaSourceId="
                        + encode(source));
    }
}
