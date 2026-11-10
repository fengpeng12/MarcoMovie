package com.pilipala.marcomovie;

import android.view.*;
import java.util.*;

/** Wraps full category labels; tall labels and remote focus follow actual rows. */
final class CategoryFlow extends ViewGroup {
    final int gap;
    final Runnable layoutReady;
    final List<List<View>> lines = new ArrayList<>();

    CategoryFlow(MainActivity a, Runnable ready) {
        super(a);
        float navScale = Prefs.clampNavScale(a.prefs.getInt(Prefs.NAV_SCALE_PERCENT, 100)) / 100f;
        gap = a.dp(Math.max(6, Math.round(8 * navScale)));
        layoutReady = ready;
        setClipChildren(false);
        setClipToPadding(false);
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int width = MeasureSpec.getSize(widthSpec),
                available = Math.max(1, width - getPaddingLeft() - getPaddingRight());
        int x = 0, height = getPaddingTop(), lineHeight = 0;
        for (int i = 0; i < getChildCount(); i++) {
            View child = getChildAt(i);
            if (child.getVisibility() == GONE) continue;
            child.measure(
                    MeasureSpec.makeMeasureSpec(available, MeasureSpec.AT_MOST),
                    MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
            if (x > 0 && x + child.getMeasuredWidth() > available) {
                height += lineHeight + gap;
                x = 0;
                lineHeight = 0;
            }
            x += child.getMeasuredWidth() + gap;
            lineHeight = Math.max(lineHeight, child.getMeasuredHeight());
        }
        setMeasuredDimension(
                width, resolveSize(height + lineHeight + getPaddingBottom(), heightSpec));
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        lines.clear();
        int start = getPaddingLeft(),
                x = start,
                y = getPaddingTop(),
                lineHeight = 0,
                end = r - l - getPaddingRight();
        List<View> line = new ArrayList<>();
        for (int i = 0; i < getChildCount(); i++) {
            View child = getChildAt(i);
            if (child.getVisibility() == GONE) continue;
            int w = child.getMeasuredWidth(), h = child.getMeasuredHeight();
            if (x > start && x + w > end) {
                lines.add(line);
                line = new ArrayList<>();
                y += lineHeight + gap;
                x = start;
                lineHeight = 0;
            }
            child.layout(x, y, x + w, y + h);
            line.add(child);
            x += w + gap;
            lineHeight = Math.max(lineHeight, h);
        }
        if (!line.isEmpty()) lines.add(line);
        layoutReady.run();
    }

    View nearest(List<View> row, View origin) {
        View best = row.get(0);
        int center = origin.getLeft() + origin.getWidth() / 2, distance = Integer.MAX_VALUE;
        for (View v : row) {
            int d = Math.abs(v.getLeft() + v.getWidth() / 2 - center);
            if (d < distance) {
                distance = d;
                best = v;
            }
        }
        return best;
    }

    @Override
    protected LayoutParams generateDefaultLayoutParams() {
        return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }
}
