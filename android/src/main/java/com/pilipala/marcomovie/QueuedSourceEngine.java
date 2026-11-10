package com.pilipala.marcomovie;

/** Keeps extension state serialized; user-selected details/playback precede queued browsing. */
final class QueuedSourceEngine implements SourceEngine {
    final SourceEngine delegate;
    final SourceGate gate = new SourceGate();

    QueuedSourceEngine(SourceEngine source) {
        delegate = source;
    }

    boolean isWedged() {
        return gate.isWedged() || delegate.isClosed();
    }

    public String home() throws Exception {
        return gate.call(false, delegate::home);
    }

    public String homeVideos() throws Exception {
        return gate.call(false, delegate::homeVideos);
    }

    public String liveContent(String url) throws Exception {
        return gate.call(true, () -> delegate.liveContent(url));
    }

    public String category(String id, int page) throws Exception {
        return gate.call(false, () -> delegate.category(id, page));
    }

    public String category(String id, int page, java.util.Map<String, String> filters)
            throws Exception {
        java.util.Map<String, String> values = new java.util.LinkedHashMap<>(filters);
        return gate.call(false, () -> delegate.category(id, page, values));
    }

    public String search(String query, int page) throws Exception {
        return gate.call(false, () -> delegate.search(query, page));
    }

    public String detail(String id) throws Exception {
        if (!delegate.requiresExternalRuntime()) return delegate.detail(id);
        return gate.call(true, () -> delegate.detail(id));
    }

    public String player(String flag, String id) throws Exception {
        if (!delegate.requiresExternalRuntime()) return delegate.player(flag, id);
        return gate.call(true, () -> delegate.player(flag, id));
    }

    public String action(String value) throws Exception {
        if (!delegate.requiresExternalRuntime()) return delegate.action(value);
        return gate.call(true, () -> delegate.action(value));
    }

    public boolean supportsCustomAction() {
        return delegate.supportsCustomAction();
    }

    public String detailAction(String id) throws Exception {
        if (!delegate.requiresExternalRuntime()) return delegate.detailAction(id);
        return gate.call(true, () -> delegate.detailAction(id));
    }

    public boolean requiresExternalRuntime() {
        return delegate.requiresExternalRuntime();
    }

    public void close() {
        try {
            gate.call(
                    true,
                    () -> {
                        delegate.close();
                        return null;
                    });
        } catch (Exception ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
