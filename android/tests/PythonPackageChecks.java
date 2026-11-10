package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.zip.*;
import org.json.*;

/** Real ZIP importer -> scoped raw package snapshot. No Android VM or third-party source. */
public final class PythonPackageChecks {
    private static int checks;

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        checks++;
    }

    private static byte[] zip(Map<String, byte[]> files) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(output)) {
            for (Map.Entry<String, byte[]> entry : files.entrySet()) {
                zip.putNextEntry(new ZipEntry(entry.getKey()));
                zip.write(entry.getValue());
                zip.closeEntry();
            }
        }
        return output.toByteArray();
    }

    private static Map<String, byte[]> minimal() {
        Map<String, byte[]> files = new LinkedHashMap<>();
        files.put(
                "bundle/main.py",
                "class Spider:\n def homeContent(self, filter): return {}\n"
                        .getBytes(StandardCharsets.UTF_8));
        return files;
    }

    private static void rejected(File filesDir, Map<String, byte[]> files, String name)
            throws Exception {
        try {
            LocalSourcePackage.open(filesDir, zip(files));
            throw new AssertionError(name + " accepted");
        } catch (IOException expected) {
            checks++;
        }
    }

    public static void main(String[] args) throws Exception {
        File filesDir = new File(args[0]);
        JSONObject fixture =
                new JSONObject(
                        new String(
                                Files.readAllBytes(new File(args[1]).toPath()),
                                StandardCharsets.UTF_8));
        JSONObject encoded = fixture.getJSONObject("packageData").getJSONObject("files");
        Map<String, byte[]> resources = new LinkedHashMap<>();
        for (Iterator<String> keys = encoded.keys(); keys.hasNext(); ) {
            String key = keys.next();
            resources.put(key, Base64.getDecoder().decode(encoded.getString(key)));
        }
        LocalSourcePackage imported = LocalSourcePackage.open(filesDir, zip(resources));
        Cms.Site reopened = Cms.parseConfig(imported.config.raw, imported.origin).sites.get(0);
        LocalSourcePackage.PythonPackage first =
                LocalSourcePackage.pythonPackage(filesDir, reopened.api);
        check(
                first != null && first.entry.equals("bundle/main.py"),
                "entry remains relative to package root");
        check(
                first.source.equals(
                        new String(resources.get("bundle/main.py"), StandardCharsets.UTF_8)),
                "entry source matches original bytes");
        check(first.files.size() == resources.size(), "all data files included");
        for (Map.Entry<String, byte[]> file : resources.entrySet())
            check(
                    Arrays.equals(file.getValue(), first.files.get(file.getKey())),
                    "raw bytes " + file.getKey());
        check(
                first.modules.containsKey("helper.py")
                        && first.modules.containsKey("tools/reader.py"),
                "modules relative to entry directory");
        check(!first.modules.containsKey("data/metadata.json"), "data is not executable module");
        JSONObject output =
                new JSONObject()
                        .put("source", first.source)
                        .put("modules", new JSONObject(first.modules));
        JSONObject data = new JSONObject();
        for (Map.Entry<String, byte[]> file : first.files.entrySet())
            data.put(file.getKey(), Base64.getEncoder().encodeToString(file.getValue()));
        output.put("packageData", new JSONObject().put("entry", first.entry).put("files", data));
        Files.write(new File(args[2]).toPath(), output.toString().getBytes(StandardCharsets.UTF_8));

        resources.put("bundle/data/payload.bin", new byte[] {0, (byte) 255, (byte) 128, 65});
        LocalSourcePackage other = LocalSourcePackage.open(filesDir, zip(resources));
        LocalSourcePackage.PythonPackage second =
                LocalSourcePackage.pythonPackage(filesDir, other.config.sites.get(0).api);
        check(
                !imported.origin.equals(other.origin),
                "different content gives different package root");
        check(
                Arrays.equals(
                        second.files.get("bundle/data/payload.bin"),
                        new byte[] {0, (byte) 255, (byte) 128, 65}),
                "exact binary bytes");
        check(
                Arrays.equals(
                        first.files.get("bundle/data/payload.bin"),
                        new byte[] {0, (byte) 255, 10, (byte) 128, 65, 10, 66}),
                "first source snapshot is isolated");
        resources.put(
                "config.json",
                "{\"sites\":[{\"key\":\"configured\",\"type\":3,\"api\":\"./bundle/main.py\",\"ext\":{\"user\":true}}]}"
                        .getBytes(StandardCharsets.UTF_8));
        LocalSourcePackage configured = LocalSourcePackage.open(filesDir, zip(resources));
        Cms.Site configuredSite =
                Cms.parseConfig(configured.config.raw, configured.origin).sites.get(0);
        check(
                LocalSourcePackage.pythonPackage(filesDir, configuredSite.api)
                        .entry
                        .equals("bundle/main.py"),
                "configured package reopens");
        check(((JSONObject) configuredSite.ext).getBoolean("user"), "source ext is preserved");
        check(
                LocalSourcePackage.pythonPackage(filesDir, "https://example.invalid/main.py")
                        == null,
                "remote sources do not inherit package data");
        File loose = new File(filesDir, "local_spiders/main.py");
        loose.getParentFile().mkdirs();
        Files.write(loose.toPath(), "standalone".getBytes(StandardCharsets.UTF_8));
        check(
                LocalSourcePackage.pythonPackage(filesDir, Cms.fileUri(loose)) == null,
                "standalone imports do not enumerate neighbouring sources");
        File invalidId = new File(filesDir, "source-packages/not-a-hash/main.py");
        invalidId.getParentFile().mkdirs();
        Files.write(invalidId.toPath(), "standalone".getBytes(StandardCharsets.UTF_8));
        try {
            LocalSourcePackage.pythonPackage(filesDir, Cms.fileUri(invalidId));
            throw new AssertionError("invalid package identity accepted");
        } catch (IOException expected) {
            checks++;
        }

        Map<String, byte[]> invalid = minimal();
        invalid.put("bundle/large.bin", new byte[2 * 1024 * 1024 + 1]);
        rejected(filesDir, invalid, "single file limit");
        invalid = minimal();
        for (int i = 0; i < 3; i++) invalid.put("bundle/data" + i, new byte[2 * 1024 * 1024]);
        rejected(filesDir, invalid, "decoded aggregate limit");
        invalid = minimal();
        for (int i = 0; i < 256; i++) invalid.put("bundle/data" + i, new byte[0]);
        rejected(filesDir, invalid, "file count");
        for (String name :
                new String[] {"bundle/a'b", "bundle/a\"b", "bundle/a\nb\nc", "../outside"}) {
            invalid = minimal();
            invalid.put(name, new byte[0]);
            rejected(filesDir, invalid, "invalid resource path");
        }
        invalid = minimal();
        invalid.put("bundle/helper.py", new byte[] {(byte) 255});
        rejected(filesDir, invalid, "malformed UTF-8 helper");
        invalid = minimal();
        invalid.put("bundle/main.py", new byte[] {(byte) 255});
        rejected(filesDir, invalid, "malformed UTF-8 entry");
        Thread.currentThread().interrupt();
        try {
            LocalSourcePackage.pythonPackage(filesDir, reopened.api);
            throw new AssertionError("interrupted package read accepted");
        } catch (InterruptedIOException expected) {
            checks++;
        } finally {
            Thread.interrupted();
        }
        check(
                LocalSourcePackage.pythonPackage(filesDir, reopened.api).files.size()
                        == first.files.size(),
                "invalid imports do not damage existing package");
        System.out.println("Python package importer: " + checks + " checks passed");
    }
}
