package com.pilipala.marcomovie;

/**
 * Responsive layout policy for TV (960x540 logical canvas), Android Tablet (640dp shortest-side
 * canvas), and Android Phone (390dp shortest-side canvas with portrait/landscape adaptation).
 */
final class TvLayoutPolicy {
    static final int FORM_TV = 0;
    static final int FORM_TABLET = 1;
    static final int FORM_PHONE = 2;

    static int percent(int value) {
        return value == 110 || value == 120 ? value : 100;
    }

    static int formFactor(boolean televisionMode, boolean hasTouchscreen, int smallestWidthDp) {
        if (televisionMode || !hasTouchscreen) return FORM_TV;
        return smallestWidthDp >= 600 ? FORM_TABLET : FORM_PHONE;
    }

    static boolean isPortrait(int width, int height) {
        return width > 0 && height > width;
    }

    static boolean useBottomDock(int width, int height, int formFactor) {
        return formFactor != FORM_TV && isPortrait(width, height);
    }

    static int searchColumns(float availableWidthDp) {
        return Math.max(2, Math.min(4, (int) (availableWidthDp / 132)));
    }

    static int homeColumns(float widthDp, int requested) {
        return Math.max(
                3, Math.min(Math.max(5, Math.min(8, requested)), (int) ((widthDp - 120) / 140)));
    }

    static int responsiveHomeColumns(
            float widthDp, int requested, int formFactor, boolean portrait) {
        if (formFactor == FORM_TV) return homeColumns(widthDp, requested);
        if (portrait || widthDp < 480) {
            return Math.max(2, Math.min(3, (int) ((widthDp - 24) / 112)));
        }
        if (widthDp < 720) {
            return Math.max(3, Math.min(4, (int) ((widthDp - 72) / 136)));
        }
        return homeColumns(widthDp, requested);
    }

    static int catalogColumns(float widthDp, int formFactor, boolean portrait) {
        if (formFactor == FORM_TV) return 4;
        if (portrait || widthDp < 480) {
            return Math.max(2, Math.min(3, (int) ((widthDp - 24) / 116)));
        }
        return widthDp < 700 ? 3 : 4;
    }

    static int episodeColumns(float widthDp, int formFactor, boolean portrait) {
        if (formFactor == FORM_TV) return 3;
        if (portrait && widthDp < 420) return 3;
        return widthDp >= 720 ? 4 : 3;
    }

    static int densityDpi(int width, int height, int percent) {
        if (width <= 0 || height <= 0) return 160;
        float scale =
                Math.min(Math.max(width, height) / 960f, Math.min(width, height) / 540f)
                        * percent(percent)
                        / 100f;
        return Math.max(80, Math.min(1920, Math.round(scale * 160)));
    }

    static int deviceDensityDpi(int width, int height, int percent, int formFactor) {
        if (width <= 0 || height <= 0) return 160;
        if (formFactor == FORM_TV) return densityDpi(width, height, percent);
        float targetShortestDp = formFactor == FORM_TABLET ? 640f : 390f;
        float scale = (Math.min(width, height) / targetShortestDp) * percent(percent) / 100f;
        return Math.max(120, Math.min(1920, Math.round(scale * 160)));
    }
}
