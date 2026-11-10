import com.pilipala.marcomovie.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.io.*;

public final class CmsChecks {
    static int count;

    static void check(boolean b, String label) {
        if (!b) throw new AssertionError(label);
        System.out.println("PASS " + label);
        count++;
    }

    public static void main(String[] args) throws Exception {
        check(
                Cms.normalizeHttp("https://例子.test/config")
                        .equals("https://xn--fsqu00a.test/config"),
                "IDN host converted");
        String cfg =
                "{\"sites\":[{\"key\":\"a\",\"name\":\"Local\",\"type\":1,\"api\":\"/cms?token=x&ac=old\",\"header\":{\"Referer\":\"http://example.test/\"}}]}";
        Cms.Config c = Cms.parseConfig(cfg, args[1]);
        Cms.Site s = c.sites.get(0);
        check(s.supported(), "standard type1 selected");
        String query = Cms.query(s.api, "ac", "list");
        check(
                query.contains("token=x") && !query.contains("ac=old"),
                "query replaces parameters and retains credentials privately");
        SourceEngine engine = new JsonCmsEngine(s);
        check(Cms.categories(engine.home()).size() == 1, "mock CMS category fetch");
        Cms.Listing list = Cms.listing(engine.category("7", 1));
        check(list.videos.size() == 1 && list.pageCount == 2, "mock paged listing");
        Cms.Video v = Cms.listing(engine.detail("42")).videos.get(0);
        check(
                v.lines.size() == 2 && v.lines.get(0).episodes.size() == 2,
                "multi-line and episode separators");
        check(v.lines.get(0).episodes.get(0).url.contains("x=1$2"), "episode URL dollar retained");
        check(Cms.listing(engine.search("中文", 1)).videos.size() == 1, "mock unicode search");
        boolean blocked = false;
        try {
            Cms.assertMedia(args[1] + "web", s.headers);
        } catch (IOException e) {
            blocked = true;
        }
        check(blocked, "HTML parser page rejected before player");
        Cms.assertMedia(args[1] + "video.mp4", s.headers);
        check(true, "direct media accepted");
        blocked = false;
        try {
            Cms.parseConfig("{\"sites\":[]}", null);
        } catch (IOException e) {
            blocked = true;
        }
        check(blocked, "empty config failure");
        check(
                Cms.withoutComments("{\"a\":\"https://x/*y*/\",/*z*/\"b\":1//e\n}")
                        .contains("https://x/*y*/"),
                "comments stripped without changing URL strings");
        Cms.ImageRequest picture =
                Cms.imageRequest(
                        "https://image.test/p.jpg@Referer=https://catalog.test/@User-Agent=Mozilla/5.0");
        check(
                picture.url.equals("https://image.test/p.jpg")
                        && picture.headers.get("Referer").equals("https://catalog.test/")
                        && picture.headers.get("User-Agent").equals("Mozilla/5.0"),
                "actual poster header suffix separated from image URL");
        System.out.println("OK " + count + " checks");
    }
}
