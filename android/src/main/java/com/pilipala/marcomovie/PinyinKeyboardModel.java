package com.pilipala.marcomovie;

import java.io.*;
import java.util.*;

/** Local, character-based pinyin input; no OS input method or online candidate service. */
public final class PinyinKeyboardModel {
    public enum Mode {
        PINYIN,
        LETTERS,
        NUMBERS
    }

    public static final class Candidate {
        public final String text, syllable;

        Candidate(String text, String syllable) {
            this.text = text;
            this.syllable = syllable;
        }
    }

    final Map<String, String> dictionary = new HashMap<>();
    String committed = "", composition = "";
    Mode mode = Mode.PINYIN;

    public PinyinKeyboardModel(InputStream in) throws IOException {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith("#")) continue;
                int at = line.indexOf('\t');
                if (at > 0) dictionary.put(line.substring(0, at), line.substring(at + 1));
            }
        }
    }

    public Mode mode() {
        return mode;
    }

    public void mode(Mode next) {
        if (!composition.isEmpty()) {
            committed += composition;
            composition = "";
        }
        mode = next;
    }

    public String committed() {
        return committed;
    }

    public String composition() {
        return composition;
    }

    public String query() {
        return (committed + composition).trim();
    }

    public void set(String value) {
        committed = value == null ? "" : value;
        composition = "";
    }

    public void clear() {
        committed = "";
        composition = "";
    }

    public void input(String value) {
        if (query().length() + value.length() > 80) return;
        if (mode == Mode.PINYIN && value.matches("[a-z]+")) composition += value;
        else {
            if (!composition.isEmpty()) {
                committed += composition;
                composition = "";
            }
            committed += value;
        }
    }

    public void backspace() {
        if (!composition.isEmpty())
            composition = composition.substring(0, composition.length() - 1);
        else if (!committed.isEmpty())
            committed =
                    committed.substring(0, committed.offsetByCodePoints(committed.length(), -1));
    }

    public List<Candidate> candidates() {
        List<Candidate> out = new ArrayList<>();
        if (composition.isEmpty() || mode != Mode.PINYIN) return out;
        String key = composition;
        while (!key.isEmpty() && !dictionary.containsKey(key))
            key = key.substring(0, key.length() - 1);
        if (key.isEmpty()) return out;
        String chars = dictionary.get(key);
        for (int at = 0; at < chars.length(); ) {
            int cp = chars.codePointAt(at);
            out.add(new Candidate(new String(Character.toChars(cp)), key));
            at += Character.charCount(cp);
        }
        return out;
    }

    public void select(Candidate candidate) {
        if (candidate != null && composition.startsWith(candidate.syllable)) {
            committed += candidate.text;
            composition = composition.substring(candidate.syllable.length());
        }
    }

    public void space() {
        List<Candidate> candidates = candidates();
        if (!candidates.isEmpty()) select(candidates.get(0));
        else input(" ");
    }
}
