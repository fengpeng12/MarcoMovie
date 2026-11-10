import com.pilipala.marcomovie.lite.LiteCatalog;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.util.List;

/** Exercise the real API-14 parser/network code; Android Base64 is a host-test shim only. */
public final class LiteFormatChecks {
    public static void main(String[] args) throws Exception {
        String json = "{\"name\":\"测试\",\"type\":1,\"api\":\"./api.php\"}";
        String array =
                "[{\"key\":\"cms\",\"name\":\"CMS fixture\",\"type\":1,\"api\":\"./api.php\","
                        + "\"header\":{\"X-Fixture\":\"array\"}},"
                        + "{\"key\":\"plugin\",\"type\":3,\"api\":\"./main.js\"}]";
        String base = "https://fixture.test/subscription.php";
        List<LiteCatalog.Site> arraySites =
                LiteCatalog.parse(LiteCatalog.importConfig(array, base), base);
        if (arraySites.size() != 2
                || !arraySites.get(0).key.equals("cms")
                || !arraySites.get(0).supported
                || !arraySites.get(0).api.equals("https://fixture.test/api.php")
                || !"array".equals(arraySites.get(0).headers.get("X-Fixture"))
                || arraySites.get(1).supported)
            throw new AssertionError("Lite root site array metadata or supported status lost");
        for (String helper :
                new String[] {
                    "[]",
                    "[\"value\"]",
                    "[{\"title\":\"helper\"}]",
                    "[{\"api\":17}]",
                    "[{\"api\":\"./api.php\"},{\"title\":\"helper\"}]"
                }) {
            try {
                LiteCatalog.parse(helper, base);
                throw new AssertionError("Lite helper array treated as source configuration");
            } catch (java.io.IOException expected) {
            }
        }
        for (String encoding : new String[] {"UTF-16LE", "UTF-16BE"}) {
            String text = LiteCatalog.decodeText(("\ufeff" + json).getBytes(encoding));
            LiteCatalog.Site site =
                    LiteCatalog.parse(text, "https://fixture.test/subscription.php").get(0);
            if (!site.name.equals("测试")
                    || !site.supported
                    || !site.api.equals("https://fixture.test/api.php"))
                throw new AssertionError("Lite UTF16/direct-site parse failed");
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/subscription.php",
                exchange -> {
                    byte[] body = ("\ufeff" + json).getBytes("UTF-16BE");
                    exchange.sendResponseHeaders(200, body.length);
                    try (java.io.OutputStream out = exchange.getResponseBody()) {
                        out.write(body);
                    }
                });
        server.createContext(
                "/array.php",
                exchange -> {
                    byte[] body = ("\ufeff" + array).getBytes("UTF-16LE");
                    exchange.sendResponseHeaders(200, body.length);
                    try (java.io.OutputStream out = exchange.getResponseBody()) {
                        out.write(body);
                    }
                });
        server.start();
        try {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/subscription.php";
            List<LiteCatalog.Site> sites = LiteCatalog.parse(LiteCatalog.fetch(url, null), url);
            if (sites.size() != 1 || !sites.get(0).supported || !sites.get(0).name.equals("测试"))
                throw new AssertionError("Lite PHP returned UTF16 JSON fetch failed");
            String arrayUrl = "http://127.0.0.1:" + server.getAddress().getPort() + "/array.php";
            List<LiteCatalog.Site> remote =
                    LiteCatalog.parse(
                            LiteCatalog.importConfig(LiteCatalog.fetch(arrayUrl, null), arrayUrl),
                            arrayUrl);
            if (remote.size() != 2
                    || !remote.get(0).supported
                    || !remote.get(0).api.equals(arrayUrl.replace("/array.php", "/api.php"))
                    || remote.get(1).supported)
                throw new AssertionError("Lite PHP returned root array import failed");
        } finally {
            server.stop(0);
        }
        if (LiteCatalog.parse(
                        "{\"sites\":[{\"type\":3,\"api\":\"https://fixture.test/main.js\"}]}", "")
                .get(0)
                .supported)
            throw new AssertionError("Lite executable script was falsely marked supported");
        System.out.println(
                "PASS Lite PHP endpoint, UTF16 LE/BE, single-site/root-array JSON, metadata, relative API, helper rejection, unsupported-script status");
    }
}
