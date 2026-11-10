package com.pilipala.marcomovie;

import org.json.*;

public final class FavoritesChecks {
    static int checks;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        checks++;
    }

    public static void main(String[] args) throws Exception {
        Cms.Video video = new Cms.Video();
        video.id = "one";
        video.title = "Test";
        video.poster = "https://image.test/poster.jpg";
        String data = Favorites.toggle("[]", "alpha", video);
        check(Favorites.contains(data, "alpha", "one"), "Saved favorite survives JSON read");
        data = Favorites.toggle(data, "beta", video);
        check(Favorites.read(data).size() == 2, "Same ID in different sources remains distinct");
        data = Favorites.toggle(data, "alpha", video);
        check(
                !Favorites.contains(data, "alpha", "one")
                        && Favorites.contains(data, "beta", "one"),
                "Remove only selected source title");
        check(
                new JSONArray(data).getJSONObject(0).length() == 4,
                "Persist only source, title, ID and poster; no playback URL");
        check(Favorites.read("broken").isEmpty(), "Malformed storage recovers");
        check(Favorites.read("[{},null]").isEmpty(), "Invalid entries ignored");
        for (int i = 0; i < 305; i++) {
            video.id = "id" + i;
            data = Favorites.toggle(data, "alpha", video);
        }
        check(Favorites.read(data).size() == 300, "Bounded collection");
        check(Favorites.read(data).get(0).id.equals("id304"), "Newest favorite first");
        System.out.println("PASS " + checks + " favorite persistence checks");
    }
}
