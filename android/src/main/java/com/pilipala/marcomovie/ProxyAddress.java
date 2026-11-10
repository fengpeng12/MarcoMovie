package com.pilipala.marcomovie;

import java.net.URI;
import java.net.URLDecoder;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Pure URL routing and request validation for the reserved source proxy endpoint. */
final class ProxyAddress {
    static volatile int port = 9978;
    static volatile String token = "";

    static String base() {
        return "http://127.0.0.1:" + port;
    }

    /** Recognize only the source endpoint that rewrite() can route to this listener. */
    static boolean isSourceProxy(String address) {
        return isListenerAddress(rewrite(address));
    }

    private static boolean isListenerAddress(String address) {
        try {
            URI uri = new URI(address);
            return "http".equalsIgnoreCase(uri.getScheme())
                    && isLoopbackHost(uri.getHost())
                    && uri.getPort() == port
                    && "/proxy".equals(uri.getPath());
        } catch (Exception ignored) {
            return false;
        }
    }

    /** A source's Origin/Host are upstream metadata, not the local HTTP authority. */
    static Map<String, String> requestHeaders(String address, Map<String, String> original) {
        Map<String, String> out = new LinkedHashMap<>(original);
        if (!isListenerAddress(address) || token.isEmpty()) return out;
        try {
            String query = new URI(address).getRawQuery();
            int matches = 0;
            if (query != null)
                for (String pair : query.split("&")) {
                    String[] parts = pair.split("=", 2);
                    if ("_mm_token".equalsIgnoreCase(URLDecoder.decode(parts[0], "UTF-8"))) {
                        if (parts.length != 2
                                || !token.equals(URLDecoder.decode(parts[1], "UTF-8"))) return out;
                        matches++;
                    }
                }
            if (matches != 1) return out;
        } catch (Exception ignored) {
            return out;
        }
        String origin = null, host = null;
        for (java.util.Iterator<Map.Entry<String, String>> it = out.entrySet().iterator();
                it.hasNext(); ) {
            Map.Entry<String, String> header = it.next();
            String name = header.getKey();
            if ("Origin".equalsIgnoreCase(name)) {
                origin = header.getValue();
                it.remove();
            } else if ("Host".equalsIgnoreCase(name)) {
                host = header.getValue();
                it.remove();
            } else if ("X-Movie-Origin".equalsIgnoreCase(name)
                    || "X-Movie-Host".equalsIgnoreCase(name)) it.remove();
        }
        if (origin != null && !origin.isEmpty()) out.put("X-Movie-Origin", origin);
        if (host != null && !host.isEmpty()) out.put("X-Movie-Host", host);
        return out;
    }

    static String rewrite(String value) {
        return rewrite(value, port, token);
    }

    static String rewrite(String value, int port) {
        return rewrite(value, port, "");
    }

    static String rewrite(String value, int port, String sessionToken) {
        if (value == null || port < 1 || port > 65535) return value;
        try {
            String trimmed = value.trim();
            if (trimmed.regionMatches(true, 0, "proxy://", 0, 8)) {
                String rest = trimmed.substring(8);
                while (rest.startsWith("/") || rest.startsWith("?")) rest = rest.substring(1);
                trimmed = "http://127.0.0.1:9978/proxy" + (rest.isEmpty() ? "" : "?" + rest);
            }
            String candidate =
                    trimmed.replace("http://127.0.0.1:-1/", "http://127.0.0.1:9978/")
                            .replace("http://localhost:-1/", "http://localhost:9978/")
                            .replace("http://127.0.0.1:0/", "http://127.0.0.1:9978/")
                            .replace("http://localhost:0/", "http://localhost:9978/");
            URI uri = new URI(sanitizePathAndQuery(candidate));
            String host = uri.getHost();
            int original = uri.getPort();
            boolean validPort =
                    original == port || original == 0 || (original >= 9978 && original <= 9999);
            if (!"http".equalsIgnoreCase(uri.getScheme())
                    || !isLoopbackHost(host)
                    || !"/proxy".equals(uri.getPath())
                    || !validPort) return value;
            String query = uri.getRawQuery();
            if (sessionToken != null
                    && !sessionToken.isEmpty()
                    && (query == null || !query.contains("_mm_token="))) {
                query =
                        (query == null || query.isEmpty() ? "" : query + "&")
                                + "_mm_token="
                                + sessionToken;
            }
            return "http://127.0.0.1:"
                    + port
                    + uri.getRawPath()
                    + (query == null ? "" : "?" + query)
                    + (uri.getRawFragment() == null ? "" : "#" + uri.getRawFragment());
        } catch (Exception ignored) {
            return value;
        }
    }

    static String sanitizePathAndQuery(String url) {
        if (url == null) return "";
        int schemeEnd = url.indexOf("://");
        if (schemeEnd < 0) return url;
        int pathStart = url.indexOf('/', schemeEnd + 3);
        if (pathStart < 0) return url;
        String prefix = url.substring(0, pathStart);
        String tail =
                url.substring(pathStart)
                        .replace("[", "%5B")
                        .replace("]", "%5D")
                        .replace("|", "%7C")
                        .replace("{", "%7B")
                        .replace("}", "%7D")
                        .replace("\"", "%22")
                        .replace("<", "%3C")
                        .replace(">", "%3E")
                        .replace("\\", "%5C")
                        .replace("^", "%5E")
                        .replace("`", "%60")
                        .replace(" ", "%20");
        return prefix + tail;
    }

    static boolean isLoopbackHost(String host) {
        if (host == null || host.isEmpty()) return false;
        String bare = host.trim();
        if (bare.startsWith("[")) {
            int close = bare.indexOf(']');
            if (close < 0) return false;
            bare = bare.substring(0, close + 1);
        } else {
            int colon = bare.indexOf(':');
            if (colon >= 0) bare = bare.substring(0, colon);
        }
        return "127.0.0.1".equals(bare)
                || "localhost".equalsIgnoreCase(bare)
                || "[::1]".equals(bare);
    }

    /**
     * Rejects DNS-rebinding Host headers, cross-origin browser requests, and mismatched session
     * tokens.
     */
    static boolean isAllowedRequest(
            String hostHeader,
            String originHeader,
            String secFetchSite,
            String requestToken,
            String expectedToken,
            boolean requireToken) {
        if (hostHeader != null && !hostHeader.isEmpty() && !isLoopbackHost(hostHeader))
            return false;
        if (originHeader != null && !originHeader.isEmpty()) return false;
        if (secFetchSite != null
                && !secFetchSite.isEmpty()
                && !"none".equalsIgnoreCase(secFetchSite.trim())
                && !"same-origin".equalsIgnoreCase(secFetchSite.trim())) return false;
        if (expectedToken != null && !expectedToken.isEmpty()) {
            if (requireToken) return expectedToken.equals(requestToken);
            if (requestToken != null && !requestToken.isEmpty())
                return expectedToken.equals(requestToken);
        }
        return true;
    }
}
