package com.pilipala.marcomovie;

import android.content.res.ColorStateList;
import android.graphics.Paint;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.util.LruCache;
import android.view.View;
import android.view.ViewPropertyAnimator;
import android.view.Window;
import android.widget.EditText;
import android.widget.SeekBar;
import java.io.IOException;
import java.net.InetAddress;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Android 4.0+ (API 14+) runtime compatibility helpers shared by the standard and Lite builds.
 * Guards View, Window, LruCache, and TLS calls introduced after API 14.
 */
final class UiCompat {
    static final boolean IS_LEGACY_ANDROID = Build.VERSION.SDK_INT < 21;
    private static final AtomicInteger NEXT_VIEW_ID = new AtomicInteger(0x00100000);
    private static volatile boolean tlsInitialized;

    private UiCompat() {}

    static boolean equals(Object a, Object b) {
        return a == b || (a != null && a.equals(b));
    }

    static boolean isAttached(View view) {
        if (view == null) return false;
        if (Build.VERSION.SDK_INT >= 19) return view.isAttachedToWindow();
        return view.getWindowToken() != null;
    }

    static boolean isLaidOut(View view) {
        if (view == null) return false;
        if (Build.VERSION.SDK_INT >= 19) return view.isLaidOut();
        return view.getWidth() > 0 || view.getHeight() > 0;
    }

    @SuppressWarnings("deprecation")
    static void setBackground(View view, Drawable drawable) {
        if (view == null) return;
        if (Build.VERSION.SDK_INT >= 16) {
            view.setBackground(drawable);
        } else {
            view.setBackgroundDrawable(drawable);
        }
    }

    static void setClipToOutline(View view, boolean clipToOutline) {
        if (view != null && Build.VERSION.SDK_INT >= 21) {
            view.setClipToOutline(clipToOutline);
        }
    }

    static void setElevation(View view, float elevation) {
        if (view != null && Build.VERSION.SDK_INT >= 21) {
            if (view.getElevation() != elevation) {
                view.setElevation(elevation);
            }
        }
    }

    static int generateViewId() {
        if (Build.VERSION.SDK_INT >= 17) {
            return View.generateViewId();
        }
        for (; ; ) {
            int result = NEXT_VIEW_ID.get();
            int nextValue = result + 1;
            if (nextValue > 0x00FFFFFF) nextValue = 0x00100000;
            if (NEXT_VIEW_ID.compareAndSet(result, nextValue)) {
                return result;
            }
        }
    }

    static void setShowSoftInputOnFocus(EditText input, boolean show) {
        if (input != null && Build.VERSION.SDK_INT >= 21) {
            input.setShowSoftInputOnFocus(show);
        }
    }

    static void tintSeekBar(SeekBar bar, int progressColor, int thumbColor) {
        if (bar != null && Build.VERSION.SDK_INT >= 21) {
            bar.setProgressTintList(ColorStateList.valueOf(progressColor));
            bar.setThumbTintList(ColorStateList.valueOf(thumbColor));
        }
    }

    static void setWindowBarColors(Window window, Integer statusColor, Integer navColor) {
        if (window != null && Build.VERSION.SDK_INT >= 21) {
            try {
                if (statusColor != null) window.setStatusBarColor(statusColor);
                if (navColor != null) window.setNavigationBarColor(navColor);
            } catch (Throwable ignored) {
            }
        }
    }

    static void postOnAnimation(View view, Runnable action) {
        if (view == null || action == null) return;
        if (Build.VERSION.SDK_INT >= 16) {
            view.postOnAnimation(action);
        } else {
            view.postDelayed(action, 16);
        }
    }

    static void startWithEndAction(
            ViewPropertyAnimator animator, View hostView, long durationMs, Runnable endAction) {
        if (animator == null) return;
        if (Build.VERSION.SDK_INT >= 16) {
            animator.withEndAction(endAction).start();
        } else {
            animator.start();
            if (hostView != null && endAction != null) {
                hostView.postDelayed(endAction, Math.max(0L, durationMs));
            }
        }
    }

    static void setLayerPaint(View view, Paint paint) {
        if (view == null) return;
        if (Build.VERSION.SDK_INT >= 17) {
            view.setLayerPaint(paint);
        } else {
            view.setLayerType(
                    paint == null ? View.LAYER_TYPE_NONE : View.LAYER_TYPE_HARDWARE, paint);
        }
    }

    static void hideFromAccessibility(View view, boolean hideDescendants) {
        if (view != null && Build.VERSION.SDK_INT >= 16) {
            view.setImportantForAccessibility(
                    hideDescendants && Build.VERSION.SDK_INT >= 19
                            ? View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                            : View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        }
    }

    static <K, V> void trimCache(LruCache<K, V> cache, int maxSize) {
        if (cache == null) return;
        if (Build.VERSION.SDK_INT >= 17) {
            cache.trimToSize(maxSize);
        } else {
            cache.evictAll();
        }
    }

    static void enableLegacyTls12() {
        if (Build.VERSION.SDK_INT >= 21 || tlsInitialized) return;
        synchronized (UiCompat.class) {
            if (tlsInitialized) return;
            tlsInitialized = true;
            try {
                SSLContext context = SSLContext.getInstance("TLS");
                context.init(null, null, null);
                final SSLSocketFactory delegate = context.getSocketFactory();
                HttpsURLConnection.setDefaultSSLSocketFactory(
                        new SSLSocketFactory() {
                            @Override
                            public String[] getDefaultCipherSuites() {
                                return delegate.getDefaultCipherSuites();
                            }

                            @Override
                            public String[] getSupportedCipherSuites() {
                                return delegate.getSupportedCipherSuites();
                            }

                            @Override
                            public Socket createSocket(
                                    Socket s, String host, int port, boolean autoClose)
                                    throws IOException {
                                return enableTls(delegate.createSocket(s, host, port, autoClose));
                            }

                            @Override
                            public Socket createSocket(String host, int port) throws IOException {
                                return enableTls(delegate.createSocket(host, port));
                            }

                            @Override
                            public Socket createSocket(
                                    String host, int port, InetAddress localHost, int localPort)
                                    throws IOException {
                                return enableTls(
                                        delegate.createSocket(host, port, localHost, localPort));
                            }

                            @Override
                            public Socket createSocket(InetAddress host, int port)
                                    throws IOException {
                                return enableTls(delegate.createSocket(host, port));
                            }

                            @Override
                            public Socket createSocket(
                                    InetAddress address,
                                    int port,
                                    InetAddress localAddress,
                                    int localPort)
                                    throws IOException {
                                return enableTls(
                                        delegate.createSocket(
                                                address, port, localAddress, localPort));
                            }

                            private Socket enableTls(Socket socket) {
                                if (socket instanceof SSLSocket) {
                                    SSLSocket ssl = (SSLSocket) socket;
                                    String[] supported = ssl.getSupportedProtocols();
                                    if (supported != null) {
                                        List<String> enabled = new ArrayList<>();
                                        for (String p : supported) {
                                            if ("TLSv1.2".equals(p)
                                                    || "TLSv1.1".equals(p)
                                                    || "TLSv1".equals(p)) {
                                                enabled.add(p);
                                            }
                                        }
                                        if (!enabled.isEmpty()) {
                                            ssl.setEnabledProtocols(enabled.toArray(new String[0]));
                                        }
                                    }
                                }
                                return socket;
                            }
                        });
            } catch (Throwable ignored) {
            }
        }
    }
}
