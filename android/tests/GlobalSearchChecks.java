package com.pilipala.marcomovie;

import java.util.concurrent.atomic.AtomicReference;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class GlobalSearchChecks {
    static int checks;

    static void check(boolean pass, String label) {
        if (!pass) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static Cms.Site site(String key) {
        Cms.Site site = new Cms.Site();
        site.key = key;
        site.name = key;
        return site;
    }

    static Cms.Video video(String id) {
        Cms.Video video = new Cms.Video();
        video.id = id;
        video.title = id;
        return video;
    }

    public static void main(String[] args) throws Exception {
        Cms.Video redirect = video("msearch:36809913");
        redirect.title = "折月亮";
        check(
                Cms.searchTitle(redirect).equals("折月亮"),
                "catalogue id redirects search by movie title");
        redirect.id = "msearch:36809913###折月亮###https://fixture.invalid/poster.jpg";
        check(Cms.searchTitle(redirect).equals("折月亮"), "cross-search id metadata is skipped");
        redirect.id = "msearch:###三体###https://fixture.invalid/poster.jpg";
        check(
                Cms.searchTitle(redirect).equals("三体"),
                "explicit cross-search title remains preferred");
        redirect.id = "msearch:1917";
        redirect.title = "1917";
        check(Cms.searchTitle(redirect).equals("1917"), "numeric movie titles remain valid");
        redirect.id = "msearch:36809913";
        redirect.title = null;
        check(
                Cms.searchTitle(redirect).isEmpty(),
                "missing movie name does not expose metadata id as query");
        PinyinKeyboardModel model =
                new PinyinKeyboardModel(
                        Files.newInputStream(
                                Paths.get(
                                        args[0],
                                        "android/src/main/assets/search/pinyin-characters.tsv")));
        check(model.dictionary.size() > 400, "complete local syllable dictionary loaded");
        model.input("san");
        check(
                model.candidates().get(0).text.equals("三"),
                "frequency-ordered simplified Chinese candidate");
        model.select(model.candidates().get(0));
        model.input("ti");
        PinyinKeyboardModel.Candidate body = null;
        for (PinyinKeyboardModel.Candidate c : model.candidates())
            if (c.text.equals("体")) {
                body = c;
                break;
            }
        model.select(body);
        check(
                model.query().equals("三体"),
                "remote pinyin selection composes a real Chinese film title");
        model.clear();
        model.input("santi");
        model.select(model.candidates().get(0));
        check(
                model.committed().equals("三") && model.composition().equals("ti"),
                "continuous pinyin preserves remaining syllable after selection");
        model.select(model.candidates().get(0));
        check(
                model.query().equals("三体"),
                "continuous pinyin can be committed one syllable at a time");
        model.input("a");
        model.backspace();
        check(model.query().equals("三体"), "delete removes composition before committed text");
        model.backspace();
        check(model.query().equals("三"), "delete removes committed Han character");
        model.set("A\ud83d\ude00");
        model.backspace();
        check(model.query().equals("A"), "delete does not split a surrogate pair");
        model.clear();
        model.mode(PinyinKeyboardModel.Mode.LETTERS);
        model.input("st");
        check(
                model.query().equals("st") && model.candidates().isEmpty(),
                "initial-letter query does not require a Chinese candidate");
        model.mode(PinyinKeyboardModel.Mode.NUMBERS);
        model.input("2026");
        check(model.query().equals("st2026"), "number mode appends directly");
        model.clear();
        model.mode(PinyinKeyboardModel.Mode.PINYIN);
        model.input("lv");
        check(
                model.candidates().stream().anyMatch(c -> c.text.equals("旅")),
                "v-input supports umlaut-u syllables");
        model.space();
        check(
                model.composition().isEmpty() && !model.committed().isEmpty(),
                "space commits the first pinyin candidate");
        model.mode(PinyinKeyboardModel.Mode.LETTERS);
        model.input("x");
        model.space();
        model.input("y");
        check(model.query().endsWith("x y"), "space works in literal mode");
        model.set(new String(new char[80]).replace('\0', 'a'));
        model.input("b");
        check(model.query().length() == 80, "bounded query length");
        CountDownLatch complete = new CountDownLatch(5);
        Map<String, SearchCoordinator.Outcome> outcomes = new ConcurrentHashMap<>();
        AtomicInteger validCount = new AtomicInteger();
        SearchCoordinator coordinator =
                new SearchCoordinator(
                        (site, query) -> {
                            if (site.key.equals("broken")) throw new IOException("fixture");
                            if (site.key.equals("verification"))
                                throw new SearchCoordinator.VerificationRequiredException();
                            if (site.key.equals("slow")) {
                                Thread.sleep(500);
                                return Collections.emptyList();
                            }
                            if (site.key.equals("empty")) return Collections.emptyList();
                            return Arrays.asList(
                                    video("msearch:fixture"), video("42"), video("42"), video(""));
                        },
                        (site, videos, outcome) -> {
                            outcomes.put(site.key, outcome);
                            validCount.addAndGet(videos.size());
                            complete.countDown();
                        },
                        60,
                        500);
        coordinator.start(
                Arrays.asList(
                        site("good"),
                        site("empty"),
                        site("broken"),
                        site("slow"),
                        site("verification")),
                "三体");
        check(
                complete.await(2, TimeUnit.SECONDS),
                "all source outcomes finish despite one slow source");
        check(
                outcomes.get("good") == SearchCoordinator.Outcome.RESULT && validCount.get() == 1,
                "deduplicates playable results and skips cross-search placeholders");
        check(
                outcomes.get("empty") == SearchCoordinator.Outcome.EMPTY,
                "empty source remains distinct from failure");
        check(
                outcomes.get("broken") == SearchCoordinator.Outcome.FAILED,
                "source failure remains distinct from empty");
        check(
                outcomes.get("slow") == SearchCoordinator.Outcome.TIMEOUT,
                "per-source deadline delivers one timeout");
        check(
                outcomes.get("verification") == SearchCoordinator.Outcome.VERIFICATION_REQUIRED,
                "website verification is distinct from empty and generic failure");
        coordinator.close();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger calls = new AtomicInteger();
        SearchCoordinator cancelled =
                new SearchCoordinator(
                        (site, query) -> {
                            entered.countDown();
                            while (release.getCount() > 0)
                                try {
                                    release.await();
                                } catch (InterruptedException ignored) {
                                }
                            return Collections.singletonList(video("late"));
                        },
                        (site, videos, outcome) -> calls.incrementAndGet(),
                        1000,
                        2000);
        cancelled.start(Collections.singletonList(site("uncancellable")), "old");
        check(entered.await(1, TimeUnit.SECONDS), "cancellation fixture is running");
        cancelled.close();
        release.countDown();
        Thread.sleep(100);
        check(calls.get() == 0, "cancelled native work cannot deliver a stale result");
        List<Cms.Site> many = new ArrayList<>();
        for (int i = 0; i < 100; i++) many.add(site("many-" + i));
        CountDownLatch all = new CountDownLatch(100);
        AtomicInteger missed = new AtomicInteger();
        SearchCoordinator large =
                new SearchCoordinator(
                        (source, q) -> Collections.singletonList(video(source.key)),
                        (source, videos, outcome) -> {
                            if (outcome != SearchCoordinator.Outcome.RESULT)
                                missed.incrementAndGet();
                            all.countDown();
                        },
                        1000,
                        5000);
        large.start(many, "query");
        check(
                all.await(5, TimeUnit.SECONDS) && missed.get() == 0,
                "100 sources are scheduled without queue-overflow omissions");
        large.close();

        // R01 regression: 6 uninterruptible jobs time out and hold their threads;
        // subsequent healthy queries must still run while wedged sites are isolated.
        CountDownLatch sixEntered = new CountDownLatch(6);
        CountDownLatch sixTimedOut = new CountDownLatch(6);
        CountDownLatch releaseSix = new CountDownLatch(1);
        List<Cms.Site> sixStuck = new ArrayList<>();
        for (int i = 0; i < 6; i++) sixStuck.add(site("stuck-" + i));
        SearchCoordinator stuckCoord =
                new SearchCoordinator(
                        (s, q) -> {
                            sixEntered.countDown();
                            while (releaseSix.getCount() > 0) {
                                try {
                                    releaseSix.await(50, TimeUnit.MILLISECONDS);
                                } catch (InterruptedException ignored) {
                                }
                            }
                            return Collections.emptyList();
                        },
                        (s, v, o) -> {
                            if (o == SearchCoordinator.Outcome.TIMEOUT) sixTimedOut.countDown();
                        },
                        80,
                        1000);
        stuckCoord.start(sixStuck, "old-query");
        check(sixEntered.await(1, TimeUnit.SECONDS), "all six uninterruptible workers entered");
        check(
                sixTimedOut.await(1, TimeUnit.SECONDS),
                "all six uninterruptible workers reported timeout");
        CountDownLatch followUpDone = new CountDownLatch(2);
        Map<String, SearchCoordinator.Outcome> followUpOutcomes = new ConcurrentHashMap<>();
        SearchCoordinator healthyCoord =
                new SearchCoordinator(
                        (s, q) -> Collections.singletonList(video("ok-" + s.key)),
                        (s, v, o) -> {
                            followUpOutcomes.put(s.key, o);
                            followUpDone.countDown();
                        },
                        300,
                        1000);
        healthyCoord.start(
                Arrays.asList(site("stuck-0"), site("healthy-after-stuck")), "new-query");
        check(
                followUpDone.await(1, TimeUnit.SECONDS)
                        && followUpOutcomes.get("healthy-after-stuck")
                                == SearchCoordinator.Outcome.RESULT
                        && followUpOutcomes.get("stuck-0") == SearchCoordinator.Outcome.BUSY,
                "healthy source executes while wedged uninterruptible sources are isolated");
        healthyCoord.close();
        stuckCoord.close();
        releaseSix.countDown();
        long recoverDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (SearchCoordinator.isSiteWedged("stuck-0") && System.nanoTime() < recoverDeadline) {
            Thread.sleep(10);
        }
        check(!SearchCoordinator.isSiteWedged("stuck-0"), "wedged site recovers once call exits");

        // A full plugin isolation budget must not starve host-controlled CMS I/O.
        CountDownLatch releaseCapacity = new CountDownLatch(1);
        CountDownLatch capacityTimedOut = new CountDownLatch(30);
        List<Cms.Site> capacitySites = new ArrayList<>();
        for (int i = 0; i < 30; i++) capacitySites.add(site("capacity-" + i));
        SearchCoordinator capacity =
                new SearchCoordinator(
                        (s, q) -> {
                            while (releaseCapacity.getCount() > 0) {
                                try {
                                    releaseCapacity.await(20, TimeUnit.MILLISECONDS);
                                } catch (InterruptedException ignored) {
                                }
                            }
                            return Collections.emptyList();
                        },
                        (s, v, o) -> capacityTimedOut.countDown(),
                        50,
                        3000);
        capacity.start(capacitySites, "capacity");
        try {
            check(
                    capacityTimedOut.await(3, TimeUnit.SECONDS),
                    "plugin capacity test reached deadlines");
            Cms.Site httpSite = site("healthy-http-at-capacity");
            httpSite.type = 1;
            httpSite.api = "https://fixture.example/api";
            CountDownLatch httpDone = new CountDownLatch(1);
            AtomicReference<SearchCoordinator.Outcome> httpOutcome = new AtomicReference<>();
            SearchCoordinator http =
                    new SearchCoordinator(
                            (s, q) -> Collections.singletonList(video("http-result")),
                            (s, v, o) -> {
                                httpOutcome.set(o);
                                httpDone.countDown();
                            },
                            300,
                            1000);
            http.start(Collections.singletonList(httpSite), "healthy");
            check(
                    httpDone.await(1, TimeUnit.SECONDS)
                            && httpOutcome.get() == SearchCoordinator.Outcome.RESULT,
                    "healthy CMS survives exhausted plugin pool");
            http.close();
        } finally {
            capacity.close();
            releaseCapacity.countDown();
        }

        System.out.println(
                "OK "
                        + checks
                        + " global search and pinyin checks; no real source playback implied.");
    }
}
