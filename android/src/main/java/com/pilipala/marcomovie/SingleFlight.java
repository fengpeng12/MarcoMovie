package com.pilipala.marcomovie;

import java.util.concurrent.*;

/** Share in-progress initialization without holding a global lock during plugin work. */
final class SingleFlight<T> {
    private final ConcurrentHashMap<String, FutureTask<T>> pending = new ConcurrentHashMap<>();

    T get(String key, Callable<T> factory) throws Exception {
        FutureTask<T> candidate = new FutureTask<>(factory);
        FutureTask<T> task = pending.putIfAbsent(key, candidate);
        if (task == null) {
            task = candidate;
            task.run();
        }
        try {
            return task.get();
        } catch (ExecutionException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause != null)
                throw new java.io.IOException(
                        "运行环境或扩展异常：" + cause.getClass().getSimpleName(), cause);
            throw new IllegalStateException(failure);
        } finally {
            // A cancelled waiter must not remove an initialization still used by others.
            if (task.isDone()) pending.remove(key, task);
        }
    }
}
