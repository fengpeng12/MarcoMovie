// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.util.Base64;
import android.util.Xml;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.zip.GZIPInputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;
import org.xmlpull.v1.XmlPullParser;

/**
 * API 14-only, non-executing CMS & Live adapter.
 *
 * <p>Supports JSON CMS ({@code type=1}), MacCMS XML ({@code type=0}), Emby accounts, GZIP / Base64
 * / 2423 Hex-AES configurations, and M3U / TXT live channel lists. Unsupported plugins remain
 * visible and explicitly labeled.
 */
public final class LiteCatalog {
    public static final int MAX_BYTES = 2 * 1024 * 1024;
    public static final long REQUEST_BUDGET_NS = 18000000000L;
    private static final Set<HttpURLConnection> IN_FLIGHT =
            Collections.synchronizedSet(new HashSet<HttpURLConnection>());

    public static void cancelAll() {
        HttpURLConnection[] active;
        synchronized (IN_FLIGHT) {
            active = IN_FLIGHT.toArray(new HttpURLConnection[IN_FLIGHT.size()]);
            IN_FLIGHT.clear();
        }
        for (int i = 0; i < active.length; i++) {
            try {
                active[i].disconnect();
            } catch (Exception ignored) {
            }
        }
    }

    public static final class Site {
        public String key, name, api, playUrl = "";
        public int type;
        public boolean supported;
        public boolean searchable = true;
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
    }

    public static final class Category {
        public String id, name;
    }

    public static final class LiveSource {
        public String name = "";
        public String url = "";
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
    }

    public static final class LiveChannel {
        public String name = "";
        public String group = "";
        public final List<String> urls = new ArrayList<String>();
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
    }

    public static final class LiveGroup {
        public String name = "";
        public final List<LiveChannel> channels = new ArrayList<LiveChannel>();
    }

    public static String http(String value) throws Exception {
        URL u = new URL(value.trim());
        String scheme = u.getProtocol();
        if ((!"http".equals(scheme) && !"https".equals(scheme))
                || u.getHost().length() == 0
                || u.getUserInfo() != null) {
            throw new IOException("请输入有效的 HTTP(S) 配置地址");
        }
        return u.toExternalForm();
    }

    public static String withoutComments(String s) {
        if (s == null) return "";
        StringBuilder out = new StringBuilder(s.length());
        boolean inStr = false, esc = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (inStr) {
                out.append(c);
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
            } else {
                if (c == '"') {
                    inStr = true;
                    out.append(c);
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '/') {
                    i += 2;
                    while (i < s.length() && s.charAt(i) != '\n') i++;
                    if (i < s.length()) out.append('\n');
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '*') {
                    i += 2;
                    while (i + 1 < s.length() && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/'))
                        i++;
                    i++;
                } else out.append(c);
            }
        }
        return out.toString();
    }

