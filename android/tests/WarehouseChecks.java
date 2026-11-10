package com.pilipala.marcomovie;

import com.pilipala.source.Warehouse;
import java.util.*;
import org.json.*;

public final class WarehouseChecks {
    public static void main(String[] args) throws Exception {
        final Map<String, String> docs = new HashMap<>();
        docs.put(
                "https://warehouse.example/root.json",
                "{\"storeHouse\":[{\"sourceName\":\"A\",\"sourceUrl\":\"./a.txt\"},{\"sourceName\":\"date\",\"sourceUrl\":\"更新时间\"}]}");
        docs.put(
                "https://warehouse.example/a.txt",
                "{\"urls\":[{\"name\":\"missing\",\"url\":\"./missing.json\"},{\"name\":\"leaf\",\"url\":\"./leaf/one.json\"}]}");
        docs.put(
                "https://warehouse.example/leaf/one.json",
                "{\"sites\":[{\"key\":\"one\",\"name\":\"one\",\"type\":1,\"api\":\"./api.php\"}]}");
        final List<String> requests = new ArrayList<>();
        Warehouse.Reader reader =
                url -> {
                    requests.add(url);
                    if (!docs.containsKey(url)) throw new java.io.IOException();
                    return docs.get(url);
                };
        Warehouse.Decoder decoder = raw -> new JSONObject(Cms.withoutComments(raw));
        Warehouse.Validator validator = (raw, origin) -> Cms.parseConfig(raw, origin);
        String root = "https://warehouse.example/root.json";
        String result = Warehouse.resolve(docs.get(root), root, reader, decoder, validator);
        Cms.Config parsed = Cms.parseConfig(result, root);
        check(
                parsed.sites.get(0).api.equals("https://warehouse.example/leaf/api.php"),
                "relative leaf base");
        check(parsed.depots.length() == 3, "nested directory retained; annotation skipped");
        check(parsed.warehouse.equals(root), "root survives reload");
        check(requests.size() == 3, "bounded sibling fallback");
        String retained =
                Warehouse.retainDirectory(
                        docs.get("https://warehouse.example/leaf/one.json"),
                        "https://warehouse.example/leaf/one.json",
                        result,
                        decoder);
        check(Cms.parseConfig(retained, root).depots.length() == 3, "switch retains branches");
        String loop = "{\"urls\":[{\"name\":\"cycle\",\"url\":\"./root.json\"}]}";
        try {
            Warehouse.resolve(loop, root, reader, decoder, validator);
            throw new AssertionError("cycle accepted");
        } catch (java.io.IOException expected) {
        }
        check(requests.size() == 3, "cycle never fetched");
        System.out.println("Warehouse checks passed");
    }

    private static void check(boolean ok, String why) {
        if (!ok) throw new AssertionError(why);
    }
}
