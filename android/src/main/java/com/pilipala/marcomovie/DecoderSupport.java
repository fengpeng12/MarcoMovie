package com.pilipala.marcomovie;

import androidx.media3.common.C;
import androidx.media3.decoder.ffmpeg.FfmpegLibrary;
import androidx.media3.decoder.av1.Gav1Library;
import androidx.media3.decoder.vp9.VpxLibrary;
import org.json.JSONObject;

/** Runtime capability checks: a packaged library is not assumed to have loaded. */
final class DecoderSupport {
    private static boolean configured;

    static synchronized void configure() {
        if (configured) return;
        // Our pinned build statically links libvpx into its JNI bridge.
        VpxLibrary.setLibraries(C.CRYPTO_TYPE_UNSUPPORTED, "vpxV2JNI");
        configured = true;
    }

    static JSONObject capabilities() {
        configure();
        JSONObject result = new JSONObject();
        try {
            result.put("ffmpeg", FfmpegLibrary.isAvailable());
            result.put("ffmpeg_version", String.valueOf(FfmpegLibrary.getVersion()));
            result.put("av1", Gav1Library.isAvailable());
            result.put("vp9", VpxLibrary.isAvailable());
            result.put("vpx_version", String.valueOf(VpxLibrary.getVersion()));
            JSONObject audio = new JSONObject();
            for (String mime :
                    new String[] {
                        "audio/ac3",
                        "audio/eac3",
                        "audio/vnd.dts",
                        "audio/vnd.dts.hd",
                        "audio/true-hd",
                        "audio/flac",
                        "audio/opus",
                        "audio/alac",
                        "audio/mp4a-latm"
                    }) audio.put(mime, FfmpegLibrary.supportsFormat(mime));
            result.put("audio", audio);
        } catch (LinkageError | Exception error) {
            try {
                result.put("error", error.getClass().getSimpleName());
            } catch (Exception ignored) {
            }
        }
        return result;
    }

    static String description() {
        JSONObject c = capabilities();
        return "FFmpeg 音频扩展："
                + (c.optBoolean("ffmpeg") ? "已就绪 · " + c.optString("ffmpeg_version") : "未能加载")
                + "\nAV1 视频软解码："
                + (c.optBoolean("av1") ? "已就绪" : "未能加载")
                + "\nVP9 视频软解码："
                + (c.optBoolean("vp9") ? "已就绪 · " + c.optString("vpx_version") : "未能加载")
                + "\n\n默认优先使用电视解码能力。扩展用于补充兼容性；高分辨率软解码可能较慢。H.264、H.265 仍使用设备提供的解码器。系统播放器不使用这些扩展。";
    }
}
