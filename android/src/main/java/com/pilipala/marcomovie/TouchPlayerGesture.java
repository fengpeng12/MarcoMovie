package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.media.AudioManager;
import android.os.SystemClock;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Locale;

/**
 * Touch gesture controller for phone and tablet playback: single-tap controls toggle, double-tap
 * play/pause, long-press 2.0x speed boost, horizontal swipe seek with linear velocity scaling and
 * live progress bar, left-side brightness swipe, and right-side volume swipe.
 */
final class TouchPlayerGesture implements View.OnTouchListener {
    private final MainActivity a;
    private final GestureDetector detector;
    private final LinearLayout hudCard;
    private final TextView hud;
    private final SeekProgressBarView hudProgress;
    private final float touchSlop;
    private float downX, downY, lastX;
    private long lastMoveTimeMs;
    private VelocityTracker velocityTracker;
    private int dragMode = SeekGesture.MODE_NONE;
    private int startPositionMs, durationMs, targetSeekMs;
    private float startBrightness = 0.5f;
    private float startVolume = 0.5f;
    private float savedSpeed = 1.0f;
    private boolean speedBoosting;
    private boolean startedInsideDock;

    static final class SeekProgressBarView extends View {
        private final MainActivity a;
        private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();
        private float progressFraction = 0f;

        SeekProgressBarView(MainActivity activity) {
            super(activity);
            this.a = activity;
            trackPaint.setColor(0x38ffffff);
            fillPaint.setColor(0xff34d399);
        }

        void setProgressFraction(float fraction) {
            float clamped = Math.max(0f, Math.min(1f, fraction));
            if (Math.abs(clamped - progressFraction) > 0.002f) {
                progressFraction = clamped;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            float r = h / 2f;
            rect.set(0, 0, w, h);
            canvas.drawRoundRect(rect, r, r, trackPaint);
            float fillW = Math.max(h, w * progressFraction);
            rect.set(0, 0, Math.min(w, fillW), h);
            canvas.drawRoundRect(rect, r, r, fillPaint);
        }
    }

    private TouchPlayerGesture(MainActivity activity) {
        this.a = activity;
        this.touchSlop = ViewConfiguration.get(activity).getScaledTouchSlop();
        this.hudCard = activity.vertical();
        this.hudCard.setGravity(Gravity.CENTER_HORIZONTAL);
        this.hudCard.setPadding(activity.dp(18), activity.dp(10), activity.dp(18), activity.dp(10));
        UiCompat.setBackground(this.hudCard, activity.bg(0xdc181d1b, 20));
        this.hudCard.setVisibility(View.GONE);

        this.hud = activity.text("", 13.5f, MainActivity.WHITE);
        this.hud.setTag("player-touch-hud");
        this.hud.setGravity(Gravity.CENTER);
        this.hudCard.addView(this.hud, new LinearLayout.LayoutParams(-2, -2));

        this.hudProgress = new SeekProgressBarView(activity);
        this.hudProgress.setVisibility(View.GONE);
        LinearLayout.LayoutParams barLp =
                new LinearLayout.LayoutParams(activity.dp(190), activity.dp(5));
        barLp.topMargin = activity.dp(7);
        this.hudCard.addView(this.hudProgress, barLp);

        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        lp.topMargin = activity.dp(36);
        activity.playbackLayer.addView(this.hudCard, lp);

        this.detector =
                new GestureDetector(
                        activity,
                        new GestureDetector.SimpleOnGestureListener() {
                            @Override
                            public boolean onDown(MotionEvent e) {
                                return true;
                            }

                            @Override
                            public boolean onSingleTapConfirmed(MotionEvent e) {
                                if (a.miniMode) {
                                    a.expandPlayback();
                                    return true;
                                }
                                a.showControls(!a.controlsVisible);
                                return true;
                            }

                            @Override
                            public boolean onDoubleTap(MotionEvent e) {
                                if (a.miniMode) return false;
                                a.togglePlayback();
                                a.showControls(true);
                                return true;
                            }

                            @Override
                            public void onLongPress(MotionEvent e) {
                                if (a.miniMode
                                        || a.isLive()
                                        || dragMode != SeekGesture.MODE_NONE
                                        || a.player == null
                                        || !a.prepared
                                        || !a.playing) return;
                                try {
                                    savedSpeed = a.player.getSpeed();
                                    a.player.setSpeed(2.0f);
                                    speedBoosting = true;
                                    showHud("2.0× 倍速播放中 · 松手恢复", -1f);
                                } catch (Exception ignored) {
                                }
                            }
                        });
    }

