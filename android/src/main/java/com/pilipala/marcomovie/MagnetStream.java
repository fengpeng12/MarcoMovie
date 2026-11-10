package com.pilipala.marcomovie;

import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import com.frostwire.jlibtorrent.*;
import com.frostwire.jlibtorrent.alerts.*;
import com.frostwire.jlibtorrent.swig.settings_pack;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** A single, cancellable torrent playback session. HTTP never serves unverified pieces. */
public final class MagnetStream implements Closeable {
    public interface Selection {
        void select(int listIndex);
    }

    public interface Listener {
        default void progress(String message) {}

        /** Override to show a file picker; selection indexes refer to this filtered video list. */
        default void files(List<MediaFile> files, int suggestedIndex, Selection selection) {
            selection.select(suggestedIndex);
        }

        void ready(String url, String mime, String name);

        void error(String message);
    }

    public static final class MediaFile {
        public final int torrentIndex;
        public final String name;
        public final long size;
        public final String mime;

        MediaFile(int index, String name, long size) {
            this.torrentIndex = index;
            this.name = name;
            this.size = size;
            this.mime = mime(name);
        }
    }

    static final long METADATA_TIMEOUT_MS = 180000, PIECE_TIMEOUT_MS = 45000;
    static final int MAX_FILES = 2000, READ_BUFFER = 64 * 1024;
    final Listener listener;
    final Handler main;
    final File directory;
    final AtomicBoolean closed = new AtomicBoolean(), errorSent = new AtomicBoolean();
    final ExecutorService control = Executors.newSingleThreadExecutor(daemon("torrent-control"));
    final ThreadPoolExecutor clients =
            new ThreadPoolExecutor(
                    0,
                    4,
                    20,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    daemon("torrent-http"));
    final Set<Socket> sockets = Collections.newSetFromMap(new ConcurrentHashMap<Socket, Boolean>());
    final CountDownLatch added = new CountDownLatch(1),
            metadata = new CountDownLatch(1),
            chosen = new CountDownLatch(1);
    final String token = UUID.randomUUID().toString();
    volatile SessionManager session;
    volatile TorrentHandle handle;
    volatile TorrentInfo info;
    volatile ServerSocket server;
    volatile MediaFile selected;
    volatile int selection = -1;
    volatile String nativeFailure;
    volatile boolean ready;
    volatile long selectedOffset;
    volatile int pieceLength;

    private MagnetStream(Context context, Listener listener) throws IOException {
        this(
                listener,
                new File(
                        context.getApplicationContext().getCacheDir(),
                        "magnet-streams/session-" + UUID.randomUUID()),
                new Handler(Looper.getMainLooper()));
    }

    /** Package-private constructor permits an offline JVM fixture without Android services. */
    MagnetStream(Listener listener, File directory, Handler callbacks) throws IOException {
        this.listener = Objects.requireNonNull(listener);
        this.directory = directory.getCanonicalFile();
        this.main = callbacks;
        if (!this.directory.mkdirs() && !this.directory.isDirectory())
            throw new IOException("无法创建磁力播放缓存");
    }

    public static MagnetStream start(Context context, String magnet, Listener listener)
            throws IOException {
        MagnetStream stream = new MagnetStream(context, listener);
        stream.control.execute(
                () -> {
                    if (Build.VERSION.SDK_INT < 26) {
                        stream.fail("磁力播放需要 Android 8 或更高版本。");
                        return;
                    }
                    stream.begin(magnet, null);
                });
        return stream;
    }

    static ThreadFactory daemon(String name) {
        return task -> {
            Thread thread = new Thread(task, name);
            thread.setDaemon(true);
            return thread;
        };
    }

    void dispatch(Runnable callback) {
        if (closed.get()) return;
        if (main == null) {
            if (!closed.get()) callback.run();
        } else
            main.post(
                    () -> {
                        if (!closed.get()) callback.run();
                    });
    }

    void status(String message) {
        dispatch(() -> listener.progress(message));
    }

