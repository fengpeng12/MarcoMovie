package com.pilipala.emby;

import android.util.Base64;
import java.io.*;
import java.net.*;
import java.security.MessageDigest;
import java.util.Locale;

/** A .js.md5 URL describes a sibling file, not a JSON or TVBox API. */
public final class CheckedScript {
    public final String code, base;

    private CheckedScript(String code, String base) {
        this.code = code;
        this.base = base;
    }

    public static boolean matches(String input) {
        try {
            return new URL(input).getPath().toLowerCase(Locale.US).endsWith(".js.md5");
        } catch (Exception ignored) {
            return false;
        }
    }

    public static CheckedScript read(String input) throws Exception {
        URI original = new URI(input);
        if (!("http".equalsIgnoreCase(original.getScheme())
                        || "https".equalsIgnoreCase(original.getScheme()))
                || original.getHost() == null) throw new IOException("请输入有效的脚本订阅地址");
        // Reuse the raw encoding of the path and query, but drop userinfo and fragment.
        String authority = original.getRawAuthority();
        authority = authority.substring(authority.lastIndexOf('@') + 1);
        String root = original.getScheme() + "://" + authority;
        String path = original.getRawPath(),
                query = original.getRawQuery() == null ? "" : "?" + original.getRawQuery();
        String auth =
                original.getUserInfo() == null
                        ? null
                        : "Basic "
                                + Base64.encodeToString(
                                        original.getUserInfo().getBytes("UTF-8"), Base64.NO_WRAP);
        long deadline = System.nanoTime() + 25000000000L;
        String digest =
                new String(fetch(root + path + query, auth, 1024, deadline), "UTF-8").trim();
        if (!digest.matches("(?i)[0-9a-f]{32}")) throw new IOException("订阅没有返回有效的 MD5 摘要");
        String script = root + path.substring(0, path.length() - 4) + query;
        byte[] bytes = fetch(script, auth, 16 * 1024 * 1024, deadline);
        StringBuilder actual = new StringBuilder();
        for (byte b : MessageDigest.getInstance("MD5").digest(bytes))
            actual.append(String.format(Locale.US, "%02x", b & 255));
        if (!digest.equalsIgnoreCase(actual.toString())) throw new IOException("脚本校验不一致，请稍后重新导入");
        String text = new String(bytes, "UTF-8");
        boolean service = text.contains("catServerFactory") && text.contains("catDartServerPort");
        if (!service && bytes.length > 2 * 1024 * 1024) throw new IOException("独立脚本超过 2 MB");
        return new CheckedScript(text, script);
    }

    private static byte[] fetch(String url, String auth, int limit, long deadline)
            throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(8000);
            c.setReadTimeout(10000);
            c.setRequestProperty("User-Agent", "okhttp/3.15");
            if (auth != null) c.setRequestProperty("Authorization", auth);
            int status = c.getResponseCode();
            if (status != 200) throw new IOException("脚本订阅读取失败（HTTP " + status + "）");
            InputStream in = c.getInputStream();
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                for (int n; (n = in.read(buffer)) != -1; ) {
                    if (System.nanoTime() >= deadline || Thread.currentThread().isInterrupted())
                        throw new InterruptedIOException("脚本订阅读取超时");
                    if (out.size() + n > limit) throw new IOException("脚本订阅超过大小限制");
                    out.write(buffer, 0, n);
                }
                return out.toByteArray();
            } finally {
                in.close();
            }
        } finally {
            c.disconnect();
        }
    }
}
