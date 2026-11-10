package com.pilipala.source;

import java.net.URL;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Credentials belong to one scheme/host/port, including redirects and HLS children. */
public final class MediaRequestHeaders {
    private MediaRequestHeaders() {}

    public static Map<String, String> forTarget(
            Map<String, String> headers, String origin, String target) {
        boolean same = false;
        try {
            URL a = new URL(origin), b = new URL(target);
            same =
                    a.getProtocol().equalsIgnoreCase(b.getProtocol())
                            && a.getHost().equalsIgnoreCase(b.getHost())
                            && port(a) == port(b);
        } catch (Exception ignored) {
        }
        Map<String, String> result = new LinkedHashMap<String, String>();
        if (headers != null)
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                String key = entry.getKey().toLowerCase(Locale.US);
                boolean sensitive =
                        key.equals("authorization")
                                || key.equals("proxy-authorization")
                                || key.equals("cookie")
                                || key.equals("cookie2")
                                || key.equals("x-api-key")
                                || key.equals("x-emby-token")
                                || key.equals("x-plex-token");
                if (same || !sensitive) result.put(entry.getKey(), entry.getValue());
            }
        return result;
    }

    private static int port(URL value) {
        return value.getPort() >= 0 ? value.getPort() : value.getDefaultPort();
    }
}
