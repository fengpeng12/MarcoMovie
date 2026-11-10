package com.pilipala.marcomovie;

import java.io.*;
import java.util.*;

/** Local phonetic matching over real learned titles plus a licensed phrase dictionary. */
public final class PhoneticSearchIndex {
    static final class Entry {
        String text, full, initials;
        int weight;

        Entry(String t, String p, int w) {
            text = t;
            full = p.replace(" ", "");
            StringBuilder initials = new StringBuilder();
            for (String s : p.split(" ")) if (!s.isEmpty()) initials.append(s.charAt(0));
            this.initials = initials.toString();
            weight = w;
        }
    }

    static final class Path {
        String text;
        double score;

        Path(String t, double s) {
            text = t;
            score = s;
        }
    }

    final Map<Integer, List<String>> readings = new HashMap<>();
    final Map<Character, List<Entry>> words = new HashMap<>();
    final List<Entry> entries = new ArrayList<>();
    final LinkedHashMap<String, List<Entry>> titles = new LinkedHashMap<>();
    final List<String> preferred = new ArrayList<>();

    public PhoneticSearchIndex(InputStream characters, InputStream phrases) throws IOException {
        this(characters, phrases, null);
    }

    public PhoneticSearchIndex(
            InputStream characters, InputStream phrases, InputStream titlePhrases)
            throws IOException {
        try (BufferedReader reader =
                new BufferedReader(new InputStreamReader(characters, "UTF-8"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                int split = line.indexOf('\t');
                if (split < 0 || line.startsWith("#")) continue;
                String py = line.substring(0, split), chars = line.substring(split + 1);
                for (int i = 0; i < chars.length(); ) {
                    int cp = chars.codePointAt(i);
                    List<String> p = readings.get(cp);
                    if (p == null) {
                        p = new ArrayList<>();
                        readings.put(cp, p);
                    }
                    if (!p.contains(py)) p.add(py);
                    i += Character.charCount(cp);
                }
            }
        }
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(phrases, "UTF-8"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith("#")) continue;
                String[] parts = line.split("\t");
                if (parts.length < 3) continue;
                try {
                    Entry e = new Entry(parts[0], parts[1], Integer.parseInt(parts[2]));
                    if (e.full.isEmpty() || e.text.length() > 12) continue;
                    if (e.text.codePointCount(0, e.text.length()) == 1) {
                        int firstCp = e.text.codePointAt(0);
                        List<String> p = readings.get(firstCp);
                        if (p == null) {
                            p = new ArrayList<>();
                            readings.put(firstCp, p);
                        }
                        if (!p.contains(e.full)) p.add(e.full);
                    }
                    entries.add(e);
                    char firstChar = e.full.charAt(0);
                    List<Entry> wList = words.get(firstChar);
                    if (wList == null) {
                        wList = new ArrayList<>();
                        words.put(firstChar, wList);
                    }
                    wList.add(e);
                } catch (NumberFormatException ignored) {
                }
            }
        }
        Collections.sort(entries, (a, b) -> Integer.compare(b.weight, a.weight));
        if (titlePhrases != null)
            try (BufferedReader reader =
                    new BufferedReader(new InputStreamReader(titlePhrases, "UTF-8"))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    line = line.trim();
                    if (!line.isEmpty() && !line.startsWith("#")) learn(line);
                }
            }
    }

    public synchronized void learn(String title) {
        if (title == null
                || title.trim().isEmpty()
                || title.length() > 100
                || titles.containsKey(title)) return;
        List<String> variants = new ArrayList<>();
        variants.add("");
        String text = title.replaceAll("[\\s\\p{Punct}，。！？·《》【】（）]", "").toLowerCase(Locale.ROOT);
        for (int at = 0; at < text.length(); ) {
            int cp = text.codePointAt(at);
            at += Character.charCount(cp);
            List<String> syllables = readings.get(cp);
            if (syllables == null)
                syllables = Collections.singletonList(new String(Character.toChars(cp)));
            List<String> next = new ArrayList<>();
            for (String before : variants) {
                for (String py : syllables) {
                    next.add(before.isEmpty() ? py : before + " " + py);
                    if (next.size() >= 48) break;
                }
                if (next.size() >= 48) break;
            }
            variants = next;
        }
        List<Entry> values = new ArrayList<>();
        for (String variant : variants) values.add(new Entry(title, variant, 1000000));
        titles.put(title, values);
        while (titles.size() > 2000) titles.remove(titles.keySet().iterator().next());
    }

    public synchronized boolean matches(String title, String query) {
        String q = normalize(query);
        if (title.toLowerCase(Locale.ROOT).contains(q)) return true;
        learn(title);
        List<Entry> titleEntries = titles.get(title);
        if (titleEntries != null)
            for (Entry e : titleEntries)
                if (e.full.contains(q) || e.initials.contains(q)) return true;
        return false;
    }

    public synchronized void prefer(String title) {
        if (title == null || !title.matches(".*[\\u3400-\\u9fff].*")) return;
        learn(title);
        preferred.remove(title);
        preferred.add(0, title);
        while (preferred.size() > 20) preferred.remove(preferred.size() - 1);
    }

    public synchronized List<String> expand(String query) {
        String q = normalize(query);
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (!q.matches("[a-zv0-9]+") || q.length() < 2) {
            out.add(query.trim());
            return new ArrayList<>(out);
        }
        Map<String, Integer> ranks = new HashMap<>();
        for (List<Entry> values : titles.values())
            for (Entry e : values)
                if (e.full.startsWith(q) || e.initials.startsWith(q)) {
                    int rank =
                            (e.full.equals(q)
                                            ? 12000
                                            : e.initials.equals(q)
                                                    ? 11000
                                                    : e.full.startsWith(q) ? 1000 : 500)
                                    - e.text.length();
                    int recent = preferred.indexOf(e.text);
                    if (recent >= 0) rank += 1000 - recent;
                    Integer prevRank = ranks.get(e.text);
                    ranks.put(
                            e.text,
                            Math.max(rank, prevRank != null ? prevRank : Integer.MIN_VALUE));
                }
        List<String> ranked = new ArrayList<>(ranks.keySet());
        Collections.sort(
                ranked,
                (a, b) -> {
                    int rank = Integer.compare(ranks.get(b), ranks.get(a));
                    return rank != 0 ? rank : a.compareTo(b);
                });
        for (String title : ranked) {
            out.add(title);
            if (out.size() >= 4) break;
        }
        if (out.isEmpty()) {
            List<Path> decoded = decode(q);
            for (Path path : decoded) {
                out.add(path.text);
                if (out.size() >= 2) break;
            }
            if (out.isEmpty() && q.length() >= 2)
                for (Entry e : entries)
                    if (e.text.length() > 1 && e.initials.equals(q)) {
                        out.add(e.text);
                        if (out.size() >= 2) break;
                    }
        }
        out.add(query.trim());
        return new ArrayList<>(out);
    }

    /** Bound expanded requests while always preserving literal English/number/acronym searches. */
    public synchronized List<String> searchTerms(String query) {
        String literal = query.trim();
        List<String> variants = expand(literal);
        LinkedHashSet<String> terms = new LinkedHashSet<>();
        for (String candidate : variants)
            if (!candidate.equalsIgnoreCase(literal)) {
                terms.add(candidate);
                if (terms.size() == 2) break;
            }
        terms.add(literal);
        return new ArrayList<>(terms);
    }

    List<Path> decode(String query) {
        List<List<Path>> best = new ArrayList<>();
        for (int i = 0; i <= query.length(); i++) best.add(new ArrayList<>());
        best.get(0).add(new Path("", 0));
        for (int start = 0; start < query.length(); start++) {
            if (best.get(start).isEmpty()) continue;
            List<Entry> bucket = words.get(query.charAt(start));
            if (bucket == null) continue;
            for (Entry e : bucket) {
                if (!query.startsWith(e.full, start)) continue;
                int end = start + e.full.length();
                List<Path> target = best.get(end);
                for (Path previous : new ArrayList<>(best.get(start)))
                    target.add(
                            new Path(
                                    previous.text + e.text,
                                    previous.score
                                            + Math.log(Math.max(1, e.weight))
                                            - (e.text.length() == 1 ? 12 : 0)));
                Collections.sort(target, (a, b) -> Double.compare(b.score, a.score));
                while (target.size() > 3) target.remove(target.size() - 1);
            }
        }
        return best.get(query.length());
    }

    static String normalize(String query) {
        return query.toLowerCase(Locale.ROOT).replace("ü", "v").replaceAll("[\\s'’-]", "");
    }
}
