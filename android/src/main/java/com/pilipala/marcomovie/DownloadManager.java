package com.pilipala.marcomovie;

import android.content.Context;
import android.os.Environment;
import android.os.SystemClock;
import com.pilipala.source.MediaRequestHeaders;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.UnknownHostException;
import java.security.GeneralSecurityException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import javax.net.ssl.SSLException;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Offline downloads for the phone and tablet interface. Direct media files resume with HTTP Range
 * requests; HLS playlists are fetched segment by segment (AES-128 supported) and joined into one
 * local file. Tasks persist in the app files directory and media is stored in app-specific
 * storage, so no runtime permission is required. The TV interface never opens this manager.
 */
final class DownloadManager {
    static final int WAITING = 0;
    static final int RUNNING = 1;
    static final int PAUSED = 2;
    static final int DONE = 3;
    static final int FAILED = 4;

    static final int PARALLEL = 2;
    static final int SEGMENT_THREADS = 3;
    static final int MAX_PLAYLIST = 8 * 1024 * 1024;
    static final int MAX_SEGMENT = 64 * 1024 * 1024;
    static final long MB = 1024L * 1024;
    static final long GB = MB * 1024;
    static final String VIDEO_EXT = "mp4|mkv|flv|avi|mov|webm|m4v|ts|wmv|rmvb|mpg|mp3|m4a";
    static final String HLS_MIME = "application/x-mpegURL";
    private static final String STORE = "downloads.json";
    private static final String TAG = "DownloadManager";
    private static final ThreadFactory THREADS = DownloadManager::daemon;
    private static DownloadManager instance;
    private static int counter;

    /** One download job; display fields are volatile because workers update them. */
    static final class Task {
        String id = "";
        String key = "";
        String title = "";
        String episode = "";
        String line = "";
        String poster = "";
        String site = "";
        String videoId = "";
        String source = "";
        boolean resolve;
        volatile String url = "";
        final Map<String, String> headers = new LinkedHashMap<>();
        volatile String mime = "";
        volatile String base = "";
        volatile String ext = "";
        volatile String path = "";
        volatile int state = WAITING;
        volatile String error = "";
        volatile long bytes;
        volatile long total = -1;
        volatile int segments;
        volatile int segmentCount;
        volatile long speed;
        volatile long windowStart;
        long windowBytes;
        long created;
        Run run;
        boolean pendingResume;
        volatile boolean removed;

        int percent() {
            if (state == DONE) return 100;
            if (segmentCount > 0) return (int) (segments * 100L / segmentCount);
            if (total > 0) return (int) Math.min(100, bytes * 100 / total);
            return -1;
        }

        long currentSpeed() {
            long age = SystemClock.elapsedRealtime() - windowStart;
            return age > 3000 ? 0 : speed;
        }

        String status() {
            int percent = percent();
            switch (state) {
                case WAITING:
                    return "等待中";
                case RUNNING:
                    return "下载中 " + progressText(percent) + " · " + size(currentSpeed()) + "/s";
                case PAUSED:
                    return percent >= 0 ? "已暂停 · " + percent + "%" : "已暂停";
                case DONE:
                    return "已完成 · " + size(Math.max(total, bytes));
                default:
                    return "失败：" + (error.isEmpty() ? "未知错误" : error);
            }
        }

        private String progressText(int percent) {
            if (segmentCount > 0) return percent + "%（" + segments + "/" + segmentCount + " 片）";
            if (percent >= 0) return percent + "% · " + size(bytes) + " / " + size(total);
            return size(bytes);
        }

        JSONObject json() throws JSONException {
            JSONObject o = new JSONObject();
            o.put("id", id);
            o.put("key", key);
            o.put("title", title);
            o.put("episode", episode);
            o.put("line", line);
            o.put("poster", poster);
            o.put("site", site);
            o.put("videoId", videoId);
            o.put("source", source);
            o.put("resolve", resolve);
            o.put("url", url);
            o.put("headers", new JSONObject(headers));
            o.put("scopedHeaders", true);
            o.put("mime", mime);
            o.put("base", base);
            o.put("ext", ext);
            o.put("path", path);
            o.put("state", state);
            o.put("error", error);
            o.put("bytes", bytes);
            o.put("total", total);
            o.put("segments", segments);
            o.put("segmentCount", segmentCount);
            o.put("created", created);
            return o;
        }

