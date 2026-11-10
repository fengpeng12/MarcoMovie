package com.github.catvod.crawler;
/** Host logging ABI. Avoid recording remote URLs, tokens or response bodies. */
public final class SpiderDebug {
    public static void log(String message){}
    public static void log(Throwable error){android.util.Log.w("SourceExtension",error.getClass().getName());}
    public static void log(Exception error){log((Throwable)error);}
}
