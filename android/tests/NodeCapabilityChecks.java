package com.pilipala.catpaw;

import android.content.Context;
import java.io.*;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;
import org.json.*;

/** Checks the opt-in policy only; synthetic library bytes are never loaded. */
public final class NodeCapabilityChecks {
    static int checks;

    static void check(boolean pass, String name) {
        if (!pass) throw new AssertionError(name);
        checks++;
    }

    static String hash(byte[] data) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(data))
            result.append(String.format(Locale.US, "%02x", value & 255));
        return result.toString();
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        new File(root, "catpaw").mkdirs();
        new File(root, "lib").mkdirs();
        Context context = new Context(root);
        File capability = new File(root, "catpaw/runtime-capabilities.json");
        check(!NodeRuntime.verifiedPageSize(context, 16384), "missing evidence retains block");
        try {
            NodeRuntime.start(context, "unused", "unused", "unused");
            throw new AssertionError("unverified runtime started");
        } catch (NodeRuntime.RuntimeUnavailableException expected) {
            check(true, "pre-start capability failure has an explicit fallback type");
        }
        JSONObject hashes = new JSONObject();
        Map<String, byte[]> libraries = new LinkedHashMap<>();
        for (String name : new String[] {"libnode.so", "libmarco_node.so", "libc++_shared.so"}) {
            byte[] data = ("synthetic policy fixture " + name).getBytes("UTF-8");
            libraries.put(name, data);
            hashes.put(name, hash(data));
            Files.write(new File(root, "lib/" + name).toPath(), data);
        }
        JSONObject manifest =
                new JSONObject()
                        .put("version", 1)
                        .put("maxPageSize", 16384)
                        .put("abis", new JSONObject().put("x86_64", hashes));
        Files.write(capability.toPath(), manifest.toString().getBytes("UTF-8"));
        check(NodeRuntime.verifiedPageSize(context, 16384), "all three installed hashes match");
        check(
                !NodeRuntime.verifiedPageSize(context, 65536)
                        && !NodeRuntime.verifiedPageSize(context, 0),
                "page sizes outside evidence rejected");
        Files.write(new File(root, "lib/libnode.so").toPath(), "changed".getBytes("UTF-8"));
        check(!NodeRuntime.verifiedPageSize(context, 16384), "installed library mismatch blocked");
        Files.write(new File(root, "lib/libnode.so").toPath(), libraries.get("libnode.so"));
        String expected = hashes.getString("libmarco_node.so");
        hashes.remove("libmarco_node.so");
        Files.write(capability.toPath(), manifest.toString().getBytes("UTF-8"));
        check(!NodeRuntime.verifiedPageSize(context, 16384), "missing bridge hash blocked");
        hashes.put("libmarco_node.so", expected);
        for (String key : new String[] {"version", "maxPageSize"}) {
            JSONObject wrong = new JSONObject(manifest.toString()).put(key, 2);
            Files.write(capability.toPath(), wrong.toString().getBytes("UTF-8"));
            check(!NodeRuntime.verifiedPageSize(context, 16384), "unsupported " + key);
        }
        Files.write(capability.toPath(), manifest.toString().getBytes("UTF-8"));
        try (ZipOutputStream zip =
                new ZipOutputStream(new FileOutputStream(new File(root, "app.apk")))) {
            for (Map.Entry<String, byte[]> entry : libraries.entrySet()) {
                zip.putNextEntry(new ZipEntry("lib/x86_64/" + entry.getKey()));
                zip.write(entry.getValue());
                zip.closeEntry();
                Files.delete(new File(root, "lib/" + entry.getKey()).toPath());
            }
        }
        check(NodeRuntime.verifiedPageSize(context, 16384), "direct APK library hashes accepted");
        android.os.Build.SUPPORTED_ABIS = new String[] {"arm64-v8a"};
        check(!NodeRuntime.verifiedPageSize(context, 16384), "other ABI evidence rejected");
        Files.write(capability.toPath(), new byte[16385]);
        check(!NodeRuntime.verifiedPageSize(context, 16384), "oversized evidence blocked");
        System.out.println(
                "Node capability policy: " + checks + " checks passed; no native execution claim");
    }
}