        static Task from(JSONObject o) {
            Task t = new Task();
            t.id = o.optString("id");
            t.key = o.optString("key");
            t.title = o.optString("title");
            t.episode = o.optString("episode");
            t.line = o.optString("line");
            t.poster = o.optString("poster");
            t.site = o.optString("site");
            t.videoId = o.optString("videoId");
            t.source = o.optString("source");
            t.resolve = o.optBoolean("resolve");
            t.url = o.optString("url");
            JSONObject h = o.optJSONObject("headers");
            if (h != null) {
                Iterator<String> names = h.keys();
                while (names.hasNext()) {
                    String name = names.next();
                    t.headers.put(name, h.optString(name));
                }
            }
            t.mime = o.optString("mime");
            t.base = o.optString("base");
            if (!o.optBoolean("scopedHeaders", false)) {
                Map<String, String> safe = MediaRequestHeaders.forTarget(t.headers, null, t.source);
                t.headers.clear();
                t.headers.putAll(safe);
            }
            t.ext = o.optString("ext");
            t.path = o.optString("path");
            t.state = o.optInt("state", PAUSED);
            t.error = o.optString("error");
            t.bytes = o.optLong("bytes");
            t.total = o.optLong("total", -1);
            t.segments = o.optInt("segments");
            t.segmentCount = o.optInt("segmentCount");
            t.created = o.optLong("created");
            return t;
        }
    }

    /** A single execution of a task; pausing stops only the run it belongs to. */
    private static final class Run {
        final Task task;
        String credentialOrigin;
        final Map<String, String> headers = new LinkedHashMap<>();
        final Map<String, byte[]> keys = new HashMap<>();
        final Set<HttpURLConnection> connections = new HashSet<>();
        volatile boolean stop;
        boolean started;
        boolean finished;
        volatile Future<?> future;
        volatile RequestScope scope;

        Run(Task task) {
            this.task = task;
        }
    }

    private static final class Segment {
        String uri;
        String key;
        byte[] iv;
        long offset = -1;
        long length = -1;

        String range() {
            if (length < 0) return null;
            long start = Math.max(0, offset);
            return "bytes=" + start + "-" + (start + length - 1);
        }
    }

    private static final class Media {
        final List<Segment> segments = new ArrayList<>();
        Segment init;
    }

    private static final class Fetched {
        byte[] data;
        String url;
    }

    /** Download failure with a readable Chinese message shown in the list. */
    static class DownloadException extends IOException {
        DownloadException(String message) {
            super(message);
        }

        boolean retry() {
            return false;
        }
    }

    static final class HttpStatusException extends DownloadException {
        final int status;

        HttpStatusException(int status) {
            super("服务器返回 HTTP " + status + (status == 403 || status == 410 ? "，地址可能已过期" : ""));
            this.status = status;
        }

        @Override
        boolean retry() {
            return status >= 500 || status == 408 || status == 429;
        }
    }

    final Context app;
    final File store;
    final List<Task> tasks = new ArrayList<>();
    final ThreadPoolExecutor pool;
    final ExecutorService saver;

    static synchronized DownloadManager get(Context context) {
        if (instance == null) instance = new DownloadManager(context.getApplicationContext());
        return instance;
    }

    private DownloadManager(Context context) {
        app = context;
        store = new File(context.getFilesDir(), STORE);
        LinkedBlockingQueue<Runnable> queue = new LinkedBlockingQueue<>();
        pool = new ThreadPoolExecutor(PARALLEL, PARALLEL, 30, TimeUnit.SECONDS, queue, THREADS);
        pool.allowCoreThreadTimeOut(true);
        saver = Executors.newSingleThreadExecutor(THREADS);
        load();
    }

    private static Thread daemon(Runnable work) {
        Thread thread = new Thread(work, "movie-download");
        thread.setDaemon(true);
        thread.setPriority(Thread.NORM_PRIORITY - 1);
        return thread;
    }

    static String key(String site, String video, String line, String episode) {
        return text(site) + "|" + text(video) + "|" + text(line) + "|" + text(episode);
    }

    static String text(String value) {
        return value == null ? "" : value;
    }

    private static synchronized String newId() {
        counter++;
        return Long.toString(System.currentTimeMillis(), 36) + Integer.toString(counter, 36);
    }

    synchronized List<Task> snapshot() {
        return new ArrayList<>(tasks);
    }

    /** Adds the episodes of one line; returns how many new tasks were created. */
    int enqueue(Cms.Site site, Cms.Video video, Cms.Line line, List<Cms.Episode> episodes) {
        int added = 0;
        synchronized (this) {
            for (Cms.Episode ep : episodes) {
                String key = key(site.key, video.id, line.name, ep.name);
                if (findKey(key) != null) continue;
                Task t = new Task();
                t.id = newId();
                t.key = key;
                t.title = text(video.title);
                t.episode = text(ep.name);
                t.line = text(line.name);
                t.poster = text(video.poster);
                t.site = text(site.key);
                t.videoId = text(video.id);
                t.source = text(ep.url);
                t.resolve = !site.supported();
                if (!t.resolve) {
                    t.url = text(ep.url);
                    t.headers.putAll(MediaRequestHeaders.forTarget(site.headers, site.api, ep.url));
                }
                t.headers.putAll(ep.headers);
                String mime = ep.media == null ? null : MediaOptions.mime(ep.media);
                t.mime = text(mime);
                t.created = System.currentTimeMillis();
                tasks.add(t);
                schedule(t);
                added++;
            }
        }
        if (added > 0) save();
        return added;
    }