    public static String fetch(String address, Map<String, String> headers) throws Exception {
        String current = http(address);
        long deadlineNs = System.nanoTime() + REQUEST_BUDGET_NS;
        for (int redirects = 0; redirects < 6; redirects++) {
            if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                throw new InterruptedIOException();
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            IN_FLIGHT.add(c);
            if (c instanceof javax.net.ssl.HttpsURLConnection)
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            int remainingMs = (int) Math.max(1000L, (deadlineNs - System.nanoTime()) / 1000000L);
            c.setConnectTimeout(Math.min(10000, remainingMs));
            c.setReadTimeout(Math.min(12000, remainingMs));
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", "MarcoMovie-Lite/0.5");
            c.setRequestProperty("Accept-Encoding", "identity");
            if (headers != null)
                for (Map.Entry<String, String> h : headers.entrySet())
                    c.setRequestProperty(h.getKey(), h.getValue());
            try {
                int status = c.getResponseCode();
                if (status >= 300 && status < 400) {
                    String next =
                            http(new URL(new URL(current), c.getHeaderField("Location")).toString());
                    URL before = new URL(current), after = new URL(next);
                    if ("https".equals(before.getProtocol()) && "http".equals(after.getProtocol()))
                        throw new IOException("不支持降级连接");
                    if (!before.getAuthority().equals(after.getAuthority())) headers = null;
                    current = next;
                    continue;
                }
                if (status != 200) throw new IOException("服务器返回 HTTP " + status);
                InputStream in = c.getInputStream();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] b = new byte[8192];
                int n;
                while ((n = in.read(b)) != -1) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                        throw new InterruptedIOException();
                    if (out.size() + n > MAX_BYTES) throw new IOException("配置或列表超过大小限制");
                    out.write(b, 0, n);
                }
                return decodeText(out.toByteArray());
            } finally {
                IN_FLIGHT.remove(c);
                c.disconnect();
            }
        }
        throw new IOException("重定向过多");
    }

    public static String decodeText(byte[] bytes) throws IOException {
        if (bytes.length >= 2 && (bytes[0] & 255) == 0x1f && (bytes[1] & 255) == 0x8b) {
            GZIPInputStream gz = new GZIPInputStream(new ByteArrayInputStream(bytes));
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = gz.read(buf)) != -1) {
                    if (out.size() + n > MAX_BYTES) throw new IOException("解压后内容超过大小限制");
                    out.write(buf, 0, n);
                }
                bytes = out.toByteArray();
            } finally {
                gz.close();
            }
        }
        if (bytes.length >= 2 && (bytes[0] & 255) == 255 && (bytes[1] & 255) == 254)
            return new String(bytes, 2, bytes.length - 2, "UTF-16LE");
        if (bytes.length >= 2 && (bytes[0] & 255) == 254 && (bytes[1] & 255) == 255)
            return new String(bytes, 2, bytes.length - 2, "UTF-16BE");
        return new String(bytes, "UTF-8");
    }

    public static String decrypt2423(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        if (!s.startsWith("2423")) return raw;
        try {
            int keyEnd = s.indexOf("2324");
            if (keyEnd < 4) return raw;
            String keyHex = s.substring(4, keyEnd);
            String body = s.substring(keyEnd + 4);
            if (body.length() < 26) return raw;
            String ivHex = body.substring(body.length() - 26);
            String cipherHex = body.substring(0, body.length() - 26);
            String keyStr = new String(hexToBytes(keyHex), "UTF-8").trim();
            String ivStr = new String(hexToBytes(ivHex), "UTF-8").trim();
            byte[] keyBytes = padRight16(keyStr.getBytes("UTF-8"));
            byte[] ivBytes = padRight16(ivStr.getBytes("UTF-8"));
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            cipher.init(
                    Cipher.DECRYPT_MODE,
                    new SecretKeySpec(keyBytes, "AES"),
                    new IvParameterSpec(ivBytes));
            byte[] decrypted = cipher.doFinal(hexToBytes(cipherHex));
            return new String(decrypted, "UTF-8").trim();
        } catch (Exception ignored) {
            return raw;
        }
    }

    private static byte[] padRight16(byte[] src) {
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            out[i] = i < src.length ? src[i] : (byte) '0';
        }
        return out;
    }

    private static byte[] hexToBytes(String hex) {
        int len = hex.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            out[i] = (byte) ((Math.max(0, hi) << 4) | Math.max(0, lo));
        }
        return out;
    }

    public static JSONObject decodeConfig(String raw) throws Exception {
        String cleaned = withoutComments(raw).trim();
        if (cleaned.startsWith("\ufeff")) cleaned = cleaned.substring(1).trim();
        if (cleaned.startsWith("2423")) {
            cleaned = withoutComments(decrypt2423(cleaned)).trim();
        }
        int star = cleaned.indexOf("**");
        if (!cleaned.startsWith("{") && !cleaned.startsWith("[") && star >= 0) {
            try {
                String decoded =
                        new String(
                                Base64.decode(
                                        cleaned.substring(star + 2).replaceAll("\\s+", ""),
                                        Base64.DEFAULT),
                                "UTF-8");
                if (decoded.trim().startsWith("{") || decoded.trim().startsWith("["))
                    cleaned = withoutComments(decoded).trim();
            } catch (Exception ignored) {
            }
        }
        if (cleaned.startsWith("[")) {
            JSONArray sites = new JSONArray(cleaned);
            if (sites.length() == 0) throw new IOException("配置数组需要包含带 api 的来源对象");
            for (int i = 0; i < sites.length(); i++) {
                JSONObject item = sites.optJSONObject(i);
                Object api = item == null ? null : item.opt("api");
                if (!(api instanceof String) || ((String) api).trim().length() == 0)
                    throw new IOException("配置数组需要包含带 api 的来源对象");
            }
            return new JSONObject().put("sites", sites);
        }
        return new JSONObject(cleaned);
    }

    public static String importConfig(String raw, String origin) throws Exception {
        return com.pilipala.source.Warehouse.resolve(
                raw,
                origin,
                new com.pilipala.source.Warehouse.Reader() {
                    public String read(String url) throws Exception {
                        return fetch(url, null);
                    }
                },
                new com.pilipala.source.Warehouse.Decoder() {
                    public JSONObject decode(String text) throws Exception {
                        return decodeConfig(text);
                    }
                },
                new com.pilipala.source.Warehouse.Validator() {
                    public void validate(String text, String base) throws Exception {
                        parse(text, base);
                    }
                });
    }

    public static List<Site> parse(String raw, String base) throws Exception {
        JSONObject document = decodeConfig(raw);
        base = document.optString(com.pilipala.source.Warehouse.ORIGIN, base);
        JSONArray rows = document.optJSONArray("sites");
        if ((rows == null || rows.length() == 0) && document.optString("api").length() > 0)
            rows = new JSONArray().put(document);
        if (rows == null || rows.length() == 0) throw new IOException("配置没有 sites 列表");
        List<Site> sites = new ArrayList<Site>();
        for (int i = 0; i < rows.length() && i < 500; i++) {
            JSONObject row = rows.getJSONObject(i);
            Site s = new Site();
            s.name = row.optString("name", "未命名");
            s.key = row.optString("key", s.name + "_" + i);
            s.type = row.optInt("type", -1);
            s.api = row.optString("api");
            s.playUrl = row.optString("playUrl", "").trim();
            s.searchable = row.optInt("searchable", 1) != 0;
            if (!s.api.startsWith("csp_")
                    && !s.api.startsWith("js_")
                    && base != null
                    && base.length() > 0) {
                try {
                    s.api = new URL(new URL(base), s.api).toString();
                } catch (Exception ignored) {
                }
            }
            boolean directPlayUrl =
                    s.playUrl.length() == 0
                            || s.playUrl.startsWith("http://")
                            || s.playUrl.startsWith("https://");
            s.supported = (s.type == 1 || s.type == 0) && directPlayUrl;
            try {
                http(s.api);
            } catch (Exception invalid) {
                s.supported = false;
            }
            if (s.api.startsWith("emby://account/")) s.supported = true;
            String ua = row.optString("ua", "").trim();
            if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
                s.headers.put("User-Agent", ua);
            }
            putSafeHeaders(s.headers, row.optJSONObject("header"));
            putSafeHeaders(s.headers, row.optJSONObject("headers"));
            JSONObject extObj = row.optJSONObject("ext");
            if (extObj != null) {
                String extUa = extObj.optString("ua", "").trim();
                if (extUa.length() > 0 && extUa.indexOf('\r') < 0 && extUa.indexOf('\n') < 0) {
                    s.headers.put("User-Agent", extUa);
                }
                putSafeHeaders(s.headers, extObj.optJSONObject("header"));
                putSafeHeaders(s.headers, extObj.optJSONObject("headers"));
            }
            sites.add(s);
        }
        return sites;
    }

    private static void putSafeHeaders(Map<String, String> target, JSONObject hs) {
        if (hs == null) return;
        Iterator<String> keys = hs.keys();
        while (keys.hasNext()) {
            String k = keys.next(), v = hs.optString(k);
            if (k.indexOf('\r') < 0
                    && k.indexOf('\n') < 0
                    && v.indexOf('\r') < 0
                    && v.indexOf('\n') < 0) {
                target.put(k, v);
            }
        }
    }

    public static List<Category> categories(String raw) {
        List<Category> out = new ArrayList<Category>();
        try {
            JSONObject obj = parseCmsResponse(raw);
            JSONArray arr = obj.optJSONArray("class");
            if (arr != null)
                for (int i = 0; i < Math.min(arr.length(), 30); i++) {
                    JSONObject c = arr.optJSONObject(i);
                    if (c == null) continue;
                    String id = c.optString("type_id").trim(),
                            name = c.optString("type_name").trim();
                    if (id.length() > 0 && name.length() > 0) {
                        Category cat = new Category();
                        cat.id = id;
                        cat.name = name;
                        out.add(cat);
                    }
                }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static JSONObject parseCmsResponse(String raw) throws Exception {
        if (raw == null) throw new IOException("空响应");
        String trimmed = raw.trim();
        if (trimmed.startsWith("\ufeff")) trimmed = trimmed.substring(1).trim();
        if (trimmed.startsWith("<")) {
            return parseXmlCms(trimmed);
        }
        return new JSONObject(trimmed);
    }

    public static JSONObject parseXmlCms(String xml) throws Exception {
        XmlPullParser parser = Xml.newPullParser();
        parser.setInput(new StringReader(xml));
        JSONArray classes = new JSONArray();
        JSONArray list = new JSONArray();
        int page = 1, pagecount = 1;
        JSONObject currentVideo = null;
        List<String> froms = new ArrayList<String>();
        List<String> urls = new ArrayList<String>();
        String currentDdFlag = "";
        int event = parser.getEventType();
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG) {
                String tag = parser.getName();
                if ("list".equalsIgnoreCase(tag)) {
                    try {
                        String pg = parser.getAttributeValue(null, "page");
                        String pc = parser.getAttributeValue(null, "pagecount");
                        if (pg != null) page = Math.max(1, Integer.parseInt(pg.trim()));
                        if (pc != null) pagecount = Math.max(1, Integer.parseInt(pc.trim()));
                    } catch (Exception ignored) {
                    }
                } else if ("ty".equalsIgnoreCase(tag)) {
                    String id = parser.getAttributeValue(null, "id");
                    String name = safeNextText(parser).trim();
                    if (id != null && id.trim().length() > 0 && name.length() > 0) {
                        classes.put(
                                new JSONObject().put("type_id", id.trim()).put("type_name", name));
                    }
                } else if ("video".equalsIgnoreCase(tag)) {
                    currentVideo = new JSONObject();
                    froms.clear();
                    urls.clear();
                } else if (currentVideo != null) {
                    if ("id".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_id", safeNextText(parser).trim());
                    } else if ("name".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_name", safeNextText(parser).trim());
                    } else if ("pic".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_pic", safeNextText(parser).trim());
                    } else if ("type".equalsIgnoreCase(tag)) {
                        currentVideo.put("type_name", safeNextText(parser).trim());
                    } else if ("year".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_year", safeNextText(parser).trim());
                    } else if ("area".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_area", safeNextText(parser).trim());
                    } else if ("note".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_remarks", safeNextText(parser).trim());
                    } else if ("actor".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_actor", safeNextText(parser).trim());
                    } else if ("director".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_director", safeNextText(parser).trim());
                    } else if ("des".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_content", safeNextText(parser).trim());
                    } else if ("dd".equalsIgnoreCase(tag)) {
                        String flag = parser.getAttributeValue(null, "flag");
                        currentDdFlag =
                                flag != null && flag.trim().length() > 0
                                        ? flag.trim()
                                        : ("线路" + (froms.size() + 1));
                        String playData = safeNextText(parser).trim();
                        if (playData.length() > 0) {
                            froms.add(currentDdFlag);
                            urls.add(playData);
                        }
                    }
                }
            } else if (event == XmlPullParser.END_TAG) {
                String tag = parser.getName();
                if ("video".equalsIgnoreCase(tag) && currentVideo != null) {
                    if (currentVideo.optString("vod_id").length() > 0
                            && currentVideo.optString("vod_name").length() > 0) {
                        if (!froms.isEmpty()) {
                            currentVideo.put("vod_play_from", join(froms, "$$$"));
                            currentVideo.put("vod_play_url", join(urls, "$$$"));
                        }
                        list.put(currentVideo);
                    }
                    currentVideo = null;
                }
            }
            event = parser.next();
        }
        return new JSONObject()
                .put("page", page)
                .put("pagecount", pagecount)
                .put("class", classes)
                .put("list", list);
    }

    private static String safeNextText(XmlPullParser parser) {
        try {
            String t = parser.nextText();
            return t == null ? "" : t;
        } catch (Exception e) {
            return "";
        }
    }

    private static String join(List<String> items, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(sep);
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    public static String query(String api, String... pairs) throws Exception {
        StringBuilder b = new StringBuilder(api);
        for (int i = 0; i < pairs.length; i += 2)
            b.append(b.indexOf("?") < 0 ? '?' : '&')
                    .append(URLEncoder.encode(pairs[i], "UTF-8"))
                    .append('=')
                    .append(URLEncoder.encode(pairs[i + 1], "UTF-8"));
        return b.toString();
    }

    public static JSONArray list(String raw) throws Exception {
        JSONArray a = parseCmsResponse(raw).optJSONArray("list");
        if (a == null) throw new IOException("返回内容不是 CMS 列表");
        return a;
    }

    public static List<LiveSource> parseLives(String rawConfig, String base) {
        List<LiveSource> out = new ArrayList<LiveSource>();
        if (rawConfig == null || rawConfig.trim().length() == 0) return out;
        try {
            JSONObject doc = decodeConfig(rawConfig);
            base = doc.optString(com.pilipala.source.Warehouse.ORIGIN, base);
            JSONArray lives = doc.optJSONArray("lives");
            if (lives == null) return out;
            for (int i = 0; i < lives.length() && out.size() < 32; i++) {
                JSONObject item = lives.optJSONObject(i);
                if (item == null) continue;
                JSONArray channels = item.optJSONArray("channels");
                if (channels != null && channels.length() > 0) {
                    for (int j = 0; j < channels.length() && out.size() < 32; j++) {
                        JSONObject ch = channels.optJSONObject(j);
                        if (ch == null) continue;
                        JSONArray urls = ch.optJSONArray("urls");
                        String rawUrl =
                                urls != null && urls.length() > 0
                                        ? urls.optString(0, "")
                                        : ch.optString("url", "");
                        addLiveSourceItem(
                                out,
                                ch.optString("name", item.optString("group", "直播源")),
                                rawUrl,
                                item,
                                base);
                    }
                } else {
                    addLiveSourceItem(
                            out,
                            item.optString("name", "直播源 " + (out.size() + 1)),
                            item.optString("url", ""),
                            item,
                            base);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static void addLiveSourceItem(
            List<LiveSource> out, String name, String rawUrl, JSONObject meta, String base) {
        if (rawUrl == null) return;
        String u = rawUrl.trim();
        if (u.length() == 0) return;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx > 0) {
                String ext = u.substring(extIdx + 4);
                int amp = ext.indexOf('&');
                if (amp > 0) ext = ext.substring(0, amp);
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                                    .trim();
                    if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                        u = decoded;
                    }
                } catch (Exception ignored) {
                }
            }
        } else if (!u.startsWith("http://")
                && !u.startsWith("https://")
                && base != null
                && base.length() > 0) {
            try {
                u = new URL(new URL(base), u).toString();
            } catch (Exception ignored) {
            }
        }
        if (!(u.startsWith("http://") || u.startsWith("https://") || u.startsWith("proxy://"))) {
            return;
        }
        LiveSource src = new LiveSource();
        src.name = name == null || name.trim().length() == 0 ? "直播源" : name.trim();
        src.url = u;
        String ua = meta.optString("ua", "").trim();
        if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
            src.headers.put("User-Agent", ua);
        }
        putSafeHeaders(src.headers, meta.optJSONObject("header"));
        putSafeHeaders(src.headers, meta.optJSONObject("headers"));
        out.add(src);
    }

    public static List<LiveGroup> fetchLiveGroups(LiveSource src) throws Exception {
        if (src == null || src.url == null) return Collections.emptyList();
        String u = src.url.trim();
        String content;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx < 0) throw new IOException("不支持的代理直播地址");
            String ext = u.substring(extIdx + 4);
            int amp = ext.indexOf('&');
            if (amp > 0) ext = ext.substring(0, amp);
            String decoded =
                    new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                            .trim();
            if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                content = fetch(decoded, src.headers);
            } else {
                content = decoded;
            }
        } else {
            content = fetch(u, src.headers);
        }
        return parseLiveContent(content);
    }

    public static List<LiveGroup> parseLiveContent(String raw) {
        if (raw == null) return Collections.emptyList();
        String text = raw.trim();
        if (text.startsWith("\ufeff")) text = text.substring(1).trim();
        int star = text.indexOf("**");
        if (star >= 0 && !text.startsWith("#EXTM3U") && !text.contains(",#genre#")) {
            try {
                text =
                        new String(
                                        Base64.decode(
                                                text.substring(star + 2).replaceAll("\\s+", ""),
                                                Base64.DEFAULT),
                                        "UTF-8")
                                .trim();
            } catch (Exception ignored) {
            }
        } else if (!text.startsWith("#EXTM3U")
                && !text.contains(",#genre#")
                && !text.contains("http://")
                && !text.contains("https://")) {
            try {
                String decoded =
                        new String(Base64.decode(text.replaceAll("\\s+", ""), Base64.DEFAULT), "UTF-8")
                                .trim();
                if (decoded.contains("http://") || decoded.contains("https://")) text = decoded;
            } catch (Exception ignored) {
            }
        }
        Map<String, LiveGroup> groups = new LinkedHashMap<String, LiveGroup>();
        Map<String, LiveChannel> channelMap = new LinkedHashMap<String, LiveChannel>();
        String[] lines = text.split("\r?\n");
        boolean isM3u = text.startsWith("#EXTM3U") || text.contains("#EXTINF:");
        if (isM3u) {
            String currentGroup = "直播频道";
            String currentName = "";
            Map<String, String> pendingHeaders = new LinkedHashMap<String, String>();
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0) continue;
                if (line.startsWith("#EXTINF:")) {
                    currentGroup = extractAttr(line, "group-title", "直播频道");
                    int comma = line.lastIndexOf(',');
                    currentName =
                            comma >= 0 && comma + 1 < line.length()
                                    ? line.substring(comma + 1).trim()
                                    : extractAttr(line, "tvg-name", "频道");
                } else if (line.startsWith("#EXTGRP:")) {
                    String g = line.substring(8).trim();
                    if (g.length() > 0) currentGroup = g;
                } else if (line.startsWith("#EXTVLCOPT:http-user-agent=")) {
                    pendingHeaders.put("User-Agent", line.substring(27).trim());
                } else if (line.startsWith("#EXTVLCOPT:http-referrer=")) {
                    pendingHeaders.put("Referer", line.substring(25).trim());
                } else if (!line.startsWith("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            currentName.length() > 0 ? currentName : "频道 " + (channelMap.size() + 1),
                            line,
                            pendingHeaders);
                    currentName = "";
                    pendingHeaders = new LinkedHashMap<String, String>();
                }
            }
        } else {
            String currentGroup = "默认分组";
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0 || line.startsWith("#") || line.startsWith("//")) continue;
                int comma = line.indexOf(',');
                if (comma <= 0) continue;
                String left = line.substring(0, comma).trim();
                String right = line.substring(comma + 1).trim();
                if (right.startsWith("#genre#")) {
                    if (left.length() > 0) currentGroup = left;
                    continue;
                }
                for (String u : right.split("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            left,
                            u.trim(),
                            Collections.<String, String>emptyMap());
                }
            }
        }
        return new ArrayList<LiveGroup>(groups.values());
    }

    private static void addChannelUrl(
            Map<String, LiveGroup> groups,
            Map<String, LiveChannel> channelMap,
            String groupName,
            String chName,
            String rawUrl,
            Map<String, String> extraHeaders) {
        if (rawUrl == null || rawUrl.length() == 0) return;
        String urlPart = rawUrl;
        Map<String, String> inlineHeaders = new LinkedHashMap<String, String>(extraHeaders);
        int pipe = rawUrl.indexOf('|');
        if (pipe > 0) {
            urlPart = rawUrl.substring(0, pipe).trim();
            String tail = rawUrl.substring(pipe + 1);
            for (String kv : tail.split("&|\\|")) {
                int eq = kv.indexOf('=');
                if (eq > 0) {
                    String k = kv.substring(0, eq).trim();
                    String v = kv.substring(eq + 1).trim();
                    if ("referer".equalsIgnoreCase(k)) inlineHeaders.put("Referer", v);
                    else if ("user-agent".equalsIgnoreCase(k) || "ua".equalsIgnoreCase(k))
                        inlineHeaders.put("User-Agent", v);
                }
            }
        }
        int dollar = urlPart.indexOf('$');
        if (dollar > 0) urlPart = urlPart.substring(0, dollar).trim();
        try {
            urlPart = http(urlPart);
        } catch (Exception invalid) {
            return;
        }
        String gKey = groupName == null || groupName.length() == 0 ? "直播频道" : groupName;
        LiveGroup grp = groups.get(gKey);
        if (grp == null) {
            grp = new LiveGroup();
            grp.name = gKey;
            groups.put(gKey, grp);
        }
        String chKey = gKey + "\n" + chName;
        LiveChannel ch = channelMap.get(chKey);
        if (ch == null) {
            ch = new LiveChannel();
            ch.name = chName;
            ch.group = gKey;
            ch.headers.putAll(inlineHeaders);
            channelMap.put(chKey, ch);
            grp.channels.add(ch);
        }
        if (!ch.urls.contains(urlPart)) {
            ch.urls.add(urlPart);
        }
    }

    private static String extractAttr(String line, String attr, String fallback) {
        int idx = line.indexOf(attr + "=\"");
        if (idx >= 0) {
            int start = idx + attr.length() + 2;
            int end = line.indexOf('"', start);
            if (end > start) {
                String v = line.substring(start, end).trim();
                if (v.length() > 0) return v;
            }
        }
        return fallback;
    }
}
