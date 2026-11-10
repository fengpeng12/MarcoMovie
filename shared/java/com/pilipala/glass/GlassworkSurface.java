package com.pilipala.glass;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.ViewTreeObserver;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Bounded backdrop capture for API 14+. Unreadable video/hardware surfaces use the tint fallback. */
public final class GlassworkSurface extends Drawable
        implements View.OnAttachStateChangeListener,
                ViewTreeObserver.OnScrollChangedListener,
                ViewTreeObserver.OnGlobalLayoutListener {
    public interface Options {
        boolean reduceTransparency();
    }

    /** Implemented by a native video view; older clients need no PixelCopy API reference. */
    public interface FrameSource {
        void prepareGlassFrame(Runnable ready);

        boolean glassFrameAdvancing();
    }

    public static boolean isCapturingBackdrop() {
        return Boolean.TRUE.equals(CAPTURING.get());
    }

    private static final ThreadLocal<Boolean> CAPTURING = new ThreadLocal<Boolean>();
    private static final ArrayList<WeakReference<GlassworkSurface>> SURFACES = new ArrayList<>();
    private static final ThreadPoolExecutor WORK =
            new ThreadPoolExecutor(0, 1, 15, TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(4));
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private final View target;
    private final View backdrop;
    private final Options options;
    private final float radius;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final RectF rect = new RectF();
    private final Path shape = new Path();
    private Bitmap material;
    private ViewTreeObserver observer;
    private boolean attached, pending, dirty = true, scheduled;
    private int generation, opacity = 255;
    private long lastCapture;
    private final Runnable refresh =
            new Runnable() {
                public void run() {
                    scheduled = false;
                    capture();
                }
            };

    private GlassworkSurface(View target, View backdrop, float radius, Options options) {
        this.target = target;
        this.backdrop = backdrop;
        this.radius = radius;
        this.options = options;
    }

    @SuppressWarnings("deprecation")
    public static void attach(View target, View backdrop, float radius, Options options) {
        if (target == null || backdrop == null) return;
        if (target.getBackground() instanceof GlassworkSurface) {
            GlassworkSurface old = (GlassworkSurface) target.getBackground();
            old.onViewDetachedFromWindow(target);
            target.removeOnAttachStateChangeListener(old);
        }
        int l = target.getPaddingLeft(), t = target.getPaddingTop();
        int r = target.getPaddingRight(), b = target.getPaddingBottom();
        GlassworkSurface surface = new GlassworkSurface(target, backdrop, radius, options);
        target.setBackgroundDrawable(surface);
        target.setPadding(l, t, r, b);
        target.addOnAttachStateChangeListener(surface);
        if (target.getWindowToken() != null) surface.onViewAttachedToWindow(target);
    }

    /** Call when an asynchronously loaded image or ambient background changes. UI thread only. */
    public static void invalidateBackdrop(View root) {
        for (int i = SURFACES.size() - 1; i >= 0; i--) {
            GlassworkSurface s = SURFACES.get(i).get();
            if (s == null || !s.attached) SURFACES.remove(i);
            else if (root == s.backdrop || root.getRootView() == s.backdrop.getRootView())
                s.changed();
        }
    }

    public void onViewAttachedToWindow(View view) {
        if (attached) return;
        attached = true;
        observer = backdrop.getViewTreeObserver();
        observer.addOnScrollChangedListener(this);
        observer.addOnGlobalLayoutListener(this);
        SURFACES.add(new WeakReference<GlassworkSurface>(this));
        changed();
    }

    @SuppressWarnings("deprecation")
    public void onViewDetachedFromWindow(View view) {
        attached = false;
        generation++;
        pending = false;
        material = null;
        MAIN.removeCallbacks(refresh);
        scheduled = false;
        if (observer != null && observer.isAlive()) {
            observer.removeOnScrollChangedListener(this);
            observer.removeGlobalOnLayoutListener(this);
        }
        observer = null;
        for (int i = SURFACES.size() - 1; i >= 0; i--) {
            GlassworkSurface s = SURFACES.get(i).get();
            if (s == null || s == this) SURFACES.remove(i);
        }
    }

    public void onScrollChanged() {
        changed();
    }

    public void onGlobalLayout() {
        changed();
    }

    private void changed() {
        dirty = true;
        invalidateSelf();
        schedule();
    }

    private void schedule() {
        if (!attached || pending || scheduled || !dirty || options.reduceTransparency()) return;
        scheduled = true;
        MAIN.postDelayed(
                refresh, Math.max(0, 100 - (android.os.SystemClock.uptimeMillis() - lastCapture)));
    }

    private static FrameSource findFrameSource(View view) {
        if (view.getVisibility() != View.VISIBLE) return null;
        if (view instanceof FrameSource) return (FrameSource) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                FrameSource found = findFrameSource(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    private void capture() {
        capture(false);
    }

    private void capture(boolean framePrepared) {
        if (!attached
                || pending
                || !dirty
                || !target.isShown()
                || target.getAlpha() < .01f
                || options.reduceTransparency()) return;
        int w = target.getWidth(), h = target.getHeight();
        if (w <= 0 || h <= 0) return;
        final FrameSource frames = findFrameSource(backdrop);
        if (!framePrepared && frames != null) {
            final int token = generation;
            pending = true;
            try {
                frames.prepareGlassFrame(
                        new Runnable() {
                            public void run() {
                                if (!attached || generation != token) return;
                                pending = false;
                                capture(true);
                            }
                        });
            } catch (RuntimeException unavailable) {
                pending = false;
                capture(true);
            }
            return;
        }
        double scale =
                Math.min(
                        1, Math.min(384.0 / Math.max(w, h), Math.sqrt(24576.0 / ((double) w * h))));
        final int width = Math.max(1, (int) (w * scale)), height = Math.max(1, (int) (h * scale));
        final float sx = (float) width / w;
        Bitmap scene = null;
        try {
            scene = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(scene);
            canvas.drawColor(GlassworkMaterial.DARK_TINT);
            int[] screen = new int[2], base = new int[2];
            target.getLocationOnScreen(screen);
            backdrop.getLocationOnScreen(base);
            canvas.scale(sx, (float) height / h);
            canvas.translate(base[0] - screen[0], base[1] - screen[1]);
            CAPTURING.set(Boolean.TRUE);
            drawBehind(canvas, backdrop, target);
            final int[] pixels = new int[width * height];
            scene.getPixels(pixels, 0, width, 0, 0, width, height);
            final int token = generation;
            final float density = target.getResources().getDisplayMetrics().density * sx;
            pending = true;
            dirty = false;
            lastCapture = android.os.SystemClock.uptimeMillis();
            WORK.execute(
                    new Runnable() {
                        public void run() {
                            Bitmap result = null;
                            try {
                                int[] rendered =
                                        GlassworkMaterial.render(
                                                pixels, width, height, radius * sx, density, true);
                                result =
                                        Bitmap.createBitmap(
                                                rendered, width, height, Bitmap.Config.ARGB_8888);
                            } catch (RuntimeException ignored) {
                                // An unreadable/unsupported backdrop keeps the material fallback.
                            }
                            final Bitmap ready = result;
                            MAIN.post(
                                    new Runnable() {
                                        public void run() {
                                            if (generation != token || !attached) return;
                                            pending = false;
                                            material = ready;
                                            if (frames != null && frames.glassFrameAdvancing())
                                                dirty = true;
                                            invalidateSelf();
                                            schedule();
                                        }
                                    });
                        }
                    });
        } catch (RejectedExecutionException busy) {
            pending = false;
            dirty = true;
            lastCapture = android.os.SystemClock.uptimeMillis();
            schedule();
        } catch (RuntimeException ignored) {
            pending = false;
            dirty = false;
            material = null;
        } finally {
            CAPTURING.remove();
            if (scene != null) scene.recycle();
        }
    }

    private static boolean contains(View parent, View child) {
        for (View at = child; at != null; ) {
            if (at == parent) return true;
            ViewParent p = at.getParent();
            at = p instanceof View ? (View) p : null;
        }
        return false;
    }

    /** Ancestor backgrounds and earlier siblings only: never rasterize the target's text into glass. */
    private static void drawBehind(Canvas canvas, View view, View stop) {
        if (view == stop || view.getVisibility() != View.VISIBLE || view.getAlpha() <= 0) return;
        if (!contains(view, stop)) {
            // Other glass surfaces must not recursively capture themselves or their foreground.
            if (!(view.getBackground() instanceof GlassworkSurface)) view.draw(canvas);
            return;
        }
        Drawable bg = view.getBackground();
        if (bg != null) bg.draw(canvas);
        if (!(view instanceof ViewGroup)) return;
        ViewGroup group = (ViewGroup) view;
        for (int i = 0; i < group.getChildCount(); i++) {
            View child = group.getChildAt(i);
            if (child == stop) break;
            int save = canvas.save();
            canvas.translate(
                    child.getLeft() - view.getScrollX(), child.getTop() - view.getScrollY());
            canvas.concat(child.getMatrix());
            if (child.getAlpha() < 1)
                canvas.saveLayerAlpha(
                        0,
                        0,
                        child.getWidth(),
                        child.getHeight(),
                        (int) (child.getAlpha() * 255),
                        Canvas.ALL_SAVE_FLAG);
            drawBehind(canvas, child, stop);
            canvas.restoreToCount(save);
            if (contains(child, stop)) break;
        }
    }

    @Override
    public void draw(Canvas canvas) {
        if (Boolean.TRUE.equals(CAPTURING.get())) return;
        rect.set(getBounds());
        float corner = Math.min(radius, Math.min(rect.width(), rect.height()) / 2);
        shape.reset();
        shape.addRoundRect(rect, corner, corner, Path.Direction.CW);
        int save = canvas.save();
        canvas.clipPath(shape);
        paint.setShader(null);
        paint.setStyle(Paint.Style.FILL);
        paint.setAlpha(opacity);
        if (!options.reduceTransparency() && material != null)
            canvas.drawBitmap(material, null, rect, paint);
        else {
            paint.setColor(GlassworkMaterial.DARK_TINT);
            paint.setAlpha(opacity);
            canvas.drawRect(rect, paint);
        }
        float px = target.getResources().getDisplayMetrics().density;
        // Glasswork's narrow white upper bevel and darker lower edge; preserve original radius.
        paint.setShader(
                new LinearGradient(
                        0,
                        rect.top,
                        0,
                        rect.bottom,
                        new int[] {0x75ffffff, 0x12ffffff, 0x2effffff},
                        new float[] {0, .45f, 1},
                        Shader.TileMode.CLAMP));
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1, px));
        rect.inset(px / 2, px / 2);
        canvas.drawRoundRect(rect, corner, corner, paint);
        paint.setShader(null);
        canvas.restoreToCount(save);
        schedule();
    }

    @Override
    public void setAlpha(int alpha) {
        opacity = alpha;
        invalidateSelf();
    }

    @Override
    public void setColorFilter(ColorFilter filter) {
        paint.setColorFilter(filter);
        invalidateSelf();
    }

    @Override
    public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