    void begin(String magnet, SessionParams fixtureSettings) {
        try {
            if (magnet == null
                    || !magnet.regionMatches(true, 0, "magnet:?", 0, 8)
                    || magnet.length() > 32768) throw new IOException("磁力地址格式不正确");
            status("正在连接磁力网络，获取影片文件列表…");
            SessionParams params = fixtureSettings == null ? new SessionParams() : fixtureSettings;
            params.setPosixDiskIO();
            SettingsPack settings = params.getSettings();
            settings.connectionsLimit(60);
            settings.activeDownloads(1);
            settings.activeSeeds(0);
            settings.uploadRateLimit(128 * 1024);
            settings.setBoolean(settings_pack.bool_types.enable_upnp.swigValue(), false);
            settings.setBoolean(settings_pack.bool_types.enable_natpmp.swigValue(), false);
            // Bound metadata and peer bookkeeping on a television with little RAM.
            settings.setInteger(
                    settings_pack.int_types.max_metadata_size.swigValue(), 8 * 1024 * 1024);
            settings.setInteger(settings_pack.int_types.max_peerlist_size.swigValue(), 500);
            params.setSettings(settings);
            session = new SessionManager(false);
            session.addListener(
                    new AlertListener() {
                        public int[] types() {
                            return new int[] {
                                AlertType.ADD_TORRENT.swig(),
                                AlertType.METADATA_RECEIVED.swig(),
                                AlertType.TORRENT_ERROR.swig()
                            };
                        }

                        public void alert(Alert<?> alert) {
                            try {
                                if (closed.get()) return;
                                // Alert handles borrow storage from the native alert queue.
                                // Reacquire an owned handle before keeping it past callback.
                                if (alert instanceof AddTorrentAlert) {
                                    AddTorrentAlert addedAlert = (AddTorrentAlert) alert;
                                    if (addedAlert.error().value() != 0) {
                                        nativeFailure = addedAlert.error().message();
                                        added.countDown();
                                        metadata.countDown();
                                        return;
                                    }
                                    handle =
                                            session.find(
                                                    addedAlert.params().getInfoHashes().getBest());
                                    if (handle == null)
                                        throw new IOException(
                                                "Native torrent handle is unavailable");
                                    handle.unsetFlags(
                                            TorrentFlags.AUTO_MANAGED.or_(TorrentFlags.PAUSED));
                                    handle.resume();
                                    added.countDown();
                                } else if (alert instanceof MetadataReceivedAlert) {
                                    if (handle == null)
                                        handle =
                                                session.find(
                                                        ((MetadataReceivedAlert) alert)
                                                                .handle()
                                                                .infoHash());
                                    info = handle.torrentFile();
                                    metadata.countDown();
                                } else if (alert instanceof TorrentErrorAlert) {
                                    nativeFailure = ((TorrentErrorAlert) alert).error().message();
                                    added.countDown();
                                    metadata.countDown();
                                }
                            } catch (Throwable error) {
                                AppLog.w("MagnetStream", "alert callback failed", error);
                                nativeFailure = error.getClass().getSimpleName();
                                added.countDown();
                                metadata.countDown();
                            }
                        }
                    });
            session.start(params);
            checkOpen();
            // Metadata is exchanged while payload downloading remains disabled.
            session.download(
                    magnet,
                    directory,
                    TorrentFlags.UPLOAD_MODE.or_(TorrentFlags.SEQUENTIAL_DOWNLOAD));
            if (!added.await(30, TimeUnit.SECONDS)) throw new IOException("磁力任务创建超时");
            checkNative();
            if (!metadata.await(METADATA_TIMEOUT_MS, TimeUnit.MILLISECONDS))
                throw new IOException("暂未取得磁力文件列表，请检查是否有可连接的分享者");
            checkNative();
            checkOpen();
            if (info == null && handle != null) info = handle.torrentFile();
            if (info == null || !info.isValid()) throw new IOException("磁力来源没有返回有效文件列表");
            List<MediaFile> files = videoFiles(info);
            if (files.isEmpty()) throw new IOException("这个磁力任务中没有可播放的视频文件");
            int largest = 0;
            for (int i = 1; i < files.size(); i++)
                if (files.get(i).size > files.get(largest).size) largest = i;
            final int suggested = largest;
            final List<MediaFile> choices = Collections.unmodifiableList(files);
            status("请选择要播放的视频文件");
            dispatch(
                    () ->
                            listener.files(
                                    choices,
                                    suggested,
                                    index -> {
                                        if (index < 0 || index >= choices.size() || closed.get())
                                            return;
                                        if (selection < 0) {
                                            selection = index;
                                            chosen.countDown();
                                        }
                                    }));
            if (!chosen.await(5, TimeUnit.MINUTES)) throw new IOException("尚未选择磁力中的视频文件");
            checkOpen();
            selected = choices.get(selection);
            if (selected.size > Math.max(0, directory.getUsableSpace() - 64L * 1024 * 1024))
                throw new IOException("电视缓存空间不足以保存这个视频，请选择较小的文件");
            selectPayload();
            startServer();
            status("正在缓冲磁力视频…");
            long initialBytes = Math.min(selected.size, 512 * 1024);
            long position = 0;
            while (position < initialBytes) {
                int piece = pieceAt(position);
                awaitPiece(piece, PIECE_TIMEOUT_MS);
                position =
                        Math.min(initialBytes, ((long) (piece + 1) * pieceLength) - selectedOffset);
            }
            checkOpen();
            ready = true;
            String url =
                    "http://127.0.0.1:"
                            + server.getLocalPort()
                            + "/stream/"
                            + token
                            + "/"
                            + URLEncoder.encode(selected.name, "UTF-8").replace("+", "%20");
            dispatch(() -> listener.ready(url, selected.mime, selected.name));
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            if (!closed.get()) fail("磁力播放已取消");
        } catch (Throwable error) {
            AppLog.w("MagnetStream", "magnet session failed", error);
            if (!closed.get())
                fail(
                        error instanceof IOException
                                ? error.getMessage()
                                : "磁力引擎无法启动：" + error.getClass().getSimpleName());
        }
    }

