package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Current-page playback feedback; never creates a navigation destination. */
final class PlaybackLoading extends FrameLayout {
    PlaybackLoading(MainActivity a) {
        super(a);
        setTag("playback-loading");
        setBackgroundColor(0x66000000);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClickable(true);
        LinearLayout pill = a.row();
        pill.setPadding(a.dp(24), a.dp(18), a.dp(24), a.dp(18));
        pill.setBackground(a.bg(0xf529292e, 24));
        pill.addView(new Ring(a), new LinearLayout.LayoutParams(a.dp(26), a.dp(26)));
        boolean inPlayer = a.current != null && a.current.player && !a.miniMode;
        String label =
                inPlayer
                                && a.activeEpisode != null
                                && a.activeEpisode.name != null
                                && !a.activeEpisode.name.isEmpty()
                        ? "正在加载 " + a.activeEpisode.name + "…"
                        : (a.isTvDevice() ? "正在加载播放信息…  返回取消" : "正在加载中…");
        TextView text = a.text(label, 14, MainActivity.WHITE);
        text.setPadding(a.dp(16), 0, 0, 0);
        pill.addView(text);
        addView(pill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
    }

    static final class Ring extends View {
        final Paint paint = new Paint(3);
        ValueAnimator animation;
        float angle;

        Ring(MainActivity a) {
            super(a);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(a.dp(2));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(MainActivity.WHITE);
        }

        protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            animation = ValueAnimator.ofFloat(0, 360);
            animation.setDuration(900);
            animation.setRepeatCount(-1);
            animation.setInterpolator(new android.view.animation.LinearInterpolator());
            animation.addUpdateListener(
                    v -> {
                        angle = (float) v.getAnimatedValue();
                        invalidate();
                    });
            animation.start();
        }

        protected void onDetachedFromWindow() {
            if (animation != null) {
                animation.removeAllUpdateListeners();
                animation.cancel();
                animation = null;
            }
            super.onDetachedFromWindow();
        }

        protected void onDraw(Canvas c) {
            super.onDraw(c);
            float inset = paint.getStrokeWidth();
            c.drawArc(
                    new RectF(inset, inset, getWidth() - inset, getHeight() - inset),
                    angle,
                    260,
                    false,
                    paint);
        }
    }
}
