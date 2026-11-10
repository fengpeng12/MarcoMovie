package com.pilipala.marcomovie;

import android.animation.*;
import android.graphics.*;
import android.view.*;
import android.view.animation.LinearInterpolator;
import android.widget.*;

/** Silent brand motion composed at the display's resolution, with no decoded video. */
final class StartupIntro extends FrameLayout {
    final MainActivity a;
    final BrandView artwork;
    ValueAnimator timeline;
    boolean closing, released, rendered;
    final Runnable timeout = () -> finish(false);

    static void show(MainActivity a) {
        if (a.reduced
                || !a.prefs.getBoolean(Prefs.STARTUP_ANIMATION, true)
                || a.startupIntro != null) return;
        StartupIntro intro = new StartupIntro(a);
        a.startupIntro = intro;
        ((FrameLayout) a.findViewById(android.R.id.content))
                .addView(intro, new FrameLayout.LayoutParams(-1, -1));
        intro.postDelayed(intro.timeout, 1500);
    }

    StartupIntro(MainActivity a) {
        super(a);
        this.a = a;
        setTag("startup-intro");
        setBackgroundColor(Color.BLACK);
        setClickable(true);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        artwork = new BrandView(a);
        addView(artwork, new FrameLayout.LayoutParams(-1, -1));
        setOnClickListener(v -> finish(true));
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        timeline = ValueAnimator.ofFloat(0, 1);
        timeline.setDuration(950);
        timeline.setInterpolator(new LinearInterpolator());
        timeline.addUpdateListener(
                v -> {
                    artwork.progress = (Float) v.getAnimatedValue();
                    artwork.invalidate();
                });
        timeline.addListener(
                new AnimatorListenerAdapter() {
                    public void onAnimationEnd(Animator animation) {
                        if (!closing) finish(true);
                    }
                });
        timeline.start();
    }

    void release() {
        if (released) return;
        released = true;
        if (timeline != null) {
            timeline.removeAllListeners();
            timeline.removeAllUpdateListeners();
            timeline.cancel();
            timeline = null;
        }
    }

    void finish(boolean fade) {
        if (closing) return;
        closing = true;
        removeCallbacks(timeout);
        release();
        if (fade && isAttachedToWindow() && !a.reduced) {
            animate().alpha(0).setDuration(160).withEndAction(this::remove).start();
        } else remove();
    }

    void remove() {
        animate().cancel();
        release();
        if (getParent() instanceof ViewGroup) ((ViewGroup) getParent()).removeView(this);
        if (a.startupIntro == this) a.startupIntro = null;
    }

    void cancel() {
        closing = true;
        removeCallbacks(timeout);
        remove();
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(timeout);
        animate().cancel();
        release();
        if (a.startupIntro == this) a.startupIntro = null;
        super.onDetachedFromWindow();
    }

    /** Preserve the owner's high-resolution logo; draw type directly at native size. */
    final class BrandView extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
        final Bitmap logo = BitmapFactory.decodeResource(getResources(), R.drawable.logo_mark);
        final RectF logoBounds = new RectF(-86, -86, 86, 86), plate = new RectF(-62, -59, 62, 60);
        final Path badge = new Path();
        final Shader light =
                new LinearGradient(
                        -45,
                        0,
                        45,
                        0,
                        new int[] {0x00ffffff, 0x66ffffff, 0x00ffffff},
                        null,
                        Shader.TileMode.CLAMP);
        final Matrix sweep = new Matrix();
        float progress;

        BrandView(MainActivity a) {
            super(a);
            setTag("startup-native-art");
            setFocusable(false);
            paint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            paint.setFilterBitmap(true);
            badge.addRoundRect(plate, 24, 24, Path.Direction.CW);
        }

        float reveal(float start, float duration) {
            float value = Math.max(0, Math.min(1, (progress - start) / duration));
            return 1 - (1 - value) * (1 - value) * (1 - value);
        }

        @Override
        protected void onDraw(Canvas c) {
            super.onDraw(c);
            if (getWidth() == 0) return;
            rendered = true;
            float unit = Math.min(getWidth() / 960f, getHeight() / 540f),
                    appear = reveal(0, .26f),
                    type = reveal(.13f, .22f);
            c.save();
            c.translate(getWidth() / 2f, getHeight() / 2f - 12 * unit);
            c.scale(unit, unit);
            c.save();
            c.translate(0, -33 + 8 * (1 - appear));
            float scale = .94f + .06f * appear;
            c.scale(scale, scale);
            paint.setStyle(Paint.Style.FILL);
            paint.setShader(null);
            paint.setAlpha(Math.round(255 * appear));
            c.drawBitmap(logo, null, logoBounds, paint);
            if (progress > .24f && progress < .65f) {
                c.save();
                c.clipPath(badge);
                sweep.setTranslate(-180 + (progress - .24f) / .41f * 360, 0);
                light.setLocalMatrix(sweep);
                paint.setShader(light);
                paint.setAlpha(Math.round(110 * appear));
                c.drawRect(plate, paint);
                paint.setShader(null);
                c.restore();
            }
            c.restore();
            paint.setColor(0xfff5f5f7);
            paint.setAlpha(Math.round(255 * type));
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTextSize(33);
            c.drawText("Marco Movie", 0, 87 + 5 * (1 - type), paint);
            paint.setColor(0xff9298a1);
            paint.setAlpha(Math.round(255 * type));
            paint.setTextSize(9);
            c.drawText("Y O U R   C I N E M A", 0, 109, paint);
            paint.setAlpha(255);
            c.restore();
        }
    }
}
