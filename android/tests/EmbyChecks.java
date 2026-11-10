import com.pilipala.emby.EmbyLibrary;
import java.util.*;
import org.json.*;

public final class EmbyChecks {
    public static void main(String[] args) throws Exception {
        JSONObject session =
                EmbyLibrary.login(args[0], "fixture", "fixture-password", "fixture-device");
        EmbyLibrary client = new EmbyLibrary(session);
        if (client.home().getJSONArray("class").length() != 1) throw new AssertionError("library");
        if (client.list("v1", "movie", 2).getInt("page") != 2)
            throw new AssertionError("pagination");
        JSONObject video = client.detail("s1").getJSONArray("list").getJSONObject(0);
        String poster = video.getString("vod_pic");
        if (!poster.endsWith("#mm-emby=" + EmbyLibrary.accountKey(session)))
            throw new AssertionError("poster account identity");
        if (!"fixture-token".equals(client.imageHeaders(poster).get("X-Emby-Token")))
            throw new AssertionError("poster auth");
        try {
            client.imageHeaders("https://elsewhere.example/Items/s1/Images/Primary");
            throw new AssertionError("image credential scope");
        } catch (java.io.IOException expected) {
        }
        String episode = video.getString("vod_play_url");
        if (!episode.startsWith("S1E1 ")) throw new AssertionError("episode name");
        String stream = episode.substring(episode.indexOf('$') + 1);
        if (!stream.contains("MediaSourceId=m1") || stream.contains("fixture-token"))
            throw new AssertionError("media source");
        if (!"fixture-token".equals(client.headersFor(stream).get("X-Emby-Token")))
            throw new AssertionError("play auth");
        if (!client.headersFor("https://elsewhere.example/Videos/e1/stream").isEmpty())
            throw new AssertionError("credential scope");
        String repeated =
                client.detail("s1").getJSONArray("list").getJSONObject(0).getString("vod_play_url");
        if (!episode.equals(repeated))
            throw new AssertionError("stable episode identity for resume");
        JSONObject direct = client.resolve(stream, false);
        if (!direct.getString("url").contains("PlaySessionId=session-m1"))
            throw new AssertionError("server playback session");
        JSONObject metadata = direct.getJSONObject("embySession");
        client.report(metadata, "Start", 0, false, false);
        client.report(metadata, "Pause", 12500, true, false);
        client.report(metadata, "TimeUpdate", 13000, true, true);
        JSONObject transcode =
                client.resolve(stream.replace("MediaSourceId=m1", "MediaSourceId=transcode"), true);
        String url = transcode.getString("url");
        if (!url.contains("/media/emby/Videos/e1/master.m3u8")
                || url.contains("api_key")
                || url.contains("obsolete")
                || !url.contains("VideoCodec=h264"))
            throw new AssertionError("transcode URL and credential scope");
        if (!"Transcode".equals(transcode.getJSONObject("embySession").getString("PlayMethod")))
            throw new AssertionError("transcode method");
        for (String rejected : new String[] {"foreign", "missing", "denied", "opening"}) {
            try {
                client.resolve(
                        stream.replace("MediaSourceId=m1", "MediaSourceId=" + rejected), false);
                throw new AssertionError("accepted invalid negotiation: " + rejected);
            } catch (java.io.IOException expected) {
            }
        }
        EmbyLibrary.Reporter reporter = client.track(transcode.getJSONObject("embySession"));
        reporter.update(0, false);
        for (int i = 0; i < 200; i++) reporter.update(i * 100, i % 2 == 0);
        reporter.stop(20000);
        reporter.update(99999, false);
        long deadline = System.currentTimeMillis() + 5000;
        boolean stopped = false;
        java.net.URL probe = new java.net.URL(args[0].replace("/media", "/test-events"));
        while (!stopped && System.currentTimeMillis() < deadline) {
            java.io.InputStream input = probe.openStream();
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            try {
                int c;
                while ((c = input.read()) != -1) bytes.write(c);
            } finally {
                input.close();
            }
            JSONArray reports = new JSONArray(bytes.toString("UTF-8"));
            for (int i = 0; i < reports.length(); i++) {
                JSONArray row = reports.getJSONArray(i);
                if (row.getString(0).endsWith("/Stopped")
                        && row.getJSONObject(1)
                                .getString("PlaySessionId")
                                .equals("session-transcode")) {
                    if (row.getJSONObject(1).getLong("PositionTicks") != 200000000)
                        throw new AssertionError("terminal progress overwritten");
                    stopped = true;
                }
            }
            if (!stopped) Thread.sleep(20);
        }
        if (!stopped) throw new AssertionError("reporter stop timeout");
        try {
            client.detail("../u2");
            throw new AssertionError("invalid id");
        } catch (java.io.IOException expected) {
        }
        System.out.println(
                "PASS Emby library, stable episode identity, playback negotiation, scoped transcode, 204 check-ins and terminal reporter");
    }
}