    void pause(String id) {
        Run run = null;
        synchronized (this) {
            Task t = find(id);
            if (t == null || (t.state != WAITING && t.state != RUNNING)) return;
            t.state = PAUSED;
            t.speed = 0;
            t.pendingResume = false;
            run = t.run;
            if (run != null) {
                run.stop = true;
                if (!run.started) run.finished = true;
            }
        }
        if (run != null) stop(run);
        save();
    }

    void resume(String id) {
        synchronized (this) {
            Task t = find(id);
            if (t == null || (t.state != PAUSED && t.state != FAILED)) return;
            t.error = "";
            if (t.run != null && !t.run.finished) {
                t.state = WAITING;
                t.pendingResume = true;
            } else {
                schedule(t);
            }
        }
        save();
    }

    void pauseAll() {
        for (Task t : snapshot()) pause(t.id);
    }

    void resumeAll() {
        for (Task t : snapshot()) {
            if (t.state == PAUSED || t.state == FAILED) resume(t.id);
        }
    }

    void delete(String id) {
        Task t;
        Run run;
        boolean active;
        synchronized (this) {
            t = find(id);
            if (t == null) return;
            tasks.remove(t);
            t.removed = true;
            run = t.run;
            active = run != null && run.started && !run.finished;
            if (run != null) run.stop = true;
        }
        if (run != null) stop(run);
        if (!active) {
            final Task gone = t;
            new Thread(() -> cleanup(gone), "movie-download-clean").start();
        }
        save();
    }

    String folderPath() {
        try {
            return folder().getAbsolutePath();
        } catch (IOException e) {
            return "不可用";
        }
    }

    private Task find(String id) {
        for (Task t : tasks) {
            if (t.id.equals(id)) return t;
        }
        return null;
    }

    private Task findKey(String key) {
        for (Task t : tasks) {
            if (t.key.equals(key)) return t;
        }
        return null;
    }

    private synchronized void schedule(Task t) {
        Run run = new Run(t);
        t.run = run;
        t.pendingResume = false;
        t.state = WAITING;
        t.speed = 0;
        run.future = pool.submit(() -> execute(t, run));
    }

    private void stop(Run run) {
        Future<?> future = run.future;
        if (future != null) future.cancel(true);
        pool.purge();
        new Thread(() -> abort(run), "movie-download-stop").start();
    }

    /** Network teardown runs off the main thread: closing TLS sockets may write to the network. */
    private static void abort(Run run) {
        RequestScope scope = run.scope;
        if (scope != null) scope.cancel();
        List<HttpURLConnection> open;
        synchronized (run.connections) {
            open = new ArrayList<>(run.connections);
            run.connections.clear();
        }
        for (HttpURLConnection connection : open) {
            try {
                connection.disconnect();
            } catch (Exception ignored) {
            }
        }
    }

    private void execute(Task t, Run run) {
        synchronized (this) {
            if (run.stop || run.finished || t.run != run || t.removed) {
                run.finished = true;
                return;
            }
            run.started = true;
            t.state = RUNNING;
            t.error = "";
        }
        save();
        boolean completed = false;
        String error = "";
        try {
            work(run);
            completed = true;
        } catch (Throwable e) {
            error = reason(e);
            if (!stopped(run)) AppLog.w(TAG, "download failed: " + t.key, e);
        }
        boolean again = false;
        synchronized (this) {
            run.finished = true;
            if (!t.removed && t.run == run) {
                if (completed) {
                    t.state = DONE;
                    t.error = "";
                } else if (run.stop) {
                    again = t.pendingResume;
                } else {
                    t.state = FAILED;
                    t.error = error;
                }
                t.speed = 0;
            }
        }
        if (t.removed) cleanup(t);
        if (again) schedule(t);
        save();
    }

    private static boolean stopped(Run run) {
        return run.stop || run.task.removed || Thread.currentThread().isInterrupted();
    }

    private static void check(Run run) throws InterruptedIOException {
        if (stopped(run)) throw new InterruptedIOException("download stopped");
    }

    private static String reason(Throwable e) {
        if (e instanceof DownloadException) return e.getMessage();
        if (e instanceof SocketTimeoutException) return "网络连接超时，请检查网络后重试";
        if (e instanceof UnknownHostException) return "无法解析服务器地址，请检查网络";
        if (e instanceof ConnectException) return "无法连接到下载服务器";
        if (e instanceof SSLException) return "安全连接失败";
        if (e instanceof FileNotFoundException) return "文件无法写入或服务器文件不存在";
        if (e instanceof JSONException) return "来源返回的播放信息无法读取";
        if (e instanceof OutOfMemoryError) return "内存不足，分片过大";
        if (e instanceof IOException) return "网络或存储读写失败（" + e.getClass().getSimpleName() + "）";
        return "下载失败（" + e.getClass().getSimpleName() + "）";
    }

