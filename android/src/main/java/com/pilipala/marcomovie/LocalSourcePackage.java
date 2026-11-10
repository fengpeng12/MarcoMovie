package com.pilipala.marcomovie;

import java.io.*;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

/** Copies an imported package into its own immutable directory after validating its entry point. */
final class LocalSourcePackage {
    final Cms.Config config;
    final String origin;
    final int liveChannels;

    private LocalSourcePackage(File root, File entry) throws Exception {
        origin = Cms.fileUri(entry);
        String text;
        try (InputStream in = new FileInputStream(entry)) {
            text = Cms.read(in, Cms.MAX_JSON);
        }
        if (playlist(entry)) {
            LiveCatalog.Catalog live = LiveCatalog.parse(text, origin, null);
            for (LiveCatalog.Group group : live.groups)
                for (LiveCatalog.Channel channel : group.channels) {
                    if (!channel.logo.isEmpty()) checkLocal(root, channel.logo);
                    for (LiveCatalog.Stream stream : channel.streams) checkLocal(root, stream.url);
                }
            liveChannels = live.channelCount();
            config = null;
            return;
        }
        config = Cms.parseConfig(text, origin);
        liveChannels = 0;
        checkLocal(root, config.spider);
        boolean pythonChecked = false;
        for (Cms.Site site : config.sites) {
            checkLocal(root, site.api);
            checkLocal(root, site.jar);
            if (site.ext instanceof String) checkLocal(root, (String) site.ext);
            if (!pythonChecked
                    && site.api.startsWith("file:")
                    && site.api.toLowerCase(Locale.ROOT).endsWith(".py")) {
                readPythonPackage(root, new File(new URI(site.api)));
                pythonChecked = true;
            }
            if (("csp_Drpy".equalsIgnoreCase(site.api)
                            || "csp_LocalRule.js".equalsIgnoreCase(site.api))
                    && site.ext instanceof String
                    && !Cms.looksLikeDrpyRule((String) site.ext)
                    && !((String) site.ext).trim().startsWith("{"))
                checkLocal(root, Cms.resolve(origin, (String) site.ext));
            if (("csp_Drpy".equalsIgnoreCase(site.api)
                            || "csp_LocalRule.js".equalsIgnoreCase(site.api))
                    && site.ext instanceof org.json.JSONObject) {
                Object rule = ((org.json.JSONObject) site.ext).opt("rule");
                if (rule instanceof String
                        && !Cms.looksLikeDrpyRule((String) rule)
                        && !((String) rule).trim().startsWith("{"))
                    checkLocal(root, Cms.resolve(origin, (String) rule));
            }
        }
    }

    /** An immutable snapshot of this imported package, never the application files directory. */
    static final class PythonPackage {
        final String entry, source;
        final Map<String, byte[]> files;
        final Map<String, String> modules;

        PythonPackage(String entry, Map<String, byte[]> files) throws IOException {
            this.entry = entry;
            this.files = Collections.unmodifiableMap(files);
            source = pythonText(files.get(entry));
            String directory =
                    entry.contains("/") ? entry.substring(0, entry.lastIndexOf('/') + 1) : "";
            Map<String, String> imported = new LinkedHashMap<>();
            for (Map.Entry<String, byte[]> file : files.entrySet()) {
                if (!file.getKey().startsWith(directory)) continue;
                String relative = file.getKey().substring(directory.length());
                if (relative.matches("(?:[A-Za-z_]\\w*/)*[A-Za-z_]\\w*\\.py"))
                    imported.put(relative, pythonText(file.getValue()));
            }
            modules = Collections.unmodifiableMap(imported);
        }
    }

    /** Return null for standalone/remote sources; only an installed SHA-256 package grants data. */
    static PythonPackage pythonPackage(File filesDir, String address) throws Exception {
        if (address == null || !address.startsWith("file:")) return null;
        File store = new File(filesDir, "source-packages").getCanonicalFile();
        File requested = new File(new URI(address)).getAbsoluteFile();
        File entry = requested.getCanonicalFile();
        String prefix = store.getPath() + File.separator;
        if (!entry.getPath().startsWith(prefix)) {
            if (requested.getPath().startsWith(prefix)) throw new IOException("Python 本地包路径越界");
            return null;
        }
        String relative = entry.getPath().substring(prefix.length());
        int separator = relative.indexOf(File.separatorChar);
        if (separator < 0 || !relative.substring(0, separator).matches("[a-f0-9]{64}"))
            throw new IOException("Python 本地包标识无效");
        File root = new File(store, relative.substring(0, separator)).getCanonicalFile();
        if (!root.getParentFile().equals(store)) throw new IOException("Python 本地包路径越界");
        return readPythonPackage(root, entry);
    }

