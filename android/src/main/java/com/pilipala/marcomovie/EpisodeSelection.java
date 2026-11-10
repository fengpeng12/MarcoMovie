package com.pilipala.marcomovie;

/** Browse position is independent of the last episode actually played. */
final class EpisodeSelection {
    String line = "";
    int page;
    boolean selected;

    void select(String name, int group, int count) {
        line = name;
        page = boundPage(group, count);
        selected = true;
    }

    static int boundPage(int page, int count) {
        return Math.max(0, Math.min(page, Math.max(0, (count - 1) / 50)));
    }

    static int pageFor(int originalIndex, int count, boolean descending) {
        int index = Math.max(0, Math.min(originalIndex, Math.max(0, count - 1)));
        return (descending ? Math.max(0, count - 1 - index) : index) / 50;
    }
}