    private void work(Run run) throws Exception {
        Task t = run.task;
        resolve(run);
        String address;
        synchronized (this) {
            address = t.url;
            run.headers.clear();
            run.headers.putAll(t.headers);
        }
        if (address.isEmpty()) throw new DownloadException("来源没有返回播放地址");
        if (address.startsWith("magnet:")) throw new DownloadException("磁力链接暂不支持下载");
        Cms.ImageRequest suffix = Cms.imageRequest(address);
        if (!suffix.headers.isEmpty()) {
            address = suffix.url;
            run.headers.putAll(suffix.headers);
        }
        address = LocalProxy.rewrite(address);
        run.credentialOrigin = address;
        if (!Cms.isHttp(address)) throw new DownloadException("该剧集不是 HTTP(S) 直链，暂不支持下载");
        if (HLS_MIME.equals(t.mime) || address.toLowerCase(Locale.ROOT).contains(".m3u8")) {
            downloadHls(run, address);
        } else {
            downloadDirect(run, address);
        }
    }

    /** Sources that need an extension engine are resolved right before downloading. */
    private void resolve(Run run) throws Exception {
        Task t = run.task;
        if (!t.resolve) return;
        MainActivity a = MainActivity.activeActivity;
        Cms.Config config = a == null ? null : a.config;
        Cms.Site site = null;
        if (config != null) {
            for (Cms.Site candidate : config.sites) {
                if (candidate.key.equals(t.site)) site = candidate;
            }
        }
        if (a == null || site == null) {
            if (!t.url.isEmpty()) return;
            throw new DownloadException("无法解析播放地址：请打开应用并确认片源仍在配置中");
        }
        Cms.Episode original = new Cms.Episode();
        original.name = t.episode;
        original.url = t.source;
        synchronized (this) {
            original.headers.putAll(t.headers);
        }
        String json;
        try {
            final SourceEngine engine = a.engine(site);
            RequestScope scope = new RequestScope();
            run.scope = scope;
            json = scope.call(() -> engine.player(t.line, t.source));
        } catch (Exception e) {
            if (stopped(run)) throw e;
            throw new DownloadException("解析播放地址失败：" + SourceController.message(e));
        } finally {
            run.scope = null;
        }
        JSONObject result = new JSONObject(json);
        if (result.optInt("parse", 0) != 0 || result.optInt("jx", 0) != 0) {
            throw new DownloadException("该剧集需要网页解析播放，暂不支持下载");
        }
        Cms.Episode resolved = MediaOptions.episode(site, original, result);
        String mime = MediaOptions.mime(resolved.media);
        synchronized (this) {
            t.url = text(resolved.url);
            t.headers.clear();
            t.headers.putAll(resolved.headers);
            t.mime = text(mime);
        }
    }

    // ---------------------------------------------------------------------
    // Direct files (mp4 / mkv / flv ...) with Range resume
    // ---------------------------------------------------------------------

    private void downloadDirect(Run run, String address) throws Exception {
        Task t = run.task;
        File part = workFile(t, ".part");
        long offset = part.isFile() ? part.length() : 0;
        HttpURLConnection c;
        try {
            c = open(run, address, offset > 0 ? "bytes=" + offset + "-" : null);
        } catch (HttpStatusException e) {
            if (e.status != 416 || offset == 0) throw e;
            part.delete();
            offset = 0;
            c = open(run, address, null);
        }
        boolean playlist;
        try {
            playlist = receive(run, c, part, offset);
        } finally {
            release(run, c);
        }
        if (playlist) {
            part.delete();
            downloadHls(run, address);
            return;
        }
        File target = outputFile(t, t.ext.isEmpty() ? ".mp4" : t.ext);
        if (target.exists() && !target.delete()) throw new DownloadException("无法覆盖同名文件");
        if (!part.renameTo(target)) throw new DownloadException("无法保存下载文件");
        synchronized (t) {
            t.path = target.getAbsolutePath();
            t.bytes = target.length();
            t.total = t.bytes;
        }
    }

    /** Streams the response into the part file; returns true when the body is an HLS playlist. */
    private boolean receive(Run run, HttpURLConnection c, File part, long from) throws Exception {
        Task t = run.task;
        int status = c.getResponseCode();
        String type = text(c.getContentType()).toLowerCase(Locale.ROOT);
        if (type.contains("mpegurl")) return true;
        if (type.contains("text/html") || type.contains("application/json")) {
            throw new DownloadException("下载地址返回的是网页或数据接口，暂不支持下载");
        }
        boolean append = from > 0 && status == 206;
        long start = append ? from : 0;
        long total = -1;
        long length = number(c.getHeaderField("Content-Length"));
        if (length >= 0) total = start + length;
        String range = c.getHeaderField("Content-Range");
        if (range != null && range.lastIndexOf('/') >= 0) {
            long full = number(range.substring(range.lastIndexOf('/') + 1));
            if (full > 0) total = full;
        }
        if (t.ext.isEmpty()) t.ext = extension(c.getURL().getPath(), type);
        synchronized (t) {
            t.bytes = start;
            t.total = total;
            t.segments = 0;
            t.segmentCount = 0;
        }
        try (BufferedInputStream in = new BufferedInputStream(c.getInputStream(), 65536)) {
            if (start == 0 && isPlaylist(in)) return true;
            try (OutputStream out = new FileOutputStream(part, append)) {
                copy(run, in, out);
            }
        }
        if (total > 0 && part.length() < total) {
            throw new DownloadException("下载不完整，请稍后重试");
        }
        return false;
    }

