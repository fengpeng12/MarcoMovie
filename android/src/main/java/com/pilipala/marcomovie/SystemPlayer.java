package com.pilipala.marcomovie;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaFormat;
import android.media.MediaPlayer;
import android.media.PlaybackParams;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;
import androidx.media3.common.text.Cue;
import androidx.media3.common.text.CueGroup;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Optional Android system backend. It owns no ExoPlayer instance or public files. */
public final class SystemPlayer extends MoviePlayer {
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private final List<File> captionFiles = new ArrayList<>();
    private final Set<Integer> externalTracks = new HashSet<>();
    private MediaPlayer nativePlayer;
    private OnPreparedListener preparedListener;
    private OnCompletionListener completionListener;
    private OnVideoSizeChangedListener sizeListener;
    private OnErrorListener errorListener;
    private SubtitleListener subtitleListener;
    private CueListener cueListener;
    private boolean prepared, focusHeld;
    private volatile boolean released;
    private int width, height, captionVersion;
    private float speed = 1;
    private volatile String lastError = "";
    private Uri mediaUri;
    private Map<String, String> headers = Collections.emptyMap();
    private JSONObject options = new JSONObject();
    private final AudioManager.OnAudioFocusChangeListener focusChange =
            change -> {
                if (released || nativePlayer == null) return;
                if (change == AudioManager.AUDIOFOCUS_LOSS
                        || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) pause();
                else if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
                    onMain(
                            () -> {
                                if (!released) nativePlayer.setVolume(.2f, .2f);
                                return null;
                            });
                else if (change == AudioManager.AUDIOFOCUS_GAIN)
                    onMain(
                            () -> {
                                if (!released) nativePlayer.setVolume(1, 1);
                                return null;
                            });
            };

    public SystemPlayer(Context host) {
        super(host, false);
        context = host.getApplicationContext();
        audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        onMain(
                () -> {
                    nativePlayer = new MediaPlayer();
                    nativePlayer.setOnPreparedListener(
                            player -> {
                                if (released) return;
                                prepared = true;
                                if (preparedListener != null)
                                    preparedListener.onPrepared(SystemPlayer.this);
                                JSONArray tracks = options.optJSONArray("subtitles");
                                if (tracks != null)
                                    for (int i = 0; i < tracks.length(); i++) {
                                        JSONObject track = tracks.optJSONObject(i);
                                        if (track == null || track.optString("url").isEmpty())
                                            continue;
                                        try {
                                            addExternalSubtitle(
                                                    Uri.parse(track.optString("url")),
                                                    track.optString("name", "外挂字幕"),
                                                    MediaOptions.subtitleMime(
                                                            track.optString("url"),
                                                            track.optString("mimeType")));
                                        } catch (RuntimeException unsupported) {
                                            lastError = "系统播放器仅支持外挂SRT字幕；其他格式请选择Media3";
                                        }
                                    }
                            });
                    nativePlayer.setOnCompletionListener(
                            player -> {
                                if (!released && completionListener != null)
                                    completionListener.onCompletion(SystemPlayer.this);
                            });
                    nativePlayer.setOnVideoSizeChangedListener(
                            (player, w, h) -> {
                                if (released) return;
                                width = w;
                                height = h;
                                if (sizeListener != null)
                                    sizeListener.onVideoSizeChanged(SystemPlayer.this, w, h);
                            });
                    nativePlayer.setOnErrorListener(
                            (player, what, extra) -> {
                                if (released) return true;
                                prepared = false;
                                lastError = "SYSTEM_" + what + "_" + extra;
                                return errorListener == null
                                        || errorListener.onError(SystemPlayer.this, what, extra);
                            });
                    nativePlayer.setOnTimedTextListener(
                            (player, text) -> {
                                if (!released) caption(text == null ? "" : text.getText());
                            });
                    if (Build.VERSION.SDK_INT >= 28) Api28SubtitleHelper.attach(this);
                    return null;
                });
    }

