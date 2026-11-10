package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.FrameLayout;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Same-signed test APK only. Synthetic fixture URLs are passed by the operator. */
public final class DecoderProbe extends Instrumentation {
    Bundle args;
    MainActivity activity;
    MoviePlayer player;
    TextureView texture;
    Surface surface;
    final CountDownLatch launched = new CountDownLatch(1);

    @Override
    public void callActivityOnCreate(Activity a, Bundle state) {
        super.callActivityOnCreate(a, state);
        if (a instanceof MainActivity) {
            activity = (MainActivity) a;
            launched.countDown();
        }
    }

    @Override
    public void onCreate(Bundle input) {
        super.onCreate(input);
        args = input;
        start();
    }

    void report(String key, String value) {
        Bundle b = new Bundle();
        b.putString(key, value);
        sendStatus(0, b);
    }

    @Override
    public void onStart() {
        JSONObject result = new JSONObject();
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new IOException("Activity timeout");
            result.put("capabilities", DecoderSupport.capabilities());
            JSONArray cases = new JSONArray(read(args.getString("base") + "cases.json"));
            JSONArray outcomes = new JSONArray();
            result.put("cases", outcomes);
            boolean all = true;
            for (int i = 0; i < cases.length(); i++) {
                JSONObject spec = cases.getJSONObject(i),
                        item =
                                new JSONObject()
                                        .put("file", spec.getString("file"))
                                        .put("mode", spec.getInt("mode"));
                outcomes.put(item);
                try {
                    runCase(spec, item);
                    all &= item.optBoolean("passed");
                } catch (Throwable error) {
                    item.put("passed", false).put("exception", error.getClass().getSimpleName());
                    all = false;
                } finally {
                    if (player != null) {
                        player.release();
                        player = null;
                    }
                }
                report("case", item.toString());
            }
            result.put("passed", all);
        } catch (Throwable error) {
            try {
                result.put("error", error.getClass().getSimpleName() + ": " + error.getMessage());
            } catch (Exception ignored) {
            }
        } finally {
            if (player != null) player.release();
            if (surface != null) surface.release();
            if (activity != null)
                runOnMainSync(
                        () ->
                                activity.getWindow()
                                        .clearFlags(
                                                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON));
        }
        String encoded =
                android.util.Base64.encodeToString(
                        result.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8),
                        android.util.Base64.NO_WRAP);
        for (int n = 0; n < encoded.length(); n += 60000)
            report("result_part", encoded.substring(n, Math.min(n + 60000, encoded.length())));
        finish(Activity.RESULT_OK, new Bundle());
    }

    void freshSurface() throws Exception {
        CountDownLatch visible = new CountDownLatch(1);
        runOnMainSync(
                () -> {
                    if (surface != null) {
                        surface.release();
                        surface = null;
                    }
                    activity.releasePlayer();
                    activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    FrameLayout root = new FrameLayout(activity);
                    root.setBackgroundColor(Color.BLACK);
                    texture = new TextureView(activity);
                    root.addView(texture, new FrameLayout.LayoutParams(-1, -1));
                    activity.setContentView(root);
                    texture.setSurfaceTextureListener(
                            new TextureView.SurfaceTextureListener() {
                                public void onSurfaceTextureAvailable(
                                        SurfaceTexture value, int w, int h) {
                                    surface = new Surface(value);
                                    visible.countDown();
                                }

                                public void onSurfaceTextureSizeChanged(
                                        SurfaceTexture value, int w, int h) {}

                                public boolean onSurfaceTextureDestroyed(SurfaceTexture value) {
                                    return true;
                                }

                                public void onSurfaceTextureUpdated(SurfaceTexture value) {}
                            });
                });
        if (!visible.await(10, TimeUnit.SECONDS))
            throw new IOException("No visible output surface");
    }

    void runCase(JSONObject spec, JSONObject item) throws Exception {
        freshSurface();
        String filename = spec.getString("file");
        if (!filename.matches("[A-Za-z0-9.-]+")) throw new IOException("Invalid fixture filename");
        File file = new File(activity.getCacheDir(), "decoder-test-" + filename);
        HttpURLConnection c =
                (HttpURLConnection) new URL(args.getString("base") + filename).openConnection();
        c.setConnectTimeout(10000);
        c.setReadTimeout(10000);
        try (InputStream in = c.getInputStream();
                OutputStream out = new FileOutputStream(file)) {
            byte[] b = new byte[32768];
            int n;
            while ((n = in.read(b)) != -1) out.write(b, 0, n);
        } finally {
            c.disconnect();
        }
        android.content.SharedPreferences prefs = activity.getSharedPreferences("movie", 0);
        Map<String, Boolean> saved = new HashMap<>();
        Set<String> absent = new HashSet<>();
        for (String key : new String[] {"software_audio", "prefer_aac"})
            if (spec.has(key)) {
                if (prefs.contains(key)) saved.put(key, prefs.getBoolean(key, false));
                else absent.add(key);
                prefs.edit().putBoolean(key, spec.getBoolean(key)).commit();
            }
        try {
            player = new MoviePlayer(activity, spec.getInt("mode"));
            player.setSurface(surface);
            player.setAudioAttributes(
                    new android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build());
            player.setDataSource(activity, Uri.fromFile(file), Collections.emptyMap());
            CountDownLatch ready = new CountDownLatch(1);
            int[] failure = {0};
            player.setOnPreparedListener(
                    p -> {
                        p.start();
                        ready.countDown();
                    });
            player.setOnErrorListener(
                    (p, code, extra) -> {
                        failure[0] = code;
                        ready.countDown();
                        return true;
                    });
            player.prepareAsync();
            boolean prepared = ready.await(20, TimeUnit.SECONDS) && failure[0] == 0;
            item.put("prepared", prepared);
            if (!prepared) {
                item.put("error", player.getLastError()).put("passed", false);
                return;
            }
            int start = player.getCurrentPosition();
            SystemClock.sleep(2600);
            int end = player.getCurrentPosition();
            JSONObject info = player.decoderDiagnostics();
            item.put("decoder", info).put("advanced", end > start + 1400);
            Bitmap[] shot = {null};
            runOnMainSync(() -> shot[0] = texture.getBitmap(320, 180));
            Set<Integer> colors = new HashSet<>();
            if (shot[0] != null) {
                int[] pixels = new int[320 * 180];
                shot[0].getPixels(pixels, 0, 320, 0, 0, 320, 180);
                for (int j = 0; j < pixels.length; j += 17) colors.add(pixels[j]);
                if (spec.getInt("mode") == 2
                        && (filename.startsWith("av1") || filename.startsWith("vp9"))) {
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    shot[0].compress(Bitmap.CompressFormat.PNG, 100, bytes);
                    item.put(
                            "frame_base64",
                            android.util.Base64.encodeToString(
                                    bytes.toByteArray(), android.util.Base64.NO_WRAP));
                }
                shot[0].recycle();
            }
            item.put("frame_colors", colors.size());
            player.pause();
            SystemClock.sleep(200);
            int paused = player.getCurrentPosition();
            SystemClock.sleep(350);
            item.put("pause_stable", Math.abs(player.getCurrentPosition() - paused) < 150);
            player.setSpeed(1.25f);
            player.seekTo(7000);
            player.start();
            long limit = SystemClock.elapsedRealtime() + 7000;
            while (SystemClock.elapsedRealtime() < limit
                    && (player.getCurrentPosition() < 7500 || !player.isPlaying()))
                SystemClock.sleep(100);
            item.put("seek_resume", player.getCurrentPosition() >= 7500 && player.isPlaying())
                    .put("seek_position", player.getCurrentPosition());
            if (spec.has("audio_mime"))
                item.put(
                        "audio_preference",
                        spec.getString("audio_mime").equals(info.optString("audio_mime")));
            String audio = info.optString("audio_decoder").toLowerCase(Locale.ROOT),
                    video = info.optString("video_decoder").toLowerCase(Locale.ROOT);
            boolean expectedAudio = !spec.has("audio") || audio.contains(spec.getString("audio"));
            boolean expectedVideo =
                    !(spec.opt("video") instanceof String)
                            || video.contains(spec.getString("video"));
            item.put("expected_decoders", expectedAudio && expectedVideo);
            item.put("error", player.getLastError());
            item.put(
                    "passed",
                    item.getBoolean("advanced")
                            && item.getBoolean("pause_stable")
                            && item.getBoolean("seek_resume")
                            && colors.size() > 20
                            && info.optInt("audio_rendered") > 0
                            && info.optInt("video_rendered") > 0
                            && expectedAudio
                            && expectedVideo
                            && item.optBoolean("audio_preference", true)
                            && failure[0] == 0);
        } finally {
            file.delete();
            android.content.SharedPreferences.Editor edit = prefs.edit();
            for (Map.Entry<String, Boolean> entry : saved.entrySet())
                edit.putBoolean(entry.getKey(), entry.getValue());
            for (String key : absent) edit.remove(key);
            edit.commit();
        }
    }

    String read(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(10000);
        c.setReadTimeout(10000);
        try (InputStream in = c.getInputStream()) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] b = new byte[4096];
            int n;
            while ((n = in.read(b)) != -1) out.write(b, 0, n);
            return out.toString("UTF-8");
        } finally {
            c.disconnect();
        }
    }
}
