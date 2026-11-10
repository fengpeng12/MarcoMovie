package com.pilipala.marcomovie;

import com.whl.quickjs.wrapper.QuickJSContext;
import java.io.IOException;

/** Native instruction-loop cancellation for the build-pinned wrapper 3.2.3. */
final class QuickJsDeadline {
    private static boolean loaded;
    private final long owner = Thread.currentThread().getId();
    private long handle;
    private long generation;

    private static synchronized void load() throws IOException {
        if (loaded) return;
        try {
            System.loadLibrary("movie-quickjs-deadline");
            loaded = true;
        } catch (LinkageError failure) {
            throw new IOException("缺少匹配的脚本超时保护组件，请重新安装完整安装包", failure);
        }
    }

    QuickJsDeadline(QuickJSContext context) throws IOException {
        load();
        try {
            handle = attach0(context);
            if (handle == 0) throw new IllegalStateException("Empty native deadline handle");
        } catch (LinkageError | RuntimeException failure) {
            throw new IOException("脚本引擎与超时保护组件不匹配，请更新完整安装包", failure);
        }
    }

    static final class Operation {
        private final long handle, generation;

        Operation(long handle, long generation) {
            this.handle = handle;
            this.generation = generation;
        }

        void cancel() {
            cancel0(handle, generation);
        }

        int finish() {
            return finish0(handle, generation);
        }
    }

    private void checkOwner() {
        if (owner != Thread.currentThread().getId())
            throw new IllegalStateException("QuickJS deadline must be managed on its owner thread");
    }

    Operation begin(long timeoutMillis) {
        checkOwner();
        if (handle == 0 || generation == Long.MAX_VALUE)
            throw new IllegalStateException("QuickJS deadline is closed");
        long ticket = ++generation;
        arm0(handle, ticket, Math.max(1, Math.min(45000, timeoutMillis)));
        return new Operation(handle, ticket);
    }

    void close() {
        checkOwner();
        if (handle == 0) return;
        detach0(handle);
        handle = 0;
    }

    private static native long attach0(QuickJSContext context);

    private static native void arm0(long handle, long generation, long timeoutMillis);

    private static native void cancel0(long handle, long generation);

    private static native int finish0(long handle, long generation);

    private static native void detach0(long handle);
}
