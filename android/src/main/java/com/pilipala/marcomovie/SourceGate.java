package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;

/** Per-instance serialization with interruptible waits, foreground preference, and wedged-call recovery. */
final class SourceGate {
    private static final ThreadLocal<long[]> TIMING = new ThreadLocal<>();
    private static final ConcurrentHashMap<Thread, SourceGate> ACTIVE_GATES =
            new ConcurrentHashMap<>();

    static <T> T measured(long[] result, Callable<T> work) throws Exception {
        long[] previous = TIMING.get();
        TIMING.set(result);
        try {
            return work.call();
        } finally {
            if (previous == null) TIMING.remove();
            else TIMING.set(previous);
        }
    }

    static void markWedged(Thread thread) {
        if (thread == null) return;
        SourceGate gate = ACTIVE_GATES.get(thread);
        if (gate != null) gate.tripWedged(thread);
    }

    private boolean occupied;
    private int foreground;
    private Thread holder;
    private volatile boolean wedged;

    boolean isWedged() {
        return wedged;
    }

    synchronized void tripWedged(Thread expectedHolder) {
        if (occupied && (expectedHolder == null || holder == expectedHolder)) {
            wedged = true;
            notifyAll();
        }
    }

    <T> T call(boolean urgent, Callable<T> task) throws Exception {
        long queued = System.nanoTime();
        Thread current = Thread.currentThread();
        synchronized (this) {
            if (urgent) foreground++;
            try {
                while (occupied || (!urgent && foreground > 0)) {
                    if (wedged) throw new IOException("来源请求尚未结束，请稍后重试或重新加载订阅");
                    wait();
                }
                if (current.isInterrupted()) throw new InterruptedException();
                if (!urgent && wedged) {
                    throw new IOException("来源后台请求超时未释放，已暂时限流");
                }
                occupied = true;
                wedged = false;
                holder = current;
            } finally {
                if (urgent) foreground--;
                notifyAll();
            }
        }
        ACTIVE_GATES.put(current, this);
        Runnable onScopeCancel = !urgent ? () -> tripWedged(current) : null;
        if (onScopeCancel != null) RequestScope.onCancel(onScopeCancel);
        long entered = System.nanoTime();
        long[] timing = TIMING.get();
        if (timing != null) timing[0] += entered - queued;
        try {
            return task.call();
        } finally {
            if (onScopeCancel != null) RequestScope.offCancel(onScopeCancel);
            ACTIVE_GATES.remove(current, this);
            if (timing != null) timing[1] += System.nanoTime() - entered;
            synchronized (this) {
                if (holder == current) {
                    occupied = false;
                    wedged = false;
                    holder = null;
                }
                notifyAll();
            }
        }
    }
}
