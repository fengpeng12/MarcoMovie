// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import android.widget.ImageView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Collections;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Low-memory API 14 poster loader with bounded RGB_565 LruCache, disk cache, and Conscrypt TLS 1.2.
 */
public final class LiteImageLoader {
    private static final int MAX_IMAGE_BYTES = 1536 * 1024;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ThreadPoolExecutor POOL =
            new ThreadPoolExecutor(
                    2,
                    3,
                    15L,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(36),
                    new ThreadPoolExecutor.DiscardOldestPolicy());
    private static final Set<String> IN_FLIGHT =
            Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());
    private static final LruCache<String, Bitmap> MEM_CACHE;

    static {
        long maxMem = Runtime.getRuntime().maxMemory();
        int budget = (int) Math.max(1536 * 1024L, Math.min(6 * 1024 * 1024L, maxMem / 10L));
        MEM_CACHE =
                new LruCache<String, Bitmap>(budget) {
                    @Override
                    protected int sizeOf(String key, Bitmap value) {
                        return value == null ? 1 : Math.max(1, value.getRowBytes() * value.getHeight());
                    }
                };
    }

    private LiteImageLoader() {}

    public static void clearCache(Context context) {
        MEM_CACHE.evictAll();
        if (context == null) return;
        try {
            File dir = new File(context.getCacheDir(), "lite_posters");
            File[] files = dir.listFiles();
            if (files != null) {
                for (int i = 0; i < files.length; i++) files[i].delete();
            }
        } catch (Throwable ignored) {
        }
    }

    public static void load(
            final Context context,
            final ImageView target,
            final String rawUrl,
            final Map<String, String> siteHeaders,
            final int targetWidthPx,
            final int targetHeightPx) {
        if (target == null) return;
        final String url = rawUrl == null ? "" : rawUrl.trim();
        target.setTag(url);
        target.setImageBitmap(null);
        if (url.length() == 0 || !(url.startsWith("http://") || url.startsWith("https://"))) {
            return;
        }
        final String cacheKey = url + "@" + targetWidthPx + "x" + targetHeightPx;
        Bitmap cached = MEM_CACHE.get(cacheKey);
        if (cached != null && !cached.isRecycled()) {
            target.setImageBitmap(cached);
            return;
        }
        POOL.execute(
                new Runnable() {
                    public void run() {
                        try {
                            Bitmap bmp = MEM_CACHE.get(cacheKey);
                            if (bmp == null || bmp.isRecycled()) {
                                byte[] bytes = readDiskCache(context, url);
                                if (bytes == null) {
                                    if (!IN_FLIGHT.add(url)) return;
                                    try {
                                        bytes = downloadImage(context, url, siteHeaders);
                                        if (bytes != null && bytes.length > 0) {
                                            writeDiskCache(context, url, bytes);
                                        }
                                    } finally {
                                        IN_FLIGHT.remove(url);
                                    }
                                }
                                if (bytes != null && bytes.length > 0) {
                                    bmp = decodeSampled(bytes, targetWidthPx, targetHeightPx);
                                    if (bmp != null) {
                                        MEM_CACHE.put(cacheKey, bmp);
                                    }
                                }
                            }
                            if (bmp == null) return;
                            final Bitmap result = bmp;
                            MAIN.post(
                                    new Runnable() {
                                        public void run() {
                                            if (url.equals(target.getTag()) && !result.isRecycled()) {
                                                target.setImageBitmap(result);
                                            }
                                        }
                                    });
                        } catch (OutOfMemoryError oom) {
                            MEM_CACHE.evictAll();
                        } catch (Throwable ignored) {
                        }
                    }
                });
    }

    public static Bitmap decodeSampled(byte[] data, int reqW, int reqH) {
        if (data == null || data.length == 0) return null;
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
            int sample = 1;
            int w = Math.max(80, reqW);
            int h = Math.max(110, reqH);
            while ((bounds.outWidth / (sample * 2)) >= w && (bounds.outHeight / (sample * 2)) >= h) {
                sample *= 2;
            }
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inSampleSize = sample;
            opts.inPreferredConfig = Bitmap.Config.RGB_565;
            return BitmapFactory.decodeByteArray(data, 0, data.length, opts);
        } catch (OutOfMemoryError oom) {
            MEM_CACHE.evictAll();
            return null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static byte[] downloadImage(
            Context context, String rawUrl, Map<String, String> siteHeaders) throws Exception {
        String cleanUrl = rawUrl;
        Map<String, String> headers = siteHeaders;
        int hashIdx = rawUrl.indexOf("#mm-emby=");
        if (hashIdx > 0 && context != null) {
            String account = rawUrl.substring(hashIdx + 9);
            cleanUrl = rawUrl.substring(0, hashIdx);
            try {
                com.pilipala.emby.EmbyLibrary lib =
                        com.pilipala.emby.EmbyAccounts.open(
                                context, com.pilipala.emby.EmbyLibrary.PREFIX + account);
                headers = lib.imageHeaders(rawUrl);
            } catch (Exception ignored) {
            }
        }
        String current = LiteCatalog.http(cleanUrl);
        for (int redirects = 0; redirects < 4; redirects++) {
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            if (c instanceof javax.net.ssl.HttpsURLConnection) {
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            }
            c.setConnectTimeout(6000);
            c.setReadTimeout(8000);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (Linux; Android 9; TV) AppleWebKit/537.36 Chrome/96.0 Safari/537.36");
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    c.setRequestProperty(e.getKey(), e.getValue());
                }
            }
            try {
                int code = c.getResponseCode();
                if (code >= 300 && code < 400) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) return null;
                    String next = LiteCatalog.http(new URL(new URL(current), loc).toString());
                    if ("https".equalsIgnoreCase(new URL(current).getProtocol())
                            && "http".equalsIgnoreCase(new URL(next).getProtocol())) {
                        return null;
                    }
                    current = next;
                    continue;
                }
                if (code != 200) return null;
                InputStream in = c.getInputStream();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (out.size() + n > MAX_IMAGE_BYTES) return null;
                    out.write(buf, 0, n);
                }
                return out.toByteArray();
            } finally {
                c.disconnect();
            }
        }
        return null;
    }

    private static File diskFile(Context context, String url) throws Exception {
        if (context == null) return null;
        File dir = new File(context.getCacheDir(), "lite_posters");
        if (!dir.exists()) dir.mkdirs();
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(url.getBytes("UTF-8"));
        StringBuilder sb = new StringBuilder(64);
        for (int i = 0; i < digest.length; i++) {
            sb.append(String.format(Locale.US, "%02x", digest[i] & 0xff));
        }
        return new File(dir, sb.toString() + ".img");
    }

    private static byte[] readDiskCache(Context context, String url) {
        try {
            File f = diskFile(context, url);
            if (f == null || !f.exists() || f.length() <= 0 || f.length() > MAX_IMAGE_BYTES) {
                return null;
            }
            byte[] data = new byte[(int) f.length()];
            FileInputStream in = new FileInputStream(f);
            try {
                int pos = 0, n;
                while (pos < data.length && (n = in.read(data, pos, data.length - pos)) > 0) {
                    pos += n;
                }
                return pos == data.length ? data : null;
            } finally {
                in.close();
            }
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static void writeDiskCache(Context context, String url, byte[] data) {
        try {
            File f = diskFile(context, url);
            if (f == null) return;
            File dir = f.getParentFile();
            File[] existing = dir == null ? null : dir.listFiles();
            if (existing != null && existing.length > 120) {
                for (int i = 0; i < 30 && i < existing.length; i++) existing[i].delete();
            }
            FileOutputStream out = new FileOutputStream(f);
            try {
                out.write(data);
            } finally {
                out.close();
            }
        } catch (Throwable ignored) {
        }
    }
}