    private static final class Api28SubtitleHelper {
        static void attach(final SystemPlayer owner) {
            owner.nativePlayer.setOnSubtitleDataListener(
                    (player, data) -> {
                        if (owner.released || data == null) return;
                        MediaPlayer.TrackInfo[] tracks = player.getTrackInfo();
                        int index = data.getTrackIndex();
                        if (index < 0 || index >= tracks.length) return;
                        String mime = owner.mime(tracks[index]);
                        if (!textMime(mime)) return;
                        String text = new String(data.getData(), StandardCharsets.UTF_8);
                        owner.caption(plainCaption(text));
                        int version = owner.captionVersion;
                        owner.main.postDelayed(
                                () -> {
                                    if (!owner.released
                                            && owner.prepared
                                            && version == owner.captionVersion) owner.caption("");
                                },
                                Math.max(100, data.getDurationUs() / 1000));
                    },
                    owner.main);
        }
    }

    @Override
    public void setAudioAttributes(AudioAttributes attributes) {
        onMain(
                () -> {
                    check();
                    nativePlayer.setAudioAttributes(attributes);
                    return null;
                });
    }

    @Override
    public void setDataSource(Context ignored, Uri uri, Map<String, String> requestHeaders) {
        onMain(
                () -> {
                    check();
                    mediaUri = uri;
                    headers = Collections.unmodifiableMap(new LinkedHashMap<>(requestHeaders));
                    nativePlayer.setDataSource(context, uri, headers);
                    return null;
                });
    }

    @Override
    public void setSurface(Surface surface) {
        onMain(
                () -> {
                    check();
                    nativePlayer.setSurface(surface);
                    return null;
                });
    }