    private static boolean isPlaylist(BufferedInputStream in) throws IOException {
        in.mark(64);
        byte[] head = new byte[10];
        int count = 0;
        while (count < head.length) {
            int n = in.read(head, count, head.length - count);
            if (n < 0) break;
            count += n;
        }
        in.reset();
        String text = new String(head, 0, count, "ISO-8859-1").replace("\u00ef\u00bb\u00bf", "");
        return text.startsWith("#EXTM3U");
    }

    private void copy(Run run, InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[65536];
        int n;
        while ((n = in.read(buffer)) != -1) {
            check(run);
            out.write(buffer, 0, n);
            count(run.task, n);
        }
    }

    static String extension(String path, String type) {
        String lower = text(path).toLowerCase(Locale.ROOT);
        boolean known = lower.matches(".*\\.(" + VIDEO_EXT + ")$");
        if (known) return lower.substring(lower.lastIndexOf('.'));
        if (type.contains("matroska")) return ".mkv";
        if (type.contains("flv")) return ".flv";
        if (type.contains("webm")) return ".webm";
        if (type.contains("mp2t")) return ".ts";
        if (type.contains("quicktime")) return ".mov";
        return ".mp4";
    }

    // ---------------------------------------------------------------------
    // HLS playlists
    // ---------------------------------------------------------------------

    private void downloadHls(Run run, String address) throws Exception {
        Task t = run.task;
        Media media = loadMedia(run, address);
        File parts = workFile(t, ".parts");
        if (!parts.isDirectory() && !parts.mkdirs()) {
            throw new DownloadException("无法创建下载缓存目录");
        }
        int count = media.segments.size();
        int ready = 0;
        for (int i = 0; i < count; i++) {
            if (segmentFile(parts, i).isFile()) ready++;
        }
        synchronized (t) {
            t.segmentCount = count;
            t.segments = ready;
            t.bytes = 0;
            t.total = -1;
        }
        ExecutorService workers = Executors.newFixedThreadPool(SEGMENT_THREADS, THREADS);
        List<Future<Void>> jobs = new ArrayList<>();
        try {
            for (int i = 0; i < count; i++) {
                File target = segmentFile(parts, i);
                if (target.isFile()) continue;
                Segment segment = media.segments.get(i);
                Callable<Void> job =
                        () -> {
                            download(run, segment, target, true);
                            return null;
                        };
                jobs.add(workers.submit(job));
            }
            for (Future<Void> pending : jobs) await(pending);
        } finally {
            workers.shutdownNow();
        }
        File init = null;
        if (media.init != null) {
            init = new File(parts, "init.mp4");
            if (!init.isFile()) download(run, media.init, init, false);
        }
        File output = outputFile(t, media.init != null ? ".mp4" : ".ts");
        File merging = new File(output.getPath() + ".tmp");
        try (OutputStream out = new FileOutputStream(merging)) {
            if (init != null) append(init, out);
            for (int i = 0; i < count; i++) {
                check(run);
                append(segmentFile(parts, i), out);
            }
        }
        if (output.exists() && !output.delete()) throw new DownloadException("无法覆盖同名文件");
        if (!merging.renameTo(output)) throw new DownloadException("无法保存合并后的视频文件");
        deleteTree(parts);
        synchronized (t) {
            t.path = output.getAbsolutePath();
            t.bytes = output.length();
            t.total = t.bytes;
        }
    }

