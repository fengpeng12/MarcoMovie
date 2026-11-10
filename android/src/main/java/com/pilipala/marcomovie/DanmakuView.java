package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.*;
import android.os.SystemClock;
import android.view.View;
import com.pilipala.marcomovie.DanmakuData.Comment;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;

/** A bounded source-provided comment overlay; animation is derived from the media clock. */
final class DanmakuView extends View implements AutoCloseable {
    interface Clock {
        int position();

        boolean playing();
    }

    interface Listener {
        void loaded(int count);

        void error(String message);
    }

    private static final Typeface DANMAKU_TYPEFACE = Typeface.create("sans-serif", Typeface.BOLD);

    final Clock clock;
    final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
    final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
    final ExecutorService loader = Executors.newSingleThreadExecutor();
    List<Comment> comments = Collections.emptyList();
    boolean closed, enabled;
    int request;
    float textSize = 22, opacity = .88f, area = .5f;
    private int lastClockPos = -1;
    private long lastClockSampleMs = 0L;

    DanmakuView(Context context, Clock clock) {
        super(context);
        this.clock = clock;
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        paint.setTypeface(DANMAKU_TYPEFACE);
        paint.setStyle(Paint.Style.FILL);
        strokePaint.setTypeface(DANMAKU_TYPEFACE);
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeJoin(Paint.Join.ROUND);
        strokePaint.setStrokeCap(Paint.Cap.ROUND);
        strokePaint.setColor(0xd8000000);
    }

    void enabled(boolean value) {
        enabled = value;
        setVisibility(value ? VISIBLE : GONE);
        if (value) invalidate();
    }