    @Override
    public void setOnPreparedListener(OnPreparedListener listener) {
        onMain(
                () -> {
                    preparedListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnCompletionListener(OnCompletionListener listener) {
        onMain(
                () -> {
                    completionListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnVideoSizeChangedListener(OnVideoSizeChangedListener listener) {
        onMain(
                () -> {
                    sizeListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnErrorListener(OnErrorListener listener) {
        onMain(
                () -> {
                    errorListener = listener;
                    return null;
                });
    }

    @Override
    public void setSubtitleListener(SubtitleListener listener) {
        onMain(
                () -> {
                    subtitleListener = listener;
                    return null;
                });
    }

    @Override
    public void setCuesListener(CueListener listener) {
        onMain(
                () -> {
                    cueListener = listener;
                    return null;
                });
    }

    @Override
    public void setOptions(JSONObject metadata) {
        onMain(
                () -> {
                    check();
                    options = new JSONObject(metadata.toString());
                    JSONObject drm = options.optJSONObject("drm");
                    String scheme =
                            drm == null
                                    ? options.optString("drmScheme")
                                    : drm.optString("scheme", drm.optString("type"));
                    if (!scheme.isEmpty()) throw new IllegalArgumentException("此DRM来源请使用Media3播放器");
                    return null;
                });
    }

    @Override
    public void prepareAsync() {
        onMain(
                () -> {
                    check();
                    nativePlayer.prepareAsync();
                    return null;
                });
    }

    @Override
    public void start() {
        onMain(
                () -> {
                    check();
                    if (audio != null && !focusHeld)
                        focusHeld =
                                audio.requestAudioFocus(
                                                focusChange,
                                                AudioManager.STREAM_MUSIC,
                                                AudioManager.AUDIOFOCUS_GAIN)
                                        == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
                    nativePlayer.start();
                    return null;
                });
    }

    @Override
    public void pause() {
        onMain(
                () -> {
                    if (!released && prepared && nativePlayer.isPlaying()) nativePlayer.pause();
                    return null;
                });
    }

    @Override
    public void seekTo(int position) {
        onMain(
                () -> {
                    check();
                    if (prepared) nativePlayer.seekTo(Math.max(0, position));
                    caption("");
                    return null;
                });
    }

    @Override
    public boolean isPlaying() {
        return onMain(() -> !released && prepared && nativePlayer.isPlaying());
    }

    @Override
    public int getCurrentPosition() {
        return onMain(
                () -> released || !prepared ? 0 : Math.max(0, nativePlayer.getCurrentPosition()));
    }

    @Override
    public int getDuration() {
        return onMain(() -> released || !prepared ? 0 : Math.max(0, nativePlayer.getDuration()));
    }

    @Override
    public String videoResolution() {
        return onMain(
                () -> !released && width > 0 && height > 0 ? width + " × " + height : "分辨率未知");
    }

    @Override
    public int getVideoWidth() {
        return onMain(() -> released ? 0 : width);
    }

    @Override
    public int getVideoHeight() {
        return onMain(() -> released ? 0 : height);
    }

    @Override
    public int getAudioSessionId() {
        return onMain(() -> released ? 0 : nativePlayer.getAudioSessionId());
    }

    @Override
    public String getLastError() {
        return onMain(() -> lastError);
    }

    @Override
    public String getFailureMessage(int code) {
        return "系统播放器无法播放。可切换到 Media3 尝试内置解码扩展，或刷新线路。";
    }

    @Override
    public String playbackInfo() {
        return "Android 系统播放器\n"
                + getVideoWidth()
                + " × "
                + getVideoHeight()
                + "\n系统管理解码器，不使用应用的 FFmpeg、AV1、VP9 扩展。";
    }

    @Override
    public JSONObject decoderDiagnostics() {
        return new JSONObject();
    }

    @Override
    public void setSpeed(float value) {
        onMain(
                () -> {
                    check();
                    if (value < .25f || value > 3) throw new IllegalArgumentException("不支持的播放速度");
                    if (prepared) {
                        boolean wasPlaying = nativePlayer.isPlaying();
                        nativePlayer.setPlaybackParams(new PlaybackParams().setSpeed(value));
                        if (!wasPlaying && nativePlayer.isPlaying()) nativePlayer.pause();
                    }
                    speed = value;
                    return null;
                });
    }

    @Override
    public float getSpeed() {
        return onMain(() -> speed);
    }

    @Override
    public void setRepeatOne(boolean repeat) {
        onMain(
                () -> {
                    check();
                    nativePlayer.setLooping(repeat);
                    return null;
                });
    }

    private List<Integer> tracks(int type) {
        List<Integer> matching = new ArrayList<>();
        if (!prepared) return matching;
        MediaPlayer.TrackInfo[] info = nativePlayer.getTrackInfo();
        for (int i = 0; i < info.length; i++) {
            int nativeType = info[i].getTrackType();
            if (type == 1 && nativeType == MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_AUDIO)
                matching.add(i);
            else if (type == 3
                    && (nativeType == MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT
                            || nativeType == MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_SUBTITLE)
                    && textMime(mime(info[i]))) matching.add(i);
        }
        return matching;
    }

    private static String mime(MediaPlayer.TrackInfo track) {
        try {
            MediaFormat format = track.getFormat();
            return format == null ? "" : format.getString(MediaFormat.KEY_MIME);
        } catch (Exception unavailable) {
            return "";
        }
    }

    private static boolean textMime(String mime) {
        return mime != null
                && (mime.startsWith("text/")
                        || mime.equals("application/x-subrip")
                        || mime.equals("application/ttml+xml")
                        || mime.equals("application/x-quicktime-tx3g"));
    }

    @Override
    public List<String> trackLabels(int type) {
        return onMain(
                () -> {
                    check();
                    List<String> labels = new ArrayList<>();
                    MediaPlayer.TrackInfo[] info =
                            prepared ? nativePlayer.getTrackInfo() : new MediaPlayer.TrackInfo[0];
                    for (int index : tracks(type)) {
                        MediaPlayer.TrackInfo track = info[index];
                        String language = track.getLanguage();
                        if (language == null || language.equals("und"))
                            language = type == 1 ? "音轨" : "字幕";
                        String label = language + " " + (labels.size() + 1);
                        if (externalTracks.contains(index)) label = "外挂SRT · " + language;
                        int selected = nativePlayer.getSelectedTrack(track.getTrackType());
                        labels.add((selected == index ? "✓ " : "") + label);
                    }
                    return labels;
                });
    }

    @Override
    public void selectTrack(int type, int index) {
        onMain(
                () -> {
                    check();
                    List<Integer> matching = tracks(type);
                    if (index == -2 && type == 3) {
                        for (int nativeType :
                                new int[] {
                                    MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT,
                                    MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_SUBTITLE
                                }) {
                            int selected = nativePlayer.getSelectedTrack(nativeType);
                            if (selected >= 0) nativePlayer.deselectTrack(selected);
                        }
                        caption("");
                        return null;
                    }
                    int chosen = index == -1 ? 0 : index;
                    if (chosen < 0 || chosen >= matching.size()) return null;
                    nativePlayer.selectTrack(matching.get(chosen));
                    return null;
                });
    }

    @Override
    public void addExternalSubtitle(Uri uri, String name, String declaredMime) {
        String type = MediaOptions.subtitleMime(uri.toString(), declaredMime);
        if (!"application/x-subrip".equals(type))
            throw new IllegalArgumentException("系统播放器仅支持外挂SRT字幕；请选择Media3播放其他字幕格式");
        onMain(
                () -> {
                    check();
                    if (!prepared) throw new IllegalStateException("请等待视频开始播放");
                    return null;
                });
        Thread load =
                new Thread(
                        () -> {
                            File file = null;
                            boolean posted = false;
                            try {
                                file =
                                        File.createTempFile(
                                                "movie-subtitle-", ".srt", context.getCacheDir());
                                try (InputStream in = subtitleInput(uri);
                                        OutputStream out = new FileOutputStream(file)) {
                                    byte[] buffer = new byte[8192];
                                    int total = 0, n;
                                    while ((n = in.read(buffer)) != -1) {
                                        if (released)
                                            throw new InterruptedIOException("Player released");
                                        total += n;
                                        if (total > 2 * 1024 * 1024)
                                            throw new IOException("字幕文件超过2MiB");
                                        out.write(buffer, 0, n);
                                    }
                                }
                                final File ready = file;
                                posted =
                                        main.post(
                                                () -> {
                                                    if (released || !prepared) {
                                                        ready.delete();
                                                        return;
                                                    }
                                                    try {
                                                        int before =
                                                                nativePlayer.getTrackInfo().length;
                                                        nativePlayer.addTimedTextSource(
                                                                ready.getAbsolutePath(),
                                                                MediaPlayer
                                                                        .MEDIA_MIMETYPE_TEXT_SUBRIP);
                                                        captionFiles.add(ready);
                                                        MediaPlayer.TrackInfo[] tracks =
                                                                nativePlayer.getTrackInfo();
                                                        for (int i = before; i < tracks.length; i++)
                                                            if (tracks[i].getTrackType()
                                                                    == MediaPlayer.TrackInfo
                                                                            .MEDIA_TRACK_TYPE_TIMEDTEXT) {
                                                                externalTracks.add(i);
                                                                nativePlayer.selectTrack(i);
                                                                break;
                                                            }
                                                    } catch (Exception unsupported) {
                                                        ready.delete();
                                                        lastError =
                                                                "外挂SRT字幕加载失败："
                                                                        + unsupported
                                                                                .getClass()
                                                                                .getSimpleName();
                                                    }
                                                });
                            } catch (Exception error) {
                                lastError = "外挂SRT字幕读取失败：" + error.getClass().getSimpleName();
                            } finally {
                                if (!posted && file != null) file.delete();
                            }
                        },
                        "system-subtitle-load");
        load.setDaemon(true);
        load.start();
    }

    private InputStream subtitleInput(Uri uri) throws IOException {
        String scheme = uri.getScheme();
        if ("content".equalsIgnoreCase(scheme) || "file".equalsIgnoreCase(scheme)) {
            InputStream in = context.getContentResolver().openInputStream(uri);
            if (in == null) throw new FileNotFoundException("字幕文件无法读取");
            return in;
        }
        if (!"https".equalsIgnoreCase(scheme) && !"http".equalsIgnoreCase(scheme))
            throw new IOException("字幕地址不受支持");
        URL next = new URL(uri.toString());
        Map<String, String> request = new LinkedHashMap<>();
        for (Map.Entry<String, String> item : headers.entrySet())
            if (item.getKey().equalsIgnoreCase("User-Agent")
                    || item.getKey().equalsIgnoreCase("Referer")
                    || (mediaUri != null && Objects.equals(mediaUri.getHost(), uri.getHost())))
                request.put(item.getKey(), item.getValue());
        for (int i = 0; i < 6; i++) {
            HttpURLConnection connection = (HttpURLConnection) next.openConnection();
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(15000);
            connection.setInstanceFollowRedirects(false);
            for (Map.Entry<String, String> item : request.entrySet())
                connection.setRequestProperty(item.getKey(), item.getValue());
            int code = connection.getResponseCode();
            if (code >= 300 && code < 400) {
                String location = connection.getHeaderField("Location");
                if (location == null) {
                    connection.disconnect();
                    throw new IOException("字幕重定向缺少地址");
                }
                URL redirected = new URL(next, location);
                if (!redirected.getProtocol().equals("http")
                        && !redirected.getProtocol().equals("https")) {
                    connection.disconnect();
                    throw new IOException("字幕重定向协议不受支持");
                }
                if (!next.getHost().equalsIgnoreCase(redirected.getHost())) {
                    for (Iterator<String> it = request.keySet().iterator(); it.hasNext(); ) {
                        String key = it.next();
                        if (key.equalsIgnoreCase("Cookie")
                                || key.equalsIgnoreCase("Authorization")) {
                            it.remove();
                        }
                    }
                }
                connection.disconnect();
                next = redirected;
                continue;
            }
            if (code < 200 || code >= 300) {
                connection.disconnect();
                throw new IOException("字幕返回HTTP " + code);
            }
            InputStream in = connection.getInputStream();
            return new FilterInputStream(in) {
                @Override
                public void close() throws IOException {
                    try {
                        super.close();
                    } finally {
                        connection.disconnect();
                    }
                }
            };
        }
        throw new IOException("字幕重定向次数过多");
    }

    private static String plainCaption(String text) {
        StringBuilder out = new StringBuilder();
        for (String line : text.replace("\r", "").split("\n")) {
            String value = line.trim();
            if (value.isEmpty()
                    || value.equals("WEBVTT")
                    || value.matches("\\d+")
                    || value.contains("-->")
                    || value.startsWith("X-TIMESTAMP-MAP")) continue;
            if (out.length() > 0) out.append('\n');
            out.append(value.replaceAll("<[^>]+>", ""));
        }
        return out.toString();
    }

    private void caption(CharSequence text) {
        captionVersion++;
        if (subtitleListener != null) subtitleListener.text(text == null ? "" : text);
        if (cueListener != null) {
            List<Cue> cues =
                    text == null || text.length() == 0
                            ? Collections.emptyList()
                            : Collections.singletonList(new Cue.Builder().setText(text).build());
            cueListener.cues(new CueGroup(cues, 0));
        }
    }

    @Override
    public void release() {
        onMain(
                () -> {
                    if (released) return null;
                    released = true;
                    prepared = false;
                    nativePlayer.release();
                    if (audio != null && focusHeld) audio.abandonAudioFocus(focusChange);
                    focusHeld = false;
                    main.removeCallbacksAndMessages(null);
                    for (File file : captionFiles) file.delete();
                    captionFiles.clear();
                    caption("");
                    return null;
                });
    }

    private void check() {
        if (released) throw new IllegalStateException("Player released");
    }

    private <T> T onMain(Callable<T> work) {
        if (Looper.myLooper() == Looper.getMainLooper())
            try {
                return work.call();
            } catch (RuntimeException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        FutureTask<T> job = new FutureTask<>(work);
        if (!main.post(job)) throw new IllegalStateException("Main looper unavailable");
        try {
            return job.get(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Player call interrupted", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            throw new IllegalStateException(cause);
        } catch (TimeoutException e) {
            job.cancel(false);
            throw new IllegalStateException("Player UI thread timed out", e);
        }
    }
}
