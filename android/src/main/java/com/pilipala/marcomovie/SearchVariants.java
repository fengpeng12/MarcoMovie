package com.pilipala.marcomovie;

import java.util.*;

/** Keep the first useful response; a later spelling fallback must not erase already found items. */
final class SearchVariants {
    interface Match {
        boolean test(String title);
    }

    interface Fetch {
        List<Cms.Video> get(String term) throws Exception;
    }

    static List<Cms.Video> run(String query, List<String> variants, Match matches, Fetch fetch)
            throws Exception {
        Exception failure = null;
        int attempts = 0;
        for (String term : variants) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
            if (++attempts > 3) break;
            try {
                List<Cms.Video> batch = fetch.get(term);
                List<Cms.Video> result = new ArrayList<>();
                Set<String> ids = new HashSet<>();
                if (batch != null)
                    for (Cms.Video v : batch)
                        if (v != null
                                && v.id != null
                                && !v.id.isEmpty()
                                && (term.equalsIgnoreCase(query) || matches.test(v.title))
                                && ids.add(v.id)) result.add(v);
                if (!result.isEmpty()) return result;
            } catch (SearchCoordinator.VerificationRequiredException e) {
                throw e;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw e;
            } catch (Exception e) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
                failure = e;
            }
        }
        if (failure != null) throw failure;
        return Collections.emptyList();
    }
}
