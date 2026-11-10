package com.pilipala.marcomovie;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Choreographer;
import java.util.ArrayList;

/** One UI-thread frame clock for emphasis, press and focus scrolling. */
final class MotionLoop {
    interface Step {
        boolean advance(float seconds);
    }

    private static final ArrayList<Step> active = new ArrayList<>(), frame = new ArrayList<>();
    private static boolean scheduled;
    private static long last;
    private static final Handler legacyHandler = new Handler(Looper.getMainLooper());
    private static final Runnable legacyTick = () -> tick(System.nanoTime());

    private static final class Api16Clock {
        private static final Choreographer.FrameCallback callback = MotionLoop::tick;

        static void post() {
            Choreographer.getInstance().postFrameCallback(callback);
        }

        static void remove() {
            Choreographer.getInstance().removeFrameCallback(callback);
        }
    }

    private static void scheduleNextFrame() {
        if (Build.VERSION.SDK_INT >= 16) {
            Api16Clock.post();
        } else {
            legacyHandler.postDelayed(legacyTick, 16);
        }
    }

    private static void cancelNextFrame() {
        if (Build.VERSION.SDK_INT >= 16) {
            Api16Clock.remove();
        } else {
            legacyHandler.removeCallbacks(legacyTick);
        }
    }

    static void add(Step step) {
        if (!active.contains(step)) active.add(step);
        if (!scheduled) {
            scheduled = true;
            last = 0;
            scheduleNextFrame();
        }
    }

    static void remove(Step step) {
        active.remove(step);
        if (active.isEmpty()) {
            cancelNextFrame();
            scheduled = false;
            last = 0;
        }
    }

    private static void tick(long time) {
        float dt = last == 0 ? 1f / 60 : Math.min(.05f, (time - last) / 1_000_000_000f);
        last = time;
        frame.clear();
        frame.addAll(active);
        for (Step step : frame) if (active.contains(step) && !step.advance(dt)) active.remove(step);
        frame.clear();
        if (active.isEmpty()) {
            scheduled = false;
            last = 0;
        } else scheduleNextFrame();
    }
}