    static void attach(MainActivity activity, View surfaceView) {
        TouchPlayerGesture listener = new TouchPlayerGesture(activity);
        activity.root.setOnTouchListener(listener);
    }

    private void showHud(String text, float progressFraction) {
        hud.setText(text);
        if (progressFraction >= 0f) {
            hudProgress.setProgressFraction(progressFraction);
            hudProgress.setVisibility(View.VISIBLE);
        } else {
            hudProgress.setVisibility(View.GONE);
        }
        hudCard.setVisibility(View.VISIBLE);
    }

    private void hideHud() {
        hudCard.setVisibility(View.GONE);
        hudProgress.setVisibility(View.GONE);
    }

    private boolean isTouchInsideDock(float rawX, float rawY) {
        if (!a.controlsVisible || a.playerChrome == null || a.playerChrome.dock == null) {
            return false;
        }
        if (!a.playerChrome.dock.isShown()) return false;
        Rect r = new Rect();
        if (!a.playerChrome.dock.getGlobalVisibleRect(r)) return false;
        return r.contains(Math.round(rawX), Math.round(rawY));
    }

    @Override
    public boolean onTouch(View v, MotionEvent event) {
        if (a.miniMode) {
            return detector.onTouchEvent(event);
        }
        detector.onTouchEvent(event);
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            downX = lastX = event.getRawX();
            downY = event.getRawY();
            lastMoveTimeMs = SystemClock.uptimeMillis();
            startedInsideDock = isTouchInsideDock(downX, downY);
            dragMode = SeekGesture.MODE_NONE;
            if (velocityTracker == null) {
                velocityTracker = VelocityTracker.obtain();
            } else {
                velocityTracker.clear();
            }
            velocityTracker.addMovement(event);
            if (a.playbackControls != null) a.playbackControls.touchSeeking = false;
            if (a.player != null && a.prepared) {
                startPositionMs = a.player.getCurrentPosition();
                durationMs = a.player.getDuration();
                targetSeekMs = startPositionMs;
            }
            WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
            startBrightness =
                    attrs.screenBrightness >= 0f && attrs.screenBrightness <= 1f
                            ? attrs.screenBrightness
                            : 0.5f;
            AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
            if (audio != null) {
                int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
                int cur = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
                startVolume = cur / (float) max;
            }
            return true;
        }
        if (action == MotionEvent.ACTION_MOVE) {
            if (speedBoosting || startedInsideDock) return true;
            if (velocityTracker != null) velocityTracker.addMovement(event);
            float rawX = event.getRawX();
            float rawY = event.getRawY();
            float dx = rawX - downX;
            float dy = rawY - downY;
            float stepDx = rawX - lastX;
            long nowMs = SystemClock.uptimeMillis();
            long dtMs = Math.max(1L, nowMs - lastMoveTimeMs);
            lastX = rawX;
            lastMoveTimeMs = nowMs;

            int width = Math.max(1, a.windowWidth());
            int height = Math.max(1, a.windowHeight());
            if (dragMode == SeekGesture.MODE_NONE) {
                dragMode = SeekGesture.classifyDrag(dx, dy, downX, width, touchSlop);
                if (dragMode == SeekGesture.MODE_SEEK && (a.isLive() || durationMs <= 0)) {
                    dragMode = SeekGesture.MODE_NONE;
                }
                if (dragMode != SeekGesture.MODE_NONE && v.getParent() != null) {
                    v.getParent().requestDisallowInterceptTouchEvent(true);
                }
            }
            if (dragMode == SeekGesture.MODE_SEEK && a.player != null && a.prepared) {
                float vx = (stepDx * 1000f) / dtMs;
                if (velocityTracker != null) {
                    velocityTracker.computeCurrentVelocity(1000);
                    float trackedVx = velocityTracker.getXVelocity();
                    if (Math.abs(trackedVx) > 10f) vx = trackedVx;
                }
                float speedMul = SeekGesture.linearSeekSpeedMultiplier(vx, width);
                targetSeekMs =
                        SeekGesture.stepLinearSeekTarget(
                                targetSeekMs, durationMs, stepDx, vx, width);
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = true;
                    a.playbackControls.timeline.setProgress(targetSeekMs);
                }
                // Show bottom timeline progress bar in progress-only mode during touch seeking
                if (!a.controlsVisible) {
                    PlaybackController.showControls(a, true, true);
                }
                String speedText = String.format(Locale.US, "%.1f×", speedMul);
                if (a.playClock != null) {
                    a.playClock.setText(
                            PlaybackController.formatTime(targetSeekMs)
                                    + " / "
                                    + PlaybackController.formatTime(durationMs));
                }
                if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                    a.playerChrome.seekHint.setText(
                            (dx >= 0 ? "快进 " : "快退 ") + speedText + " · 松手跳转");
                    a.playerChrome.seekHint.setVisibility(View.VISIBLE);
                }
                float frac = durationMs > 0 ? (targetSeekMs / (float) durationMs) : 0f;
                showHud(
                        (dx >= 0 ? "快进至 " : "快退至 ")
                                + PlaybackController.formatTime(targetSeekMs)
                                + " / "
                                + PlaybackController.formatTime(durationMs)
                                + "  ·  "
                                + speedText,
                        frac);
            } else if (dragMode == SeekGesture.MODE_BRIGHTNESS) {
                float level = SeekGesture.dragVerticalLevel(startBrightness, dy, height);
                WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
                attrs.screenBrightness = Math.max(0.02f, level);
                a.getWindow().setAttributes(attrs);
                showHud("屏幕亮度 " + Math.round(level * 100) + "%", level);
            } else if (dragMode == SeekGesture.MODE_VOLUME) {
                float level = SeekGesture.dragVerticalLevel(startVolume, dy, height);
                AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
                if (audio != null) {
                    int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
                    int vol = Math.round(level * max);
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0);
                }
                showHud("媒体音量 " + Math.round(level * 100) + "%", level);
            }
            return true;
        }
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
            if (a.playbackControls != null) a.playbackControls.touchSeeking = false;
            if (speedBoosting) {
                speedBoosting = false;
                if (a.player != null && a.prepared) {
                    try {
                        a.player.setSpeed(savedSpeed);
                    } catch (Exception ignored) {
                    }
                }
                hideHud();
                return true;
            }
            if (dragMode == SeekGesture.MODE_SEEK && a.player != null && a.prepared) {
                if (a.playbackControls != null) {
                    a.playbackControls.recordUserSeek(targetSeekMs);
                }
                a.player.seekTo(targetSeekMs);
                if (a.playClock != null && durationMs > 0) {
                    a.playClock.setText(
                            PlaybackController.formatTime(targetSeekMs)
                                    + " / "
                                    + PlaybackController.formatTime(durationMs));
                }
                if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                    a.playerChrome.seekHint.setText("");
                    a.playerChrome.seekHint.setVisibility(View.GONE);
                }
                if (a.playerChrome != null && a.playerChrome.progressOnlyMode) {
                    a.showControls(false);
                } else {
                    a.scheduleHide();
                }
            }
            dragMode = SeekGesture.MODE_NONE;
            startedInsideDock = false;
            hideHud();
            return true;
        }
        return true;
    }
}
