package com.pilipala.marcomovie;

import java.util.*;

/** Memory-only detail responses; no player() resolution results. Parse a fresh model on each use. */
final class DetailCache {
    interface Clock {
        long getAsLong();
    }

    static final long TTL_MS = 5 * 60 * 1000;
    static final int MAX_ENTRIES = 24, MAX_CHARS = 1024 * 1024;

    static final class Entry {
        final String raw;
        final long time;
        final int size;

        Entry(String r, long t, int bytes) {
            raw = r;
            time = t;
            size = bytes;
        }
    }

    final LinkedHashMap<String, Entry> entries = new LinkedHashMap<>(32, .75f, true);
    final Clock clock;
    int chars;

    DetailCache() {
        this(() -> System.nanoTime() / 1000000);
    }

    DetailCache(Clock time) {
        clock = time;
    }

    synchronized String get(String key) {
        Entry e = entries.get(key);
        if (e == null) return null;
        if (clock.getAsLong() - e.time >= TTL_MS) {
            entries.remove(key);
            chars -= e.size;
            return null;
        }
        return e.raw;
    }

    synchronized void put(String key, String raw) {
        if (raw == null || (long) raw.length() + key.length() > MAX_CHARS) return;
        int size = raw.length() + key.length();
        Entry previous = entries.put(key, new Entry(raw, clock.getAsLong(), size));
        if (previous != null) chars -= previous.size;
        chars += size;
        Iterator<Entry> i = entries.values().iterator();
        while (entries.size() > MAX_ENTRIES || chars > MAX_CHARS) {
            chars -= i.next().size;
            i.remove();
        }
    }

    synchronized void clear() {
        entries.clear();
        chars = 0;
    }
}
