package com.pilipala.marcomovie;

/** Runs against compiled production classes; does not simulate Activity lifecycle. */
public final class PrivacySearchChecks {
    public static void main(String[] args) throws Exception {
        MobileShell.cachedSearchKeyword = "private fixture";
        MobileShell.pendingSearchKeyword = "pending private fixture";
        MobileShell.cachedSearchStatus = "private result";
        MobileShell.cachedSearchHits.add(new MobileShell.CachedSearchHit(null, null));
        MobileShell.cachedSearchScrollY = 120;
        java.lang.reflect.Field filter = optional("cachedSearchSiteFilter");
        java.lang.reflect.Field scroll = optional("cachedSiteFilterScrollX");
        if (filter != null) filter.set(null, "private source");
        if (scroll != null) scroll.setInt(null, 120);

        MobileShell.clearSearchSession();
        if (!MobileShell.cachedSearchKeyword.isEmpty()
                || !MobileShell.pendingSearchKeyword.isEmpty()
                || !MobileShell.cachedSearchStatus.isEmpty()
                || !MobileShell.cachedSearchHits.isEmpty()
                || MobileShell.cachedSearchScrollY != 0
                || (filter != null && !"".equals(filter.get(null)))
                || (scroll != null && scroll.getInt(null) != 0)) {
            throw new AssertionError("Private search data survived session cleanup");
        }
        System.out.println(
                "PASS production search cleanup clears private keywords, results and view state");
    }

    private static java.lang.reflect.Field optional(String name) throws Exception {
        try {
            java.lang.reflect.Field field = MobileShell.class.getDeclaredField(name);
            field.setAccessible(true);
            return field;
        } catch (NoSuchFieldException absentInOlderBranch) {
            return null;
        }
    }
}
