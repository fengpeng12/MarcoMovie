package com.pilipala.marcomovie;

import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * Bounded in-memory diagnostic ring buffer that works both on Android (forwarding to logcat) and in
 * offline JVM tests without requiring the Android framework jar at runtime.
 */
final class AppLog {
    static final int CAPACITY = 200;
    private static final ArrayDeque<String> ENTRIES = new ArrayDeque<>(CAPACITY);
    private static final Method ANDROID_INFO;
    private static final Method ANDROID_WARN;

    static {
        Method info = null, warn = null;
        try {
            Class<?> log = Class.forName("android.util.Log");
            info = log.getMethod("i", String.class, String.class);
            warn = log.getMethod("w", String.class, String.class, Throwable.class);
        } catch (Throwable ignored) {
        }
        ANDROID_INFO = info;
        ANDROID_WARN = warn;
    }

    private AppLog() {}

    static void i(String tag, String message) {
        record("I", tag, message, null);
        if (ANDROID_INFO != null) {
            try {
                ANDROID_INFO.invoke(null, safeTag(tag), message == null ? "" : message);
            } catch (Throwable ignored) {
            }
        }
    }

    static void w(String tag, String message, Throwable error) {
        record("W", tag, message, error);
        if (ANDROID_WARN != null) {
            try {
                ANDROID_WARN.invoke(null, safeTag(tag), message == null ? "" : message, error);
            } catch (Throwable ignored) {
            }
        }
    }

    private static String safeTag(String tag) {
        return tag == null || tag.isEmpty() ? "MarcoMovie" : tag;
    }

    private static void record(String level, String tag, String message, Throwable error) {
        StringBuilder line = new StringBuilder(96);
        line.append(System.currentTimeMillis())
                .append(' ')
                .append(level)
                .append('/')
                .append(safeTag(tag))
                .append(": ")
                .append(message == null ? "" : message);
        if (error != null) {
            line.append(" (").append(error.getClass().getSimpleName());
            String detail = error.getMessage();
            if (detail != null && !detail.isEmpty()) line.append(": ").append(detail);
            line.append(')');
        }
        synchronized (ENTRIES) {
            while (ENTRIES.size() >= CAPACITY) ENTRIES.pollFirst();
            ENTRIES.addLast(line.toString());
        }
    }

    static List<String> entries() {
        synchronized (ENTRIES) {
            return new ArrayList<>(ENTRIES);
        }
    }

    static String dump() {
        List<String> snapshot = entries();
        StringBuilder out = new StringBuilder(snapshot.size() * 64);
        for (int i = 0; i < snapshot.size(); i++) {
            if (i > 0) out.append('\n');
            out.append(snapshot.get(i));
        }
        return out.toString();
    }

    static void clear() {
        synchronized (ENTRIES) {
            ENTRIES.clear();
        }
    }
}
