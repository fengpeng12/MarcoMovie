package com.pilipala.catpaw;

/** One embedded Node engine for the application; subscriptions run in worker isolates. */
public final class NodeRuntime {
    /** The runtime cannot start on this installation; no subscription code has executed. */
    public static final class RuntimeUnavailableException extends java.io.IOException {
        RuntimeUnavailableException(String message) {
            super(message);
        }
    }

    private static boolean started, exited;
    private static String rootPath;

    private static native int run(String script, String root, String ready);

    public static synchronized void start(
            android.content.Context context,
            final String script,
            final String root,
            final String ready)
            throws java.io.IOException {
        if (exited || (started && !root.equals(rootPath)))
            throw new java.io.IOException("请重新打开应用以启动 CatPaw");
        if (started) return;
        long pageSize = android.system.Os.sysconf(android.system.OsConstants._SC_PAGESIZE);
        if (pageSize > 4096 && !verifiedPageSize(context, pageSize))
            throw new RuntimeUnavailableException("当前 CatPaw 运行组件尚不支持此设备的 16 KB 内存页，请使用其他片源");
        try {
            System.loadLibrary("node");
            System.loadLibrary("marco_node");
        } catch (UnsatisfiedLinkError error) {
            throw new RuntimeUnavailableException("安装包缺少兼容的 CatPaw 本机运行组件");
        }
        new java.io.File(ready).delete();
        rootPath = root;
        started = true;
        new Thread(
                        null,
                        new Runnable() {
                            public void run() {
                                try {
                                    NodeRuntime.run(script, root, ready);
                                } finally {
                                    synchronized (NodeRuntime.class) {
                                        exited = true;
                                    }
                                }
                            }
                        },
                        "catpaw-node",
                        8 * 1024 * 1024)
                .start();
    }

    /** Only the exact source-built libraries named by the APK's build evidence may opt in. */
    static boolean verifiedPageSize(android.content.Context context, long pageSize) {
        if (pageSize > 16384 || pageSize <= 0) return false;
        try {
            String text;
            try (java.io.InputStream input =
                    context.getAssets().open("catpaw/runtime-capabilities.json")) {
                java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                byte[] buffer = new byte[2048];
                for (int n; (n = input.read(buffer)) != -1; ) {
                    if (bytes.size() + n > 16384) return false;
                    bytes.write(buffer, 0, n);
                }
                text = new String(bytes.toByteArray(), "UTF-8");
            }
            org.json.JSONObject manifest = new org.json.JSONObject(text);
            if (manifest.optInt("version") != 1 || manifest.optInt("maxPageSize") != 16384)
                return false;
            org.json.JSONObject abis = manifest.getJSONObject("abis");
            android.content.pm.ApplicationInfo app = context.getApplicationInfo();
            String[] libraries = {"libnode.so", "libmarco_node.so", "libc++_shared.so"};
            for (String abi : android.os.Build.SUPPORTED_ABIS) {
                org.json.JSONObject hashes = abis.optJSONObject(abi);
                if (hashes == null) continue;
                boolean matches = true;
                for (String name : libraries) {
                    String expected = hashes.optString(name);
                    if (!expected.matches("[a-f0-9]{64}")) {
                        matches = false;
                        break;
                    }
                    java.io.File installed = new java.io.File(app.nativeLibraryDir, name);
                    String actual;
                    if (installed.isFile()) {
                        try (java.io.InputStream input = new java.io.FileInputStream(installed)) {
                            actual = digest(input);
                        }
                    } else {
                        try (java.util.zip.ZipFile apk = new java.util.zip.ZipFile(app.sourceDir)) {
                            java.util.zip.ZipEntry entry = apk.getEntry("lib/" + abi + "/" + name);
                            if (entry == null) {
                                matches = false;
                                break;
                            }
                            try (java.io.InputStream input = apk.getInputStream(entry)) {
                                actual = digest(input);
                            }
                        }
                    }
                    if (!expected.equals(actual)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return true;
            }
        } catch (Exception ignored) {
            // Older builds have no capability evidence and keep the explicit compatibility guard.
        }
        return false;
    }

    private static String digest(java.io.InputStream input) throws Exception {
        java.security.MessageDigest hash = java.security.MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[65536];
        for (int n; (n = input.read(buffer)) != -1; ) hash.update(buffer, 0, n);
        StringBuilder result = new StringBuilder();
        for (byte value : hash.digest())
            result.append(String.format(java.util.Locale.US, "%02x", value & 255));
        return result.toString();
    }
}
