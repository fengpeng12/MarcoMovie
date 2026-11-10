package com.pilipala.marcomovie;

/**
 * Remote-key timeline preview and touch-drag gesture math for seek, brightness, and volume
 * controls.
 */
final class SeekGesture {
    static final int TAP_MS = 15000, HOLD_DELAY_MS = 500;
    static final int BASE_SPEED = 30, ACCELERATION = 30, MAX_SPEED = 240;
    static final int RAMP_MS = (MAX_SPEED - BASE_SPEED) * 1000 / ACCELERATION;
    static final int MODE_NONE = 0, MODE_SEEK = 1, MODE_BRIGHTNESS = 2, MODE_VOLUME = 3;
    boolean active;
    int direction, target, duration, initialTarget;
    long started, updated;

    static int classifyDrag(float dx, float dy, float startX, float width, float touchSlop) {
        if (Math.abs(dx) < touchSlop && Math.abs(dy) < touchSlop) return MODE_NONE;
        if (Math.abs(dx) >= Math.abs(dy) * 1.15f) return MODE_SEEK;
        if (Math.abs(dy) > Math.abs(dx)) {
            return startX < width * 0.5f ? MODE_BRIGHTNESS : MODE_VOLUME;
        }
        return MODE_NONE;
    }

    static int dragSeekTarget(int startPositionMs, int durationMs, float dx, float width) {
        if (durationMs <= 0 || width <= 0) return 0;
        int span = Math.max(60000, Math.min(300000, durationMs / 5));
        long delta = Math.round((dx / width) * span);
        return (int) Math.max(0L, Math.min(durationMs, (long) startPositionMs + delta));
    }

    /**
     * Computes a linear seek speed multiplier from horizontal swipe speed (pixels per second
     * normalized by screen width). Slow drags scrub finely (~0.75x) while faster swipes scale
     * linearly up to 4.5x.
     */
    static float linearSeekSpeedMultiplier(float velocityPxPerSec, float width) {
        if (width <= 0f) return 1f;
        float screensPerSec = Math.abs(velocityPxPerSec) / width;
        return Math.max(0.75f, Math.min(4.5f, 0.75f + 1.5f * screensPerSec));
    }

    static int stepLinearSeekTarget(
            int currentTargetMs,
            int durationMs,
            float stepDx,
            float velocityPxPerSec,
            float width) {
        if (durationMs <= 0 || width <= 0) return 0;
        int baseSpan = Math.max(60000, Math.min(300000, durationMs / 5));
        float speedMul = linearSeekSpeedMultiplier(velocityPxPerSec, width);
        long delta = Math.round((stepDx / width) * baseSpan * speedMul);
        return (int) Math.max(0L, Math.min(durationMs, (long) currentTargetMs + delta));
    }

    static float dragVerticalLevel(float startLevel, float dy, float height) {
        float clampedStart = Math.max(0f, Math.min(1f, startLevel));
        if (height <= 0) return clampedStart;
        return Math.max(0f, Math.min(1f, clampedStart - dy / (height * 0.65f)));
    }

    void begin(int direction, int position, int duration, long now) {
        this.direction = direction < 0 ? -1 : 1;
        this.duration = Math.max(0, duration);
        initialTarget = target = bound((long) position + this.direction * TAP_MS);
        started = updated = now;
        active = duration > 0;
    }

    void advance(long now) {
        if (!active || now <= updated) return;
        long elapsed = Math.max(0, now - started - HOLD_DELAY_MS);
        double ramp = Math.min(elapsed, RAMP_MS);
        // Integrate a linear speed ramp from the initial preview position. Absolute
        // elapsed time avoids dependence on remote repeat rate or callback jitter.
        double distance =
                BASE_SPEED * ramp
                        + ACCELERATION * ramp * ramp / 2000.0
                        + MAX_SPEED * (double) Math.max(0, elapsed - RAMP_MS);
        long delta = Math.min(duration, Math.round(distance));
        target = bound((long) initialTarget + direction * delta);
        updated = now;
    }

    boolean accelerated(long now) {
        return active && now - started > HOLD_DELAY_MS;
    }

    int speed(long now) {
        if (!active || now - started <= HOLD_DELAY_MS) return 0;
        long ramp = Math.min(RAMP_MS, Math.max(0, now - started - HOLD_DELAY_MS));
        return BASE_SPEED + (int) (ACCELERATION * ramp / 1000);
    }

    int bound(long value) {
        return (int) Math.max(0, Math.min(duration, value));
    }

    void cancel() {
        active = false;
    }
}
