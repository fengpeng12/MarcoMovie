package com.pilipala.marcomovie;

import java.io.InterruptedIOException;
import java.net.HttpURLConnection;
import java.util.Set;
import java.util.concurrent.*;

/** Cancellation reaches host-managed sockets, including requests made on the JS thread.
 * Third-party native networking is outside this scope and retains its own timeouts. */
final class RequestScope {
    private static final ThreadLocal<RequestScope> CURRENT = new ThreadLocal<>();
    private static final ExecutorService CLOSER =
            Executors.newFixedThreadPool(
                    2,
                    r -> {
                        Thread t = new Thread(r, "movie-request-close");
                        t.setDaemon(true);
                        return t;
                    });
    final Set<HttpURLConnection> connections =
            java.util.Collections.newSetFromMap(
                    new ConcurrentHashMap<HttpURLConnection, Boolean>());
    final Set<Runnable> cancelListeners =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<Runnable, Boolean>());
    volatile boolean cancelled;

    static RequestScope current() {
        return CURRENT.get();
    }

    static void onCancel(Runnable listener) {
        RequestScope scope = CURRENT.get();
        if (scope != null && listener != null) {
            scope.cancelListeners.add(listener);
            if (scope.cancelled && scope.cancelListeners.remove(listener)) {
                listener.run();
            }
        }
    }

    static void offCancel(Runnable listener) {
        RequestScope scope = CURRENT.get();
        if (scope != null && listener != null) {
            scope.cancelListeners.remove(listener);
        }
    }

    <T> T call(Callable<T> work) throws Exception {
        RequestScope previous = CURRENT.get();
        if (previous == null) {
            Thread.interrupted();
        }
        CURRENT.set(this);
        try {
            check();
            return work.call();
        } finally {
            if (previous == null) {
                CURRENT.remove();
                Thread.interrupted();
            } else {
                CURRENT.set(previous);
            }
        }
    }

    void check() throws InterruptedIOException {
        if (cancelled || Thread.currentThread().isInterrupted())
            throw new InterruptedIOException("Request cancelled");
    }

    static void attach(HttpURLConnection connection) throws InterruptedIOException {
        RequestScope scope = CURRENT.get();
        if (scope != null) {
            scope.check();
            scope.connections.add(connection);
            if (scope.cancelled) {
                scope.connections.remove(connection);
                CLOSER.execute(connection::disconnect);
                throw new InterruptedIOException("Request cancelled");
            }
        }
    }

    static void detach(HttpURLConnection connection) {
        RequestScope scope = CURRENT.get();
        if (scope != null) scope.connections.remove(connection);
    }

    void cancel() {
        cancelled = true;
        for (HttpURLConnection connection : connections)
            if (connections.remove(connection)) CLOSER.execute(connection::disconnect);
        for (Runnable listener : cancelListeners)
            if (cancelListeners.remove(listener)) {
                try {
                    listener.run();
                } catch (Exception ignored) {
                }
            }
    }

    static Future<?> submit(ExecutorService executor, Runnable work) {
        RequestScope scope = new RequestScope();
        FutureTask<Void> task =
                new FutureTask<Void>(
                        () ->
                                scope.call(
                                        () -> {
                                            work.run();
                                            return null;
                                        })) {
                    @Override
                    public boolean cancel(boolean interrupt) {
                        boolean result = super.cancel(interrupt);
                        if (result) scope.cancel();
                        return result;
                    }
                };
        executor.execute(task);
        return task;
    }
}
