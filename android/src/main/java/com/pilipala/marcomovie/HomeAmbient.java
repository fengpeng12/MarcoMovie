package com.pilipala.marcomovie;

import android.animation.*;
import android.graphics.*;
import android.graphics.drawable.BitmapDrawable;
import android.util.LruCache;
import android.view.View;
import android.widget.ImageView;

/** Small cached color fields, crossfaded as textures rather than full-screen shaders. */
final class HomeAmbient extends View {
    final MainActivity a;
    final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    final LruCache<String, int[]> colors = new LruCache<>(48);
    final RectF destination = new RectF();
    ImageView wanted;
    Runnable pending;
    ValueAnimator animation;
    Bitmap from, to;
    float fraction = 1;
    int left = 0xff354553, right = 0xff403847;
    int applied;

    HomeAmbient(MainActivity host) {
        super(host);
        a = host;
        setTag("home-ambient");
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        to = field(left, right);
    }

    void follow(ImageView image) {
        if (wanted == image) return;
        wanted = image;
        posterReady(image);
    }

    void posterReady(ImageView image) {
        if (image != wanted) return;
        if (pending != null) removeCallbacks(pending);
        pending =
                () -> {
                    pending = null;
                    if (image != wanted
                            || !isAttachedToWindow()
                            || !(image.getDrawable() instanceof BitmapDrawable)) return;
                    Bitmap bitmap = ((BitmapDrawable) image.getDrawable()).getBitmap();
                    if (bitmap == null || bitmap.isRecycled()) return;
                    String key = String.valueOf(image.getTag());
                    int[] target = colors.get(key);
                    if (target == null) {
                        target = new int[] {sample(bitmap, 0), sample(bitmap, 1)};
                        colors.put(key, target);
                    }
                    transition(target[0], target[1]);
                };
        postDelayed(pending, a.reduced ? 0 : 160);
    }

    static int sample(Bitmap bitmap, int side) {
        double red = 0, green = 0, blue = 0, weight = 0;
        float[] hsv = new float[3];
        for (int y = 0; y < 20; y++)
            for (int x = 0; x < 12; x++) {
                int
                        px =
                                Math.min(
                                        bitmap.getWidth() - 1,
                                        (x * 2 + 1 + side * 24) * bitmap.getWidth() / 48),
                        py =
                                Math.min(
                                        bitmap.getHeight() - 1,
                                        (y * 2 + 1) * bitmap.getHeight() / 40);
                int c = bitmap.getPixel(px, py);
                Color.colorToHSV(c, hsv);
                if (Color.alpha(c) < 128 || hsv[2] < .12f || hsv[2] > .94f) continue;
                double w = .15 + hsv[1] * hsv[1];
                red += Color.red(c) * w;
                green += Color.green(c) * w;
                blue += Color.blue(c) * w;
                weight += w;
            }
        if (weight == 0) return side == 0 ? 0xff354553 : 0xff403847;
        Color.colorToHSV(
                Color.rgb((int) (red / weight), (int) (green / weight), (int) (blue / weight)),
                hsv);
        hsv[1] = Math.min(.48f, hsv[1] * .65f);
        hsv[2] = .25f;
        return Color.HSVToColor(hsv);
    }

    static int mix(int from, int to, float f) {
        return Color.rgb(
                Math.round(Color.red(from) + (Color.red(to) - Color.red(from)) * f),
                Math.round(Color.green(from) + (Color.green(to) - Color.green(from)) * f),
                Math.round(Color.blue(from) + (Color.blue(to) - Color.blue(from)) * f));
    }

    Bitmap field(int first, int second) {
        Bitmap b = Bitmap.createBitmap(240, 135, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(3);
        p.setShader(
                new LinearGradient(0, 0, 0, 135, 0xff191c22, 0xff101013, Shader.TileMode.CLAMP));
        c.drawRect(0, 0, 240, 135, p);
        p.setShader(
                new RadialGradient(
                        -240 * .08f,
                        135 * .2f,
                        240 * .8f,
                        new int[] {first, first & 0x00ffffff},
                        null,
                        Shader.TileMode.CLAMP));
        c.drawRect(0, 0, 240, 135, p);
        p.setShader(
                new RadialGradient(
                        240 * 1.02f,
                        135 * .7f,
                        240 * .65f,
                        new int[] {second, second & 0x00ffffff},
                        null,
                        Shader.TileMode.CLAMP));
        c.drawRect(0, 0, 240, 135, p);
        return b;
    }

    void cancelAnimation() {
        if (animation != null) {
            ValueAnimator old = animation;
            animation = null;
            old.removeAllUpdateListeners();
            old.removeAllListeners();
            old.cancel();
        }
    }

    void transition(int first, int second) {
        if (left == first && right == second) return;
        cancelAnimation();
        applied++;
        // Retarget from the displayed blend, including rapid remote moves.
        if (from != null && fraction < 1) {
            Bitmap blended = Bitmap.createBitmap(240, 135, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(blended);
            paint.setAlpha(255);
            c.drawBitmap(from, 0, 0, paint);
            paint.setAlpha(Math.round(255 * fraction));
            c.drawBitmap(to, 0, 0, paint);
            paint.setAlpha(255);
            from = blended;
        } else from = to;
        left = first;
        right = second;
        to = field(first, second);
        fraction = 0;
        if (a.reduced) {
            fraction = 1;
            from = null;
            invalidate();
            com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
            return;
        }
        animation = ValueAnimator.ofFloat(0, 1);
        animation.setDuration(650);
        animation.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
        animation.addUpdateListener(
                v -> {
                    fraction = (Float) v.getAnimatedValue();
                    invalidate();
                    com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
                });
        animation.addListener(
                new AnimatorListenerAdapter() {
                    public void onAnimationEnd(Animator animator) {
                        if (animation == animator) {
                            animation = null;
                            from = null;
                        }
                    }
                });
        animation.start();
    }

    @Override
    protected void onDraw(Canvas c) {
        destination.set(0, 0, getWidth(), getHeight());
        paint.setAlpha(255);
        if (from != null && fraction < 1) c.drawBitmap(from, null, destination, paint);
        paint.setAlpha(Math.round(255 * (from == null ? 1 : fraction)));
        if (to != null) c.drawBitmap(to, null, destination, paint);
        paint.setAlpha(255);
    }

    @Override
    protected void onDetachedFromWindow() {
        if (pending != null) removeCallbacks(pending);
        pending = null;
        cancelAnimation();
        wanted = null;
        from = null;
        super.onDetachedFromWindow();
    }
}
