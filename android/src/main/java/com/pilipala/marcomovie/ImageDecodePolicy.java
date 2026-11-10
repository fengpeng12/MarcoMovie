package com.pilipala.marcomovie;

/** Decode enough pixels for the displayed artwork while bounding TV memory. */
final class ImageDecodePolicy {
    static int sample(
            int width, int height, int boxWidth, int boxHeight, boolean crop, boolean detail) {
        if (width <= 0 || height <= 0) return 1;
        double scale =
                crop
                        ? Math.max((double) boxWidth / width, (double) boxHeight / height)
                        : Math.min((double) boxWidth / width, (double) boxHeight / height);
        scale = Math.min(1, Math.max(0, scale));
        int desiredWidth = Math.max(1, (int) Math.ceil(width * scale)),
                desiredHeight = Math.max(1, (int) Math.ceil(height * scale)),
                sample = 1;
        while (sample <= 16384
                && width / (sample * 2) >= desiredWidth
                && height / (sample * 2) >= desiredHeight) sample *= 2;
        long maxPixels = detail ? 2L * 1024 * 1024 : 800L * 1024;
        while (sample <= 16384
                && (long) Math.max(1, width / sample) * (long) Math.max(1, height / sample)
                        > maxPixels) sample *= 2;
        return sample;
    }

    static int targetWidth(int viewWidth, boolean detail) {
        return Math.max(
                1, Math.min(detail ? 1080 : 480, viewWidth > 64 ? viewWidth : detail ? 720 : 320));
    }

    static int targetHeight(int viewHeight, boolean detail) {
        return Math.max(
                1,
                Math.min(detail ? 1620 : 720, viewHeight > 64 ? viewHeight : detail ? 1080 : 480));
    }

    static String cacheKey(String address, int width, int height, boolean crop, boolean detail) {
        return address
                + "|"
                + width
                + "x"
                + height
                + "|"
                + (crop ? "crop" : "fit")
                + (detail ? "|detail" : "");
    }

    static int cacheBytes(int memoryClassMb) {
        int mb = Math.max(10, Math.min(32, memoryClassMb / 8));
        return mb * 1024 * 1024;
    }
}