    private static void await(Future<Void> job) throws Exception {
        try {
            job.get();
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof OutOfMemoryError) throw new DownloadException("内存不足，分片过大");
            throw new DownloadException("分片下载失败");
        }
    }

    private static File segmentFile(File parts, int index) {
        return new File(parts, String.format(Locale.ROOT, "%06d.seg", index));
    }

    private static void append(File file, OutputStream out) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536];
            int n;
            while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
        }
    }

    /** Follows master playlists to the highest-bandwidth variant and parses its segments. */
    private Media loadMedia(Run run, String address) throws Exception {
        String url = address;
        for (int depth = 0; depth < 5; depth++) {
            Fetched body = fetch(run, url, null, MAX_PLAYLIST);
            String text = new String(body.data, "UTF-8");
            if (!text.contains("#EXTM3U")) throw new DownloadException("播放列表格式无法识别");
            String variant = bestVariant(text, body.url);
            if (variant == null) return parseMedia(text, body.url);
            url = variant;
        }
        throw new DownloadException("播放列表嵌套层级过多");
    }

    private static String bestVariant(String text, String base) throws IOException {
        String[] lines = text.split("\n");
        long best = -1;
        String chosen = null;
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i].trim();
            if (!line.startsWith("#EXT-X-STREAM-INF")) continue;
            long bandwidth = number(attribute(line, "BANDWIDTH"));
            String uri = null;
            for (int j = i + 1; j < lines.length; j++) {
                String next = lines[j].trim();
                if (next.isEmpty() || next.startsWith("#")) continue;
                uri = next;
                break;
            }
            if (uri != null && (chosen == null || bandwidth > best)) {
                best = bandwidth;
                chosen = absolute(base, uri);
            }
        }
        return chosen;
    }

    private static Media parseMedia(String text, String base) throws IOException {
        Media out = new Media();
        long sequence = 0;
        String keyUri = null;
        byte[] keyIv = null;
        long pendingLength = -1;
        long pendingOffset = -1;
        long nextOffset = 0;
        String lastUri = null;
        int index = 0;
        for (String raw : text.split("\n")) {
            String line = raw.trim();
            if (line.isEmpty()) continue;
            if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
                sequence = Math.max(0, number(line.substring(line.indexOf(':') + 1)));
            } else if (line.startsWith("#EXT-X-KEY:")) {
                String method = text(attribute(line, "METHOD")).toUpperCase(Locale.ROOT);
                if (method.isEmpty() || method.equals("NONE")) {
                    keyUri = null;
                    keyIv = null;
                } else if (method.equals("AES-128")) {
                    String uri = attribute(line, "URI");
                    if (uri == null || uri.isEmpty()) {
                        throw new DownloadException("播放列表缺少解密密钥地址");
                    }
                    keyUri = absolute(base, uri);
                    String iv = attribute(line, "IV");
                    keyIv = iv == null ? null : hexIv(iv);
                } else {
                    throw new DownloadException("该视频使用 " + method + " 加密，暂不支持下载");
                }
            } else if (line.startsWith("#EXT-X-MAP:")) {
                String uri = attribute(line, "URI");
                if (uri == null || uri.isEmpty()) continue;
                Segment init = new Segment();
                init.uri = absolute(base, uri);
                long[] range = byteRange(attribute(line, "BYTERANGE"));
                if (range != null) {
                    init.length = range[0];
                    init.offset = Math.max(0, range[1]);
                }
                if (keyUri != null && keyIv != null) {
                    init.key = keyUri;
                    init.iv = keyIv;
                }
                out.init = init;
            } else if (line.startsWith("#EXT-X-BYTERANGE:")) {
                long[] range = byteRange(line.substring(line.indexOf(':') + 1));
                if (range != null) {
                    pendingLength = range[0];
                    pendingOffset = range[1];
                }
            } else if (!line.startsWith("#")) {
                Segment segment = new Segment();
                segment.uri = absolute(base, line);
                if (pendingLength >= 0) {
                    boolean same = segment.uri.equals(lastUri);
                    long start = pendingOffset >= 0 ? pendingOffset : (same ? nextOffset : 0);
                    segment.offset = start;
                    segment.length = pendingLength;
                    nextOffset = start + pendingLength;
                }
                lastUri = segment.uri;
                pendingLength = -1;
                pendingOffset = -1;
                if (keyUri != null) {
                    segment.key = keyUri;
                    segment.iv = keyIv != null ? keyIv : sequenceIv(sequence + index);
                }
                out.segments.add(segment);
                index++;
            }
        }
        if (out.segments.isEmpty()) throw new DownloadException("播放列表中没有可下载的分片");
        return out;
    }

    /** Reads one attribute from an HLS tag such as {@code #EXT-X-KEY:METHOD=AES-128,URI="k"}. */
    static String attribute(String line, String name) {
        int colon = line.indexOf(':');
        if (colon < 0) return null;
        String list = line.substring(colon + 1);
        int i = 0;
        while (i < list.length()) {
            int eq = list.indexOf('=', i);
            if (eq < 0) return null;
            String key = list.substring(i, eq).trim();
            String value;
            int end;
            if (eq + 1 < list.length() && list.charAt(eq + 1) == '"') {
                int close = list.indexOf('"', eq + 2);
                if (close < 0) close = list.length();
                value = list.substring(eq + 2, close);
                end = list.indexOf(',', close);
            } else {
                end = list.indexOf(',', eq + 1);
                value = list.substring(eq + 1, end < 0 ? list.length() : end).trim();
            }
            if (key.equalsIgnoreCase(name)) return value;
            if (end < 0) return null;
            i = end + 1;
        }
        return null;
    }

    static long[] byteRange(String value) {
        if (value == null) return null;
        String[] parts = value.trim().split("@", 2);
        long length = number(parts[0]);
        long offset = parts.length > 1 ? number(parts[1]) : -1;
        return length < 0 ? null : new long[] {length, offset};
    }

    static byte[] sequenceIv(long sequence) {
        byte[] iv = new byte[16];
        for (int i = 0; i < 8; i++) iv[15 - i] = (byte) (sequence >>> (8 * i));
        return iv;
    }

    static byte[] hexIv(String value) throws DownloadException {
        String hex = value.trim();
        if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.substring(2);
        if (hex.isEmpty() || hex.length() > 32) throw new DownloadException("加密参数 IV 格式无效");
        StringBuilder padded = new StringBuilder();
        for (int i = hex.length(); i < 32; i++) padded.append('0');
        padded.append(hex);
        byte[] iv = new byte[16];
        for (int i = 0; i < 16; i++) {
            int high = Character.digit(padded.charAt(i * 2), 16);
            int low = Character.digit(padded.charAt(i * 2 + 1), 16);
            if (high < 0 || low < 0) throw new DownloadException("加密参数 IV 格式无效");
            iv[i] = (byte) ((high << 4) | low);
        }
        return iv;
    }

    static String absolute(String base, String uri) throws IOException {
        return new URL(new URL(base), uri).toString();
    }

    /** Downloads, decrypts and stores one segment; a finished file means a finished segment. */
    private void download(Run run, Segment s, File target, boolean counted) throws Exception {
        Exception last = null;
        for (int attempt = 0; attempt < 3; attempt++) {
            check(run);
            try {
                byte[] data = fetch(run, s.uri, s.range(), MAX_SEGMENT).data;
                if (s.key != null) data = decrypt(data, key(run, s.key), s.iv);
                File temp = new File(target.getPath() + ".tmp");
                try (OutputStream out = new FileOutputStream(temp)) {
                    out.write(data);
                }
                if (!temp.renameTo(target)) throw new DownloadException("无法写入分片文件");
                if (counted) {
                    synchronized (run.task) {
                        run.task.segments++;
                    }
                }
                return;
            } catch (Exception e) {
                if (stopped(run) || !retryable(e)) throw e;
                last = e;
            }
            Thread.sleep(800L * (attempt + 1));
        }
        throw last;
    }

    private static boolean retryable(Exception e) {
        if (e instanceof DownloadException) return ((DownloadException) e).retry();
        return true;
    }

    private byte[] key(Run run, String uri) throws Exception {
        synchronized (run.keys) {
            byte[] cached = run.keys.get(uri);
            if (cached != null) return cached;
        }
        byte[] key = fetch(run, uri, null, 4096).data;
        if (key.length != 16) {
            throw new DownloadException("解密密钥无效（" + key.length + " 字节），暂不支持下载");
        }
        synchronized (run.keys) {
            run.keys.put(uri, key);
        }
        return key;
    }

    static byte[] decrypt(byte[] data, byte[] key, byte[] iv) throws DownloadException {
        try {
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            SecretKeySpec spec = new SecretKeySpec(key, "AES");
            cipher.init(Cipher.DECRYPT_MODE, spec, new IvParameterSpec(iv));
            return cipher.doFinal(data);
        } catch (GeneralSecurityException e) {
            throw new DownloadException("分片解密失败，密钥可能已失效");
        }
    }

    // ---------------------------------------------------------------------
    // HTTP helpers
    // ---------------------------------------------------------------------

    private Fetched fetch(Run run, String url, String range, int limit) throws Exception {
        HttpURLConnection c = open(run, url, range);
        try (InputStream in = c.getInputStream()) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(65536);
            byte[] buffer = new byte[32768];
            int n;
            while ((n = in.read(buffer)) != -1) {
                check(run);
                if (out.size() + n > limit) throw new DownloadException("文件超过大小限制");
                out.write(buffer, 0, n);
                count(run.task, n);
            }
            Fetched result = new Fetched();
            result.data = out.toByteArray();
            result.url = c.getURL().toString();
            return result;
        } finally {
            release(run, c);
        }
    }

    private HttpURLConnection open(Run run, String address, String range) throws Exception {
        URL next = new URL(Cms.normalizeHttp(address));
        if (run.credentialOrigin != null
                && run.credentialOrigin.startsWith("https://")
                && !"https".equalsIgnoreCase(next.getProtocol())) {
            throw new DownloadException("拒绝将安全下载降级为 HTTP");
        }
        Map<String, String> activeHeaders =
                MediaRequestHeaders.forTarget(run.headers, run.credentialOrigin, next.toString());
        for (int hop = 0; hop < 6; hop++) {
            check(run);
            HttpURLConnection c = (HttpURLConnection) next.openConnection();
            c.setConnectTimeout(15000);
            c.setReadTimeout(30000);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", Cms.USER_AGENT);
            c.setRequestProperty("Accept-Encoding", "identity");
            for (Map.Entry<String, String> e : activeHeaders.entrySet()) {
                c.setRequestProperty(e.getKey(), e.getValue());
            }
            if (range != null) c.setRequestProperty("Range", range);
            synchronized (run.connections) {
                run.connections.add(c);
            }
            int status;
            try {
                status = c.getResponseCode();
            } catch (Exception e) {
                release(run, c);
                throw e;
            }
            if (status >= 300 && status < 400 && status != 304) {
                String location = c.getHeaderField("Location");
                release(run, c);
                if (location == null) throw new DownloadException("服务器重定向缺少目标地址");
                URL target = new URL(next, location);
                if (!Cms.isHttp(target.toString())) throw new DownloadException("不支持的重定向地址");
                if ("https".equalsIgnoreCase(next.getProtocol())
                        && !"https".equalsIgnoreCase(target.getProtocol())) {
                    throw new DownloadException("拒绝将安全下载降级为 HTTP");
                }
                activeHeaders =
                        MediaRequestHeaders.forTarget(
                                activeHeaders, next.toString(), target.toString());
                next = target;
                continue;
            }
            if (status < 200 || status >= 300) {
                release(run, c);
                throw new HttpStatusException(status);
            }
            return c;
        }
        throw new DownloadException("服务器重定向次数过多");
    }

    private static void release(Run run, HttpURLConnection c) {
        synchronized (run.connections) {
            run.connections.remove(c);
        }
        try {
            c.disconnect();
        } catch (Exception ignored) {
        }
    }

    private static void count(Task t, int n) {
        long now = SystemClock.elapsedRealtime();
        synchronized (t) {
            t.bytes += n;
            t.windowBytes += n;
            long elapsed = now - t.windowStart;
            if (elapsed >= 1000) {
                t.speed = elapsed > 5000 ? 0 : t.windowBytes * 1000 / elapsed;
                t.windowBytes = 0;
                t.windowStart = now;
            }
        }
    }

    static long number(String value) {
        if (value == null) return -1;
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    static String size(long bytes) {
        if (bytes < 1024) return Math.max(0, bytes) + " B";
        if (bytes < MB) return String.format(Locale.ROOT, "%.0f KB", bytes / 1024.0);
        if (bytes < GB) return String.format(Locale.ROOT, "%.1f MB", bytes / (double) MB);
        return String.format(Locale.ROOT, "%.2f GB", bytes / (double) GB);
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    File folder() throws IOException {
        File dir = null;
        try {
            dir = app.getExternalFilesDir(Environment.DIRECTORY_MOVIES);
        } catch (Exception e) {
            AppLog.w(TAG, "external files dir unavailable", e);
        }
        if (dir == null || (!dir.isDirectory() && !dir.mkdirs())) {
            dir = new File(app.getFilesDir(), "downloads");
        }
        if (!dir.isDirectory() && !dir.mkdirs()) throw new DownloadException("无法创建下载目录");
        return dir;
    }

    private File workFile(Task t, String suffix) throws IOException {
        if (t.base.isEmpty()) t.base = new File(folder(), fileName(t)).getAbsolutePath();
        return new File(t.base + suffix);
    }

    private File outputFile(Task t, String ext) throws IOException {
        return workFile(t, ext);
    }

    static String fileName(Task t) {
        String name = (t.title + " " + t.episode).replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
        name = name.trim();
        if (name.length() > 60) name = name.substring(0, 60).trim();
        if (name.isEmpty() || name.startsWith(".")) name = "video" + name;
        return name + "_" + t.id;
    }

    private static void cleanup(Task t) {
        String base = t.base;
        if (!base.isEmpty()) {
            new File(base + ".part").delete();
            new File(base + ".ts.tmp").delete();
            new File(base + ".mp4.tmp").delete();
            deleteTree(new File(base + ".parts"));
        }
        if (!t.path.isEmpty()) new File(t.path).delete();
    }

    static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) deleteTree(child);
        }
        file.delete();
    }

    private void load() {
        List<Task> restart = new ArrayList<>();
        try {
            if (store.isFile()) {
                JSONArray items = new JSONArray(readText(store));
                for (int i = 0; i < items.length(); i++) {
                    JSONObject item = items.optJSONObject(i);
                    if (item == null) continue;
                    Task t = Task.from(item);
                    if (t.id.isEmpty()) continue;
                    if (t.state == WAITING || t.state == RUNNING) restart.add(t);
                    tasks.add(t);
                }
            }
        } catch (Exception e) {
            AppLog.w(TAG, "load downloads failed", e);
        }
        for (Task t : restart) schedule(t);
    }

    private static String readText(File file) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
            return new String(out.toByteArray(), "UTF-8");
        }
    }

    private void save() {
        saver.execute(this::write);
    }

    private void write() {
        String text;
        synchronized (this) {
            JSONArray items = new JSONArray();
            for (Task t : tasks) {
                try {
                    items.put(t.json());
                } catch (JSONException e) {
                    AppLog.w(TAG, "encode download failed", e);
                }
            }
            text = items.toString();
        }
        File temp = new File(store.getPath() + ".tmp");
        try {
            try (OutputStream out = new FileOutputStream(temp)) {
                out.write(text.getBytes("UTF-8"));
            }
            if (!temp.renameTo(store)) AppLog.i(TAG, "replace download list failed");
        } catch (IOException e) {
            AppLog.w(TAG, "save downloads failed", e);
        }
    }
}
