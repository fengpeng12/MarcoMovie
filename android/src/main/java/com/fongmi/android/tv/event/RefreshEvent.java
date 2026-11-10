package com.fongmi.android.tv.event;

import com.pilipala.marcomovie.CspEngine;

/**
 * Host callback ABI expected by third-party CatVod / FongMi JAR spiders (such as 饭太硬, 王二小,
 * LeoDanmaku, WoGGGuard, Pan, etc.) that asynchronously push resolved danmaku or subtitle URLs via
 * {@code com.fongmi.android.tv.event.RefreshEvent.danmaku(String)} on a background thread after
 * {@code playerContent} returns.
 */
public final class RefreshEvent {
    public RefreshEvent() {}

    public static void danmaku(String path) {
        CspEngine.onPluginDanmaku(path);
    }

    public static void subtitle(String path) {
        CspEngine.onPluginSubtitle(path);
    }

    public static void video() {}

    public static void detail() {}

    public static void player() {}

    public static void history() {}

    public static void config() {}
}
