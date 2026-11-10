package com.pilipala.marcomovie;

import java.util.*;

/** Stable catalogue order for cross-group channel stepping and numeric tuning. */
final class LiveSession {
    final LiveCatalog.Source source;
    final List<LiveCatalog.Channel> channels = new ArrayList<>();
    int index = -1;
    String digits = "";

    LiveSession(LiveCatalog.Source selected, LiveCatalog.Catalog catalog) {
        source = selected;
        for (LiveCatalog.Group group : catalog.groups)
            for (LiveCatalog.Channel channel : group.channels)
                if (!channel.streams.isEmpty()) channels.add(channel);
    }

    int step(int direction) {
        if (channels.isEmpty()) return -1;
        if (index < 0) return direction < 0 ? channels.size() - 1 : 0;
        int n = channels.size();
        return ((index + direction) % n + n) % n;
    }

    boolean digit(int digit) {
        if (digit < 0 || digit > 9) return false;
        int max = Integer.toString(Math.max(1, channels.size())).length();
        if (digits.length() >= max) digits = "";
        digits += digit;
        return true;
    }

    int selectedNumber() {
        try {
            int n = Integer.parseInt(digits);
            return n > 0 && n <= channels.size() ? n - 1 : -1;
        } catch (Exception ignored) {
            return -1;
        }
    }

    void clear() {
        digits = "";
    }
}
