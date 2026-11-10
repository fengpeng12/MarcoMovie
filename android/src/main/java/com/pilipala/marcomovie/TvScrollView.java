package com.pilipala.marcomovie;

import android.graphics.Rect;
import android.view.*;
import android.widget.ScrollView;

/** A single focus reveal policy; retargeting retains position and velocity. */
final class TvScrollView extends ScrollView {
    final MainActivity a;
    final MotionSpring spring = new MotionSpring(0, 18, .35f);
    MotionLoop.Step motion;
    boolean focusing, layingOut;
    int goal;

    TvScrollView(MainActivity host) {
        super(host);
        a = host;
        setOverScrollMode(OVER_SCROLL_NEVER);
        setSmoothScrollingEnabled(false);
        setClipChildren(false);
        setClipToPadding(false);
    }

    @Override
    protected void dispatchDraw(android.graphics.Canvas canvas) {
        int save = canvas.save();
        canvas.clipRect(
                getScrollX(), getScrollY(), getScrollX() + getWidth(), getScrollY() + getHeight());
        super.dispatchDraw(canvas);
        canvas.restoreToCount(save);
    }

    int limit() {
        return getChildCount() == 0
                ? 0
                : Math.max(
                        0,
                        getChildAt(0).getHeight()
                                - getHeight()
                                + getPaddingTop()
                                + getPaddingBottom());
    }

    int bound(int y) {
        return Math.max(0, Math.min(y, limit()));
    }

    void cancelMotion() {
        if (motion != null) MotionLoop.remove(motion);
        motion = null;
        spring.snap(getScrollY());
    }

    void moveTo(int y) {
        int end = bound(y);
        goal = end;
        if (a.reduced) {
            cancelMotion();
            spring.snap(end);
            super.scrollTo(0, end);
            return;
        }
        if (motion == null) spring.snap(getScrollY());
        spring.target(end);
        if (motion != null || getScrollY() == end && spring.velocity == 0) return;
        motion =
                seconds -> {
                    if (!isAttachedToWindow()) {
                        motion = null;
                        return false;
                    }
                    boolean moving = spring.step(seconds);
                    int next = bound(Math.round(spring.value));
                    TvScrollView.super.scrollTo(0, next);
                    if (!moving) {
                        motion = null;
                        return false;
                    }
                    return true;
                };
        MotionLoop.add(motion);
    }

    void reveal(View focused) {
        if (focused == null || getHeight() == 0) return;
        Rect area = new Rect(0, 0, focused.getWidth(), focused.getHeight());
        offsetDescendantRectToMyCoords(focused, area);
        reveal(area);
    }

    void reveal(Rect area) {
        int margin = a.dp(14);
        int reference = motion == null ? getScrollY() : goal;
        int top = reference + margin, bottom = reference + getHeight() - margin;
        int y = reference;
        // Small focus changes inside the destination's safe region do not move the page.
        if (area.height() > getHeight() - 2 * margin) y = area.top - margin;
        else if (area.top < top) y = area.top - Math.max(margin, (getHeight() - area.height()) / 3);
        else if (area.bottom > bottom)
            y = area.bottom - getHeight() + Math.max(margin, (getHeight() - area.height()) / 3);
        else return;
        moveTo(y);
    }

    @Override
    public void requestChildFocus(View child, View focused) {
        focusing = true;
        try {
            super.requestChildFocus(child, focused);
        } finally {
            focusing = false;
        }
        reveal(focused);
    }

    @Override
    public void scrollTo(int x, int y) {
        if (focusing) return;
        if (layingOut) {
            if (motion != null) return;
            super.scrollTo(x, y);
            spring.snap(getScrollY());
            return;
        }
        cancelMotion();
        super.scrollTo(x, y);
        spring.snap(getScrollY());
        goal = getScrollY();
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        layingOut = true;
        try {
            super.onLayout(changed, l, t, r, b);
        } finally {
            layingOut = false;
        }
        if (motion != null && goal > limit()) moveTo(limit());
    }

    @Override
    public boolean requestChildRectangleOnScreen(View child, Rect rectangle, boolean immediate) {
        if (focusing) return false;
        Rect area = new Rect(rectangle);
        offsetDescendantRectToMyCoords(child, area);
        int old = goal;
        if (immediate) {
            int delta = computeScrollDeltaToGetChildRectOnScreen(area);
            scrollTo(0, getScrollY() + delta);
        } else reveal(area);
        return old != goal || motion != null;
    }

    @Override
    public boolean executeKeyEvent(KeyEvent event) {
        int key = event.getKeyCode();
        if ((key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN)
                && !event.isAltPressed()) {
            if (event.getAction() != KeyEvent.ACTION_DOWN) return true;
            int direction = key == KeyEvent.KEYCODE_DPAD_UP ? View.FOCUS_UP : View.FOCUS_DOWN;
            View focused = findFocus();
            if (focused == this) focused = null;
            View next = FocusFinder.getInstance().findNextFocus(this, focused, direction);
            if (next != null && next != this) {
                next.requestFocus(direction);
                return true;
            }
            int end = key == KeyEvent.KEYCODE_DPAD_UP ? 0 : limit();
            if ((motion == null ? getScrollY() : goal) == end) return false;
            moveTo(end);
            return true;
        }
        return super.executeKeyEvent(event);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) cancelMotion();
        return super.onTouchEvent(event);
    }

    @Override
    protected void onDetachedFromWindow() {
        cancelMotion();
        super.onDetachedFromWindow();
    }
}