    private static PythonPackage readPythonPackage(File packageRoot, File source)
            throws IOException {
        File root = packageRoot.getCanonicalFile(), entry = source.getCanonicalFile();
        if (!entry.isFile() || !entry.getPath().startsWith(root.getPath() + File.separator))
            throw new IOException("Python 本地包缺少入口或入口越界");
        Map<String, byte[]> files = new LinkedHashMap<>();
        collectPythonFiles(root, root, files, new int[2]);
        String relative = root.toURI().relativize(entry.toURI()).getPath();
        if (!files.containsKey(relative)) throw new IOException("Python 本地包缺少入口");
        return new PythonPackage(relative, files);
    }

    private static void collectPythonFiles(
            File root, File directory, Map<String, byte[]> files, int[] counts) throws IOException {
        File[] children = directory.listFiles();
        if (children == null) throw new IOException("无法读取 Python 本地包目录");
        Arrays.sort(children, (a, b) -> a.getName().compareTo(b.getName()));
        for (File child : children) {
            if (Thread.currentThread().isInterrupted())
                throw new InterruptedIOException("Python 本地包读取已取消");
            if (++counts[0] > 2048) throw new IOException("Python 本地包目录数量超过限制");
            File canonical = child.getCanonicalFile();
            if (!canonical.equals(child.getAbsoluteFile())
                    || !canonical.getPath().startsWith(root.getPath() + File.separator))
                throw new IOException("Python 本地包不允许链接或包外文件");
            String relative = root.toURI().relativize(canonical.toURI()).getPath();
            if (relative.endsWith("/")) relative = relative.substring(0, relative.length() - 1);
            if (relative.isEmpty()
                    || relative.length() > 512
                    || java.util.regex.Pattern.compile("[\\\\:'\"\\x00-\\x1f\\x7f\\u2028\\u2029]")
                            .matcher(relative)
                            .find()) throw new IOException("Python 本地包文件名无效");
            for (String component : relative.split("/", -1))
                if (component.isEmpty() || component.equals(".") || component.equals(".."))
                    throw new IOException("Python 本地包路径无效");
            if (canonical.isDirectory()) {
                collectPythonFiles(root, canonical, files, counts);
                continue;
            }
            if (!canonical.isFile() || files.size() >= 256)
                throw new IOException("Python 本地包最多支持 256 个文件");
            try (InputStream in = new FileInputStream(canonical);
                    ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192];
                for (int n; (n = in.read(buffer)) != -1; ) {
                    if (Thread.currentThread().isInterrupted())
                        throw new InterruptedIOException("Python 本地包读取已取消");
                    if (out.size() + n > 2 * 1024 * 1024 || (counts[1] += n) > 6 * 1024 * 1024)
                        throw new IOException("Python 本地包单文件限 2 MiB、总计限 6 MiB");
                    out.write(buffer, 0, n);
                }
                files.put(relative, out.toByteArray());
            }
        }
    }

    private static String pythonText(byte[] bytes) throws IOException {
        return StandardCharsets.UTF_8
                .newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString();
    }

    private static void checkLocal(File root, String address) throws Exception {
        if (address == null || !address.startsWith("file:")) return;
        File resource = new File(new URI(address.split(";md5;", 2)[0])).getCanonicalFile();
        if (!resource.getPath().startsWith(root.getCanonicalPath() + File.separator)
                || !resource.isFile()) throw new IOException("本地包缺少资源或引用了包外文件");
    }

    private static int rank(File entry) {
        List<String> names =
                Arrays.asList("config.json", "tv.json", "api.json", "index.json", "main.json");
        int index = names.indexOf(entry.getName().toLowerCase(Locale.ROOT));
        return index < 0 ? names.size() : index;
    }

    private static boolean script(File file) {
        return file.getName().toLowerCase(Locale.ROOT).matches(".*\\.(js|mjs|py)");
    }

    private static boolean playlist(File file) {
        return file.getName().toLowerCase(Locale.ROOT).matches(".*\\.(txt|m3u|m3u8)");
    }

    private static int scriptRank(File file) {
        String stem = file.getName().toLowerCase(Locale.ROOT).replaceFirst("\\.[^.]+$", "");
        int rank = Arrays.asList("main", "index", "spider").indexOf(stem);
        return rank < 0 ? 3 : rank;
    }

    private static File chooseEntry(List<File> files) throws IOException {
        List<File> json = new ArrayList<>(),
                configs = new ArrayList<>(),
                scripts = new ArrayList<>(),
                playlists = new ArrayList<>();
        for (File file : files) {
            if (file.getName().toLowerCase(Locale.ROOT).endsWith(".json")) {
                json.add(file);
                if (configuration(file)) configs.add(file);
            }
            if (script(file)) scripts.add(file);
            if (playlist(file)) playlists.add(file);
        }
        Collections.sort(configs, (a, b) -> Integer.compare(rank(a), rank(b)));
        Collections.sort(scripts, (a, b) -> Integer.compare(scriptRank(a), scriptRank(b)));
        // An explicitly named JSON config takes precedence over script helpers.
        if (!configs.isEmpty()) {
            if (configs.size() > 1 && rank(configs.get(0)) == rank(configs.get(1)))
                throw new IOException("本地包含多个同名 JSON 入口");
            return configs.get(0);
        }
        // A named script may include JSON data beside it without making that data
        // the subscription entry. Ambiguous script entries are never guessed.
        if (!scripts.isEmpty()) {
            if (scripts.size() > 1 && scriptRank(scripts.get(0)) == scriptRank(scripts.get(1)))
                throw new IOException("本地包需要唯一的脚本入口，例如 main.py 或 index.js");
            return scripts.get(0);
        }
        if (json.size() == 1) return json.get(0);
        if (!json.isEmpty()) throw new IOException("本地包需要唯一的 JSON 入口，例如 config.json");
        if (playlists.size() == 1) return playlists.get(0);
        throw new IOException("本地包需要明确的 JSON、JS、PY 或单播放列表入口");
    }

    private static boolean configuration(File file) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            Object parsed =
                    new org.json.JSONTokener(Cms.withoutComments(Cms.read(in, Cms.MAX_JSON)))
                            .nextValue();
            if (parsed instanceof org.json.JSONArray)
                return Cms.isSiteArray((org.json.JSONArray) parsed);
            if (!(parsed instanceof org.json.JSONObject)) return false;
            org.json.JSONObject value = (org.json.JSONObject) parsed;
            return value.optJSONArray("sites") != null
                    || !value.optString("api").isEmpty()
                    || com.pilipala.source.Warehouse.isCatalog(value);
        } catch (org.json.JSONException invalid) {
            return false;
        }
    }

    static synchronized LocalSourcePackage open(File filesDir, byte[] bytes) throws Exception {
        if (bytes.length > 28 * 1024 * 1024) throw new IOException("本地包超过 28 MB");
        File store = new File(filesDir, "source-packages");
        if (!store.isDirectory() && !store.mkdir()) throw new IOException("无法创建本地包目录");
        StringBuilder digest = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes))
            digest.append(String.format(Locale.ROOT, "%02x", b & 255));
        File installed = new File(store, digest.toString());
        File stage = new File(store, "import-" + UUID.randomUUID());
        if (!stage.mkdir()) throw new IOException("无法准备本地包");
        List<File> entries = new ArrayList<>();
        try {
            String prefix = stage.getCanonicalPath() + File.separator;
            long size = 0;
            int count = 0;
            try (ZipInputStream in = new ZipInputStream(new ByteArrayInputStream(bytes))) {
                byte[] buffer = new byte[8192];
                for (ZipEntry entry; (entry = in.getNextEntry()) != null; ) {
                    String name = entry.getName().replace('\\', '/');
                    if (++count > 2048
                            || name.startsWith("/")
                            || name.contains(":")
                            || Arrays.asList(name.split("/")).contains(".."))
                        throw new IOException("本地包目录或文件数量无效");
                    File dest = new File(stage, name).getCanonicalFile();
                    if (!dest.getPath().startsWith(prefix)) throw new IOException("本地包路径无效");
                    if (entry.isDirectory()) continue;
                    File parent = dest.getParentFile();
                    if ((!parent.isDirectory() && !parent.mkdirs()) || !dest.createNewFile())
                        throw new IOException("本地包文件重复或路径无效");
                    try (OutputStream out = new FileOutputStream(dest)) {
                        for (int n; (n = in.read(buffer)) != -1; ) {
                            size += n;
                            if (size > 48L * 1024 * 1024) throw new IOException("本地包解压超过 48 MB");
                            out.write(buffer, 0, n);
                        }
                    }
                    entries.add(dest);
                }
            }
            File entry = chooseEntry(entries);
            String relative = stage.toURI().relativize(entry.toURI()).getPath();
            new LocalSourcePackage(stage, entry);
            if (!installed.isDirectory() && !stage.renameTo(installed))
                throw new IOException("无法保存本地包");
            return new LocalSourcePackage(installed, new File(installed, relative));
        } finally {
            discard(stage);
        }
    }

    private static void discard(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) discard(child);
        file.delete();
    }
}
