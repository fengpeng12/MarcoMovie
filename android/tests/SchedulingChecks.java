package com.pilipala.marcomovie;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.net.*;
import java.io.*;

public final class SchedulingChecks {
    static int checks;

    static void check(boolean b, String name) {
        if (!b) throw new AssertionError(name);
        checks++;
        System.out.println("PASS " + name);
    }

    static void waiting(Thread t) throws Exception {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (t.getState() != Thread.State.WAITING && System.nanoTime() < end) Thread.sleep(1);
        check(t.getState() == Thread.State.WAITING, "request waiting behind active plugin");
    }

    public static void main(String[] args) throws Exception {
        AtomicLong clock = new AtomicLong();
        DetailCache cache = new DetailCache(clock::get);
        cache.put("a", "one");
        check("one".equals(cache.get("a")), "cache hit");
        clock.set(DetailCache.TTL_MS);
        check(cache.get("a") == null, "expiry at TTL");
        for (int i = 0; i < 25; i++) cache.put("key" + i, "data");
        check(cache.entries.size() == 24 && cache.get("key0") == null, "bounded entry eviction");
        cache.get("key1");
        cache.put("last", "data");
        check(cache.get("key1") != null && cache.get("key2") == null, "LRU retains recent details");
        cache.clear();
        check(cache.chars == 0 && cache.entries.isEmpty(), "configuration clear");
        char[] big = new char[600000];
        Arrays.fill(big, 'a');
        cache.put("big1", new String(big));
        cache.put("big2", new String(big));
        check(
                cache.entries.size() == 1 && cache.chars <= DetailCache.MAX_CHARS,
                "bounded metadata memory");
        cache.put("big2", "tiny");
        check(cache.chars == 8, "replacement byte accounting");
        SourceGate gate = new SourceGate();
        CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
        List<String> order = Collections.synchronizedList(new ArrayList<>());
        AtomicReference<Throwable> error = new AtomicReference<>();
        Thread first =
                new Thread(
                        () -> {
                            try {
                                gate.call(
                                        false,
                                        () -> {
                                            started.countDown();
                                            release.await();
                                            order.add("active");
                                            return null;
                                        });
                            } catch (Throwable e) {
                                error.set(e);
                            }
                        });
        first.start();
        started.await();
        Thread browse =
                new Thread(
                        () -> {
                            try {
                                gate.call(
                                        false,
                                        () -> {
                                            order.add("browse");
                                            return null;
                                        });
                            } catch (Throwable e) {
                                error.set(e);
                            }
                        });
        browse.start();
        waiting(browse);
        Thread detail =
                new Thread(
                        () -> {
                            try {
                                gate.call(
                                        true,
                                        () -> {
                                            order.add("detail");
                                            return null;
                                        });
                            } catch (Throwable e) {
                                error.set(e);
                            }
                        });
        detail.start();
        waiting(detail);
        AtomicBoolean cancelledEntered = new AtomicBoolean();
        Thread cancelled =
                new Thread(
                        () -> {
                            try {
                                gate.call(
                                        true,
                                        () -> {
                                            cancelledEntered.set(true);
                                            return null;
                                        });
                            } catch (InterruptedException expected) {
                            } catch (Throwable e) {
                                error.set(e);
                            }
                        });
        cancelled.start();
        waiting(cancelled);
        cancelled.interrupt();
        cancelled.join(1000);
        check(
                !cancelled.isAlive() && !cancelledEntered.get(),
                "cancelled queue entry never executes");
        release.countDown();
        first.join(3000);
        detail.join(3000);
        browse.join(3000);
        check(
                error.get() == null && order.equals(Arrays.asList("active", "detail", "browse")),
                "foreground follows active call before browsing without concurrency");
        try {
            gate.call(
                    true,
                    () -> {
                        throw new IOException();
                    });
        } catch (IOException expected) {
        }
        check(gate.call(false, () -> true), "gate released after failure");
        long[] measured = new long[2];
        check(
                SourceGate.measured(
                                measured,
                                () ->
                                        gate.call(
                                                true,
                                                () -> {
                                                    Thread.sleep(8);
                                                    return true;
                                                }))
                        && measured[0] >= 0
                        && measured[1] >= TimeUnit.MILLISECONDS.toNanos(8),
                "gate separates waiting from delegate duration");
        long before = measured[1];
        try {
            SourceGate.measured(
                    measured,
                    () -> {
                        throw new IOException();
                    });
        } catch (IOException expected) {
        }
        gate.call(true, () -> true);
        check(before == measured[1], "timing scope cleared after failure");
        ExecutorService worker = Executors.newSingleThreadExecutor();
        CountDownLatch attached = new CountDownLatch(1),
                disconnected = new CountDownLatch(1),
                stop = new CountDownLatch(1);
        HttpURLConnection fake =
                new HttpURLConnection(new URL("http://fixture.test")) {
                    public void connect() {}

                    public boolean usingProxy() {
                        return false;
                    }

                    public void disconnect() {
                        disconnected.countDown();
                    }
                };
        Future<?> request =
                RequestScope.submit(
                        worker,
                        () -> {
                            try {
                                RequestScope.attach(fake);
                                attached.countDown();
                                stop.await();
                            } catch (Exception ignored) {
                            }
                        });
        attached.await();
        request.cancel(true);
        check(
                disconnected.await(2, TimeUnit.SECONDS),
                "cancel closes host-managed connection off caller thread");
        stop.countDown();
        check(
                worker.submit(() -> RequestScope.current() == null).get(),
                "scope removed before worker reuse");
        worker.shutdownNow();
        MotionSpring spring = new MotionSpring(0, 18, .05f);
        spring.target(500);
        spring.step(.07f);
        float position = spring.value, velocity = spring.velocity;
        spring.target(0);
        check(
                spring.value == position && spring.velocity == velocity,
                "reverse preserves position and velocity");
        for (int i = 0; i < 120; i++) spring.step(1f / 60);
        check(
                spring.value == 0 && spring.velocity == 0 && !spring.step(0),
                "motion settles exactly and stops");
        MotionSpring s30 = new MotionSpring(0, 18, .000001f),
                s60 = new MotionSpring(0, 18, .000001f);
        s30.target(500);
        s60.target(500);
        for (int i = 0; i < 9; i++) s30.step(1f / 30);
        for (int i = 0; i < 18; i++) s60.step(1f / 60);
        check(Math.abs(s30.value - s60.value) < .001f, "same motion timing across frame rates");

        // A wedged delegate must never be re-entered while the old holder is running.
        SourceGate wedgedGate = new SourceGate();
        CountDownLatch bgEntered = new CountDownLatch(1);
        CountDownLatch releaseBg = new CountDownLatch(1);
        CountDownLatch fgCompleted = new CountDownLatch(1);
        AtomicReference<Thread> bgHolder = new AtomicReference<>();
        Thread bgThread =
                new Thread(
                        () -> {
                            try {
                                wedgedGate.call(
                                        false,
                                        () -> {
                                            bgHolder.set(Thread.currentThread());
                                            bgEntered.countDown();
                                            while (releaseBg.getCount() > 0) {
                                                try {
                                                    releaseBg.await(50, TimeUnit.MILLISECONDS);
                                                } catch (InterruptedException ignored) {
                                                }
                                            }
                                            return null;
                                        });
                            } catch (Exception ignored) {
                            }
                        });
        bgThread.start();
        check(bgEntered.await(1, TimeUnit.SECONDS), "background source call entered gate");
        Thread fgThread =
                new Thread(
                        () -> {
                            try {
                                wedgedGate.call(
                                        true,
                                        () -> {
                                            fgCompleted.countDown();
                                            return null;
                                        });
                            } catch (Exception ignored) {
                            }
                        });
        fgThread.start();
        waiting(fgThread);
        SourceGate.markWedged(bgHolder.get());
        check(
                !fgCompleted.await(150, TimeUnit.MILLISECONDS),
                "foreground never overlaps a wedged background delegate");
        releaseBg.countDown();
        bgThread.join(1000);
        fgThread.join(1000);
        check(
                wedgedGate.call(true, () -> 42) == 42,
                "gate becomes reusable only after old call exits");

        System.out.println(checks + " scheduling/cache/motion checks passed");
    }
}