    private static String decodeResponseStream(InputStream rawStream, String encoding)
            throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int total = 0, read;
        while ((read = rawStream.read(chunk)) != -1) {
            total += read;
            if (total > 8 * 1024 * 1024) throw new IOException("弹幕文件过大");
            buffer.write(chunk, 0, read);
        }
        byte[] bytes = buffer.toByteArray();
        if (bytes.length == 0) return "";
        String enc = encoding == null ? "" : encoding.toLowerCase(Locale.ROOT);
        if (enc.contains("gzip")
                || (bytes.length >= 2 && (bytes[0] & 0xff) == 0x1f && (bytes[1] & 0xff) == 0x8b)) {
            try (InputStream gz = new GZIPInputStream(new ByteArrayInputStream(bytes))) {
                return Cms.read(gz, 8 * 1024 * 1024);
            } catch (Exception ignored) {
            }
        }
        byte firstNonSpace = 0;
        for (byte b : bytes) {
            if (b != ' ' && b != '\t' && b != '\r' && b != '\n') {
                firstNonSpace = b;
                break;
            }
        }
        if (enc.contains("deflate")
                || (firstNonSpace != '<' && firstNonSpace != '{' && firstNonSpace != '[')) {
            for (boolean nowrap : new boolean[] {true, false}) {
                try (InputStream inf =
                        new InflaterInputStream(
                                new ByteArrayInputStream(bytes), new Inflater(nowrap))) {
                    String inflated = Cms.read(inf, 8 * 1024 * 1024);
                    String trimmed = inflated.trim();
                    if (trimmed.startsWith("<")
                            || trimmed.startsWith("{")
                            || trimmed.startsWith("[")) {
                        return inflated;
                    }
                } catch (Exception ignored) {
                }
            }
        }
        return new String(bytes, "UTF-8");
    }

    void load(String url, Map<String, String> headers, Listener listener) {
        final int ticket = ++request;
        loader.execute(
                () -> {
                    HttpURLConnection connection = null;
                    try {
                        String candidate = url == null ? "" : url.trim();
                        if (candidate.startsWith("[") || candidate.startsWith("{")) {
                            try {
                                org.json.JSONObject wrapper =
                                        new org.json.JSONObject().put("danmaku", candidate);
                                candidate = MediaOptions.extractDanmakuUrl(wrapper);
                            } catch (Exception ignored) {
                            }
                        }
                        String address = LocalProxy.rewrite(candidate);
                        if (!Cms.isHttp(address)) throw new IOException("来源没有提供有效弹幕地址");
                        Map<String, String> reqHeaders =
                                ProxyAddress.requestHeaders(
                                        address,
                                        headers != null
                                                ? headers
                                                : Collections.<String, String>emptyMap());
                        URL currentUrl = new URL(Cms.normalizeHttp(address));
                        for (int redirect = 0; redirect <= 5; redirect++) {
                            if (connection != null) {
                                connection.disconnect();
                            }
                            boolean isLoopback = LocalProxy.loopbackHost(currentUrl.getHost());
                            connection = (HttpURLConnection) currentUrl.openConnection();
                            connection.setInstanceFollowRedirects(false);
                            connection.setConnectTimeout(12000);
                            connection.setReadTimeout(25000);
                            connection.setRequestProperty("User-Agent", Cms.USER_AGENT);
                            connection.setRequestProperty("Accept-Encoding", "gzip, deflate");
                            for (Map.Entry<String, String> h : reqHeaders.entrySet()) {
                                String k = h.getKey();
                                if (k == null) continue;
                                if (isLoopback
                                        && ("Origin".equalsIgnoreCase(k)
                                                || "Host".equalsIgnoreCase(k))) {
                                    continue;
                                }
                                connection.setRequestProperty(k, h.getValue());
                            }
                            int status = connection.getResponseCode();
                            if (status == 301
                                    || status == 302
                                    || status == 303
                                    || status == 307
                                    || status == 308) {
                                String loc = connection.getHeaderField("Location");
                                if (loc == null || loc.trim().isEmpty()) break;
                                currentUrl = new URL(currentUrl, loc.trim());
                                continue;
                            }
                            break;
                        }
                        String body;
                        try (InputStream in = connection.getInputStream()) {
                            body = decodeResponseStream(in, connection.getContentEncoding());
                        }
                        List<Comment> values = DanmakuData.parse(body);
                        post(
                                () -> {
                                    if (!closed && ticket == request) {
                                        comments = values;
                                        listener.loaded(values.size());
                                        invalidate();
                                    }
                                });
                    } catch (Exception error) {
                        post(
                                () -> {
                                    if (!closed && ticket == request)
                                        listener.error("弹幕暂时不可用，可导入本地 XML / JSON 文件。");
                                });
                    } finally {
                        if (connection != null) connection.disconnect();
                    }
                });
    }

    void loadText(String text, Listener listener) {
        final int ticket = ++request;
        loader.execute(
                () -> {
                    try {
                        List<Comment> values = DanmakuData.parse(text);
                        post(
                                () -> {
                                    if (!closed && ticket == request) {
                                        comments = values;
                                        listener.loaded(values.size());
                                        invalidate();
                                    }
                                });
                    } catch (Exception error) {
                        post(
                                () -> {
                                    if (!closed && ticket == request) listener.error("无法识别弹幕文件。");
                                });
                    }
                });
    }

    private long smoothNow() {
        int raw = clock.position();
        long wall = SystemClock.elapsedRealtime();
        if (!clock.playing()) {
            lastClockPos = raw;
            lastClockSampleMs = wall;
            return raw;
        }
        if (lastClockPos < 0 || Math.abs(raw - lastClockPos) > 1200) {
            lastClockPos = raw;
            lastClockSampleMs = wall;
            return raw;
        }
        if (raw != lastClockPos) {
            lastClockPos = raw;
            lastClockSampleMs = wall;
            return raw;
        }
        long elapsed = Math.max(0L, Math.min(500L, wall - lastClockSampleMs));
        return raw + elapsed;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (!enabled || closed || comments.isEmpty()) return;
        long now = smoothNow();
        float density = getResources().getDisplayMetrics().density;
        float pxSize = textSize * density;
        paint.setTextSize(pxSize);
        strokePaint.setTextSize(pxSize);
        strokePaint.setStrokeWidth(Math.max(2f, 2.6f * density));
        int alpha = (int) (opacity * 255);
        strokePaint.setAlpha(Math.min(255, (int) (alpha * 0.92f)));
        int lanes = Math.max(1, Math.min(8, (int) (getHeight() * area / (pxSize * 1.48f))));
        int lo = 0, hi = comments.size();
        while (lo < hi) {
            int middle = (lo + hi) >>> 1;
            if (comments.get(middle).time < now - 8500) lo = middle + 1;
            else hi = middle;
        }
        int drawn = 0;
        int viewW = getWidth(), viewH = getHeight();
        for (int i = lo; i < comments.size() && drawn < 56; i++) {
            Comment c = comments.get(i);
            long age = now - c.time;
            if (age < 0) break;
            long duration = c.mode == 4 || c.mode == 5 ? 4000 : 8000;
            if (age > duration) continue;
            if (c.cachedWidth <= 0f || c.cachedTextSize != pxSize) {
                c.cachedWidth = paint.measureText(c.text);
                c.cachedTextSize = pxSize;
            }
            float width = c.cachedWidth;
            float x = (viewW + width) * (1 - age / (float) duration) - width;
            float y = (i % lanes + 1) * pxSize * 1.45f;
            if (c.mode == 4) {
                x = (viewW - width) / 2f;
                y = viewH - pxSize * (1.5f + i % 2);
            } else if (c.mode == 5) {
                x = (viewW - width) / 2f;
            }
            canvas.drawText(c.text, x, y, strokePaint);
            paint.setColor(0xff000000 | (c.color & 0xffffff));
            paint.setAlpha(alpha);
            canvas.drawText(c.text, x, y, paint);
            drawn++;
        }
        if (clock.playing()) postInvalidateOnAnimation();
    }

    @Override
    public void close() {
        closed = true;
        request++;
        loader.shutdownNow();
        comments = Collections.emptyList();
    }
}