    List<MediaFile> videoFiles(TorrentInfo torrent) throws IOException {
        FileStorage storage = torrent.files();
        int count = storage.numFiles();
        if (count <= 0 || count > MAX_FILES) throw new IOException("磁力文件数量超出播放器限制");
        List<MediaFile> media = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            String path = storage.filePath(i);
            validateRelativePath(directory, path);
            if (storage.fileAbsolutePath(i)
                    || storage.fileFlags(i).and_(FileStorage.FLAG_SYMLINK).to_int() != 0)
                throw new IOException("磁力文件包含不支持的路径");
            if (storage.padFileAt(i) || storage.fileSize(i) <= 0) continue;
            if (videoName(path)) media.add(new MediaFile(i, path, storage.fileSize(i)));
        }
        return media;
    }

    void selectPayload() throws IOException {
        FileStorage files = info.files();
        pieceLength = info.pieceLength();
        if (pieceLength <= 0 || pieceLength > 64 * 1024 * 1024) throw new IOException("磁力分片大小不受支持");
        selectedOffset = files.fileOffset(selected.torrentIndex);
        Priority[] priorities = Priority.array(Priority.IGNORE, files.numFiles());
        priorities[selected.torrentIndex] = Priority.NORMAL;
        handle.prioritizeFiles(priorities);
        handle.unsetFlags(
                TorrentFlags.UPLOAD_MODE.or_(TorrentFlags.AUTO_MANAGED).or_(TorrentFlags.PAUSED));
        handle.setFlags(TorrentFlags.SEQUENTIAL_DOWNLOAD);
        handle.resume();
        prioritize(pieceAt(0));
        int last = pieceAt(selected.size - 1);
        handle.piecePriority(last, Priority.SEVEN);
        handle.setPieceDeadline(last, 1500);
    }

    int pieceAt(long filePosition) {
        return (int) ((selectedOffset + filePosition) / pieceLength);
    }

    void prioritize(int first) {
        if (handle == null || info == null) return;
        int last = pieceAt(selected.size - 1);
        for (int piece = first; piece <= Math.min(last, first + 12); piece++) {
            if (!handle.havePiece(piece)) {
                handle.piecePriority(piece, Priority.SEVEN);
                handle.setPieceDeadline(piece, (piece - first) * 150);
            }
        }
    }

    void awaitPiece(int piece, long timeout) throws IOException, InterruptedException {
        long until = (System.nanoTime() / 1000000L) + timeout;
        prioritize(piece);
        while (!closed.get()) {
            checkNative();
            if (handle != null && handle.isValid() && handle.havePiece(piece)) return;
            if ((System.nanoTime() / 1000000L) >= until)
                throw new IOException("视频分片缓冲超时，暂时没有可用的分享者");
            Thread.sleep(80);
        }
        throw new IOException("磁力播放已关闭");
    }

    void checkOpen() throws IOException {
        if (closed.get()) throw new IOException("磁力播放已关闭");
    }

    void checkNative() throws IOException {
        if (nativeFailure != null) throw new IOException("磁力任务错误：" + nativeFailure);
    }

    void startServer() throws IOException {
        server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0));
        Thread accept =
                daemon("torrent-http-accept")
                        .newThread(
                                () -> {
                                    while (!closed.get())
                                        try {
                                            Socket socket = server.accept();
                                            sockets.add(socket);
                                            try {
                                                clients.execute(() -> serve(socket));
                                            } catch (RejectedExecutionException full) {
                                                sockets.remove(socket);
                                                socket.close();
                                            }
                                        } catch (IOException error) {
                                            if (!closed.get()) fail("磁力本地播放服务已中断");
                                        }
                                });
        accept.start();
    }

    void serve(Socket socket) {
        boolean headersSent = false;
        try {
            Socket connection = socket;
            connection.setSoTimeout(15000);
            InputStream input = connection.getInputStream();
            OutputStream output = connection.getOutputStream();
            String request = readLine(input, 4096);
            String[] fields = request.split(" ");
            if (fields.length != 3 || (!fields[0].equals("GET") && !fields[0].equals("HEAD"))) {
                reply(output, 405, "Method Not Allowed", "");
                return;
            }
            if (!fields[1].startsWith("/stream/" + token + "/")) {
                reply(output, 404, "Not Found", "");
                return;
            }
            Map<String, String> headers = new HashMap<>();
            int bytes = 0;
            for (; ; ) {
                String line = readLine(input, 8192);
                bytes += line.length();
                if (bytes > 32768) throw new IOException("HTTP headers exceed limit");
                if (line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0)
                    headers.put(
                            line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            line.substring(colon + 1).trim());
            }
            if (selected == null) {
                reply(output, 503, "Service Unavailable", "");
                return;
            }
            long[] range = parseRange(headers.get("range"), selected.size);
            if (range == null) {
                reply(
                        output,
                        416,
                        "Range Not Satisfiable",
                        "Content-Range: bytes */" + selected.size + "\r\n");
                return;
            }
            long start = range[0], end = range[1];
            boolean partial = headers.containsKey("range");
            // Wait before emitting headers so an unavailable first piece produces
            // a truthful retryable HTTP error rather than a fake empty video.
            if (fields[0].equals("GET")) awaitPiece(pieceAt(start), PIECE_TIMEOUT_MS);
            String head =
                    "HTTP/1.1 "
                            + (partial ? "206 Partial Content" : "200 OK")
                            + "\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: "
                            + selected.mime
                            + "\r\nContent-Length: "
                            + (end - start + 1)
                            + "\r\nCache-Control: no-store\r\n"
                            + (partial
                                    ? "Content-Range: bytes "
                                            + start
                                            + "-"
                                            + end
                                            + "/"
                                            + selected.size
                                            + "\r\n"
                                    : "")
                            + "\r\n";
            output.write(head.getBytes("US-ASCII"));
            headersSent = true;
            if (fields[0].equals("HEAD")) {
                output.flush();
                return;
            }
            File file = validateRelativePath(directory, selected.name);
            byte[] buffer = new byte[READ_BUFFER];
            try (RandomAccessFile media = new RandomAccessFile(file, "r")) {
                long position = start;
                while (position <= end && !closed.get()) {
                    int piece = pieceAt(position);
                    awaitPiece(piece, PIECE_TIMEOUT_MS);
                    long verifiedEnd =
                            Math.min(end, ((long) (piece + 1) * pieceLength) - selectedOffset - 1);
                    while (position <= verifiedEnd) {
                        int count = (int) Math.min(buffer.length, verifiedEnd - position + 1);
                        media.seek(position);
                        media.readFully(buffer, 0, count);
                        output.write(buffer, 0, count);
                        position += count;
                    }
                }
            }
            output.flush();
        } catch (Exception error) {
            if (!headersSent)
                try {
                    reply(
                            socket.getOutputStream(),
                            503,
                            "Service Unavailable",
                            "Retry-After: 2\r\n");
                } catch (Exception ignored) {
                }
        } finally {
            sockets.remove(socket);
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }

    static String readLine(InputStream input, int limit) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int value;
        while ((value = input.read()) != -1) {
            if (value == '\n') break;
            if (value != '\r') bytes.write(value);
            if (bytes.size() > limit) throw new IOException("HTTP line exceeds limit");
        }
        return bytes.toString("ISO-8859-1");
    }

    static void reply(OutputStream output, int code, String reason, String extra)
            throws IOException {
        output.write(
                ("HTTP/1.1 "
                                + code
                                + " "
                                + reason
                                + "\r\nConnection: close\r\nContent-Length: 0\r\n"
                                + extra
                                + "\r\n")
                        .getBytes("US-ASCII"));
        output.flush();
    }

    static long[] parseRange(String header, long size) {
        if (size <= 0) return null;
        if (header == null) return new long[] {0, size - 1};
        if (!header.startsWith("bytes=") || header.indexOf(',') >= 0) return null;
        String[] parts = header.substring(6).split("-", -1);
        if (parts.length != 2) return null;
        try {
            long start, end;
            if (parts[0].isEmpty()) {
                long suffix = Long.parseLong(parts[1]);
                if (suffix <= 0) return null;
                start = Math.max(0, size - suffix);
                end = size - 1;
            } else {
                start = Long.parseLong(parts[0]);
                end = parts[1].isEmpty() ? size - 1 : Long.parseLong(parts[1]);
                if (start < 0 || start >= size || end < start) return null;
                end = Math.min(end, size - 1);
            }
            return new long[] {start, end};
        } catch (NumberFormatException error) {
            return null;
        }
    }

    static File validateRelativePath(File root, String path) throws IOException {
        if (path == null
                || path.isEmpty()
                || path.indexOf('\0') >= 0
                || path.startsWith("/")
                || path.startsWith("\\")
                || path.matches("^[A-Za-z]:.*")) throw new IOException("磁力文件路径不受支持");
        String normalized = path.replace('\\', '/');
        for (String part : normalized.split("/"))
            if (part.equals("..")) throw new IOException("磁力文件路径越界");
        File file = new File(root, normalized).getCanonicalFile();
        String prefix = root.getCanonicalPath() + File.separator;
        if (!file.getPath().startsWith(prefix)) throw new IOException("磁力文件路径越界");
        return file;
    }

    static boolean videoName(String name) {
        return name.toLowerCase(Locale.ROOT)
                .matches(".*\\.(mp4|mkv|webm|avi|mov|m4v|ts|m2ts|mpg|mpeg|flv)$");
    }

    static String mime(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".mkv")) return "video/x-matroska";
        if (lower.endsWith(".webm")) return "video/webm";
        if (lower.endsWith(".ts") || lower.endsWith(".m2ts")) return "video/mp2t";
        if (lower.endsWith(".avi")) return "video/x-msvideo";
        if (lower.endsWith(".flv")) return "video/x-flv";
        return "video/mp4";
    }

    void fail(String message) {
        if (!errorSent.compareAndSet(false, true) || closed.get()) return;
        String value = message == null ? "磁力播放失败" : message;
        if (main == null) listener.error(value);
        else main.post(() -> listener.error(value));
        close();
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) return;
        added.countDown();
        metadata.countDown();
        chosen.countDown();
        ServerSocket listenerSocket = server;
        if (listenerSocket != null)
            try {
                listenerSocket.close();
            } catch (IOException ignored) {
            }
        for (Socket socket : sockets)
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        clients.shutdownNow();
        control.shutdownNow();
        Thread cleanup =
                daemon("torrent-cleanup")
                        .newThread(
                                () -> {
                                    SessionManager running = session;
                                    if (running != null)
                                        try {
                                            running.stop();
                                        } catch (Throwable ignored) {
                                        }
                                    try {
                                        deleteOwned(
                                                directory,
                                                directory.getCanonicalPath() + File.separator);
                                    } catch (IOException ignored) {
                                    }
                                });
        cleanup.start();
    }

    static void deleteOwned(File file, String prefix) throws IOException {
        String absolute = file.getAbsolutePath();
        if (!absolute.equals(prefix.substring(0, prefix.length() - 1))
                && !absolute.startsWith(prefix)) return;
        if (isSymlink(file)) {
            file.delete();
            return;
        }
        String resolved = file.getCanonicalPath();
        if (!resolved.equals(prefix.substring(0, prefix.length() - 1))
                && !resolved.startsWith(prefix)) return;
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) for (File child : children) deleteOwned(child, prefix);
        }
        file.delete();
    }

    private static boolean isSymlink(File file) throws IOException {
        File canon;
        if (file.getParent() == null) {
            canon = file;
        } else {
            File canonDir = file.getParentFile().getCanonicalFile();
            canon = new File(canonDir, file.getName());
        }
        return !canon.getCanonicalFile().equals(canon.getAbsoluteFile());
    }
}
