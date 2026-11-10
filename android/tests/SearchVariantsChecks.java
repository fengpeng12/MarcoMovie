package com.pilipala.marcomovie;

import java.util.*;

public final class SearchVariantsChecks {
    static int checks;

    static void check(boolean value) {
        if (!value) throw new AssertionError("check " + checks);
        checks++;
    }

    static Cms.Video video(String id, String title) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.tag = "folder";
        return v;
    }

    public static void main(String[] args) throws Exception {
        int[] calls = {0};
        List<Cms.Video> found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("样本", "另一写法", "sample"),
                        t -> t.equals("样本"),
                        term -> {
                            calls[0]++;
                            if (calls[0] > 1)
                                throw new AssertionError(
                                        "useful result must not wait for another spelling");
                            return Arrays.asList(video("folder", "样本"));
                        });
        check(calls[0] == 1 && found.size() == 1 && found.get(0).tag.equals("folder"));
        calls[0] = 0;
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("无结果", "sample"),
                        t -> true,
                        term -> {
                            calls[0]++;
                            return calls[0] == 1
                                    ? Collections.emptyList()
                                    : Arrays.asList(
                                            video("a", "title"),
                                            video("a", "title"),
                                            video("", "title"));
                        });
        check(calls[0] == 2 && found.size() == 1);
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("错误", "sample"),
                        t -> true,
                        term -> {
                            if (term.equals("错误")) throw new java.io.IOException();
                            return Arrays.asList(video("a", "title"));
                        });
        check(found.size() == 1);
        boolean failed = false;
        try {
            SearchVariants.run(
                    "sample",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        throw new java.io.IOException();
                    });
        } catch (java.io.IOException expected) {
            failed = true;
        }
        check(failed);
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("样本", "sample"),
                        t -> t.equals("样本"),
                        term -> Arrays.asList(video("a", "unmatched"), video("a", "样本")));
        check(found.size() == 1 && found.get(0).title.equals("样本"));
        Thread.currentThread().interrupt();
        boolean cancelled = false;
        try {
            SearchVariants.run("x", Arrays.asList("x"), t -> true, term -> Collections.emptyList());
        } catch (InterruptedException expected) {
            cancelled = true;
        } finally {
            Thread.interrupted();
        }
        check(cancelled);
        calls[0] = 0;
        cancelled = false;
        try {
            SearchVariants.run(
                    "x",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        calls[0]++;
                        throw new InterruptedException();
                    });
        } catch (InterruptedException expected) {
            cancelled = Thread.currentThread().isInterrupted();
        } finally {
            Thread.interrupted();
        }
        check(cancelled && calls[0] == 1);
        calls[0] = 0;
        boolean verification = false;
        try {
            SearchVariants.run(
                    "x",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        calls[0]++;
                        throw new SearchCoordinator.VerificationRequiredException();
                    });
        } catch (SearchCoordinator.VerificationRequiredException expected) {
            verification = true;
        }
        check(verification && calls[0] == 1);
        System.out.println("OK " + checks + " search fallback checks");
    }
}
