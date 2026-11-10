package com.pilipala.marcomovie;

/** Pure navigation and crash-classification rules, kept free of Android types for JVM tests. */
final class ListingRoute {
    private ListingRoute() {}

    /** Folder, source-action and cross-search cards open another page instead of a detail page. */
    static boolean isRedirect(String tag, String action, String id) {
        return "folder".equalsIgnoreCase(tag)
                || "action".equalsIgnoreCase(tag)
                || (action != null && !action.isEmpty())
                || (id != null && id.startsWith("msearch:"));
    }

    /**
     * True only for a background thread whose failure stack contains source-extension frames. The
     * main thread and app-owned failures keep the normal system crash behavior.
     */
    static boolean isPluginBackgroundCrash(Thread thread, Throwable error, Thread mainThread) {
        if (thread == null || error == null || thread == mainThread) return false;
        return hasPluginFrame(error);
    }

    static boolean hasPluginFrame(Throwable error) {
        if (error == null) return false;
        int depth = 0;
        for (Throwable t = error; t != null && depth < 16; t = t.getCause(), depth++) {
            for (StackTraceElement e : t.getStackTrace()) {
                String cls = e.getClassName();
                if (cls.startsWith("com.github.catvod.")
                        || cls.startsWith("com.github.tvbox.")
                        || cls.startsWith("com.fongmi.")
                        || cls.startsWith("com.jar.")
                        || cls.startsWith("com.wexfnw.")) return true;
            }
            if (t.getCause() == t) break;
        }
        return false;
    }
}
