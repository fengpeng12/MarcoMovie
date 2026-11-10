package com.pilipala.glass;

import java.util.Arrays;

/** CPU counterpart of Glasswork glass.css, lens.js and adapt.js (MIT, see notices). */
public final class GlassworkMaterial {
    public static final int DARK_TINT = 0xff1e1e22;
    public static final int DARK_INK = 0xffd1d1da;
    private static final double[] LINEAR = new double[256];

    static {
        for (int i = 0; i < 256; i++) {
            double c = i / 255.0;
            LINEAR[i] = c <= .03928 ? c / 12.92 : Math.pow((c + .055) / 1.055, 2.4);
        }
    }

    private GlassworkMaterial() {}

    public static double luminance(int color) {
        return .2126 * LINEAR[(color >> 16) & 255]
                + .7152 * LINEAR[(color >> 8) & 255]
                + .0722 * LINEAR[color & 255];
    }

    public static double contrast(int a, int b) {
        double x = luminance(a), y = luminance(b);
        return (Math.max(x, y) + .05) / (Math.min(x, y) + .05);
    }

    private static double clamp(double v, double min, double max) {
        return Math.max(min, Math.min(max, v));
    }

    private static int channel(double v) {
        return (int) Math.round(clamp(v, 0, 255));
    }

    private static double smooth(double x) {
        x = clamp(x, 0, 1);
        return x * x * (3 - 2 * x);
    }

    private static int rgb(double r, double g, double b) {
        return 0xff000000 | channel(r) << 16 | channel(g) << 8 | channel(b);
    }

    private static int mix(int a, int b, double alpha) {
        return rgb(
                ((a >> 16) & 255) * (1 - alpha) + ((b >> 16) & 255) * alpha,
                ((a >> 8) & 255) * (1 - alpha) + ((b >> 8) & 255) * alpha,
                (a & 255) * (1 - alpha) + (b & 255) * alpha);
    }

    /** Returns an opaque, bounded-size material image; the UI clips its existing round shape. */
    public static int[] render(
            int[] scene, int width, int height, float radius, float pixelsPerDp, boolean dark) {
        if (width <= 0
                || height <= 0
                || width * (long) height > 65536
                || scene.length != width * height)
            throw new IllegalArgumentException("Glasswork capture dimensions exceed budget");
        double[] samples = new double[15];
        double red = 0, green = 0, blue = 0;
        for (int y = 0; y < 3; y++)
            for (int x = 0; x < 5; x++) {
                int c =
                        scene[
                                Math.min(height - 1, (int) (height * (.24 + .26 * y))) * width
                                        + Math.min(width - 1, (int) (width * (.18 + .16 * x)))];
                red += (c >> 16) & 255;
                green += (c >> 8) & 255;
                blue += c & 255;
                samples[y * 5 + x] =
                        (.299 * ((c >> 16) & 255) + .587 * ((c >> 8) & 255) + .114 * (c & 255))
                                / 255.0;
            }
        Arrays.sort(samples);
        double mean = 0;
        for (int i = 2; i < 13; i++) mean += samples[i] / 11;
        double texture = samples[14] - samples[0];
        double chroma =
                (Math.max(red, Math.max(green, blue)) - Math.min(red, Math.min(green, blue)))
                        / (15 * 255);
        double near = dark ? smooth((mean - .12) / .4) : smooth((.8 - mean) / .35);
        double density = clamp(near * .55 + texture * .7 + chroma * .3, 0, 1);
        double saturation = (dark ? 1.6 : 1.8) * clamp(1 - chroma * .75, .45, 1);
        double brightness = dark ? .8 : 1.06;
        int[] blurred = blur(scene, width, height, Math.max(.35, 2 * pixelsPerDp));
        int[] output = new int[scene.length];
        double halfW = width / 2.0, halfH = height / 2.0;
        double corner = Math.min(radius, Math.min(halfW, halfH));
        double rim = Math.max(1, Math.min(40 * pixelsPerDp, Math.min(width, height) / 3.5));
        int brightest = 0, darkest = 255;
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++) {
                double lx = x + .5 - halfW, ly = y + .5 - halfH;
                double qx = Math.abs(lx) - halfW + corner, qy = Math.abs(ly) - halfH + corner;
                double ax = Math.max(qx, 0),
                        ay = Math.max(qy, 0),
                        length = Math.sqrt(ax * ax + ay * ay);
                double depth = corner - length - Math.min(Math.max(qx, qy), 0);
                double nx = length > 0 ? ax / length : qx > qy ? 1 : 0,
                        ny = length > 0 ? ay / length : qx > qy ? 0 : 1;
                double bend = rim * 1.1 * Math.pow(clamp(1 - depth / rim, 0, 1), 2.6);
                double dx = -Math.signum(lx) * nx * bend, dy = -Math.signum(ly) * ny * bend;
                double r = sample(blurred, width, height, x + dx * 1.15, y + dy * 1.15, 16);
                double g = sample(blurred, width, height, x + dx, y + dy, 8);
                double b = sample(blurred, width, height, x + dx * .85, y + dy * .85, 0);
                double l = .213 * r + .715 * g + .072 * b;
                int color =
                        rgb(
                                (l + (r - l) * saturation) * brightness,
                                (l + (g - l) * saturation) * brightness,
                                (l + (b - l) * saturation) * brightness);
                output[y * width + x] = color;
                for (int shift = 0; shift <= 16; shift += 8) {
                    int c = (color >> shift) & 255;
                    brightest = Math.max(brightest, c);
                    darkest = Math.min(darkest, c);
                }
            }
        int tint = dark ? DARK_TINT : 0xffffffff, ink = dark ? DARK_INK : 0xff1d1d1f;
        int worst = dark ? rgb(brightest, brightest, brightest) : rgb(darkest, darkest, darkest);
        double alpha = dark ? .16 + .22 * density : .06 + .16 * density;
        if (contrast(ink, mix(worst, tint, alpha)) < 4.5) {
            double low = alpha, high = .9;
            for (int i = 0; i < 16; i++) {
                double mid = (low + high) / 2;
                if (contrast(ink, mix(worst, tint, mid)) >= 4.5) high = mid;
                else low = mid;
            }
            alpha = high;
        }
        for (int i = 0; i < output.length; i++) output[i] = mix(output[i], tint, alpha);
        return output;
    }

    private static double sample(int[] pixels, int w, int h, double x, double y, int channel) {
        x = clamp(x, 0, w - 1);
        y = clamp(y, 0, h - 1);
        int x0 = (int) x, y0 = (int) y, x1 = Math.min(w - 1, x0 + 1), y1 = Math.min(h - 1, y0 + 1);
        double fx = x - x0, fy = y - y0;
        double a =
                ((pixels[y0 * w + x0] >> channel) & 255) * (1 - fx)
                        + ((pixels[y0 * w + x1] >> channel) & 255) * fx;
        double b =
                ((pixels[y1 * w + x0] >> channel) & 255) * (1 - fx)
                        + ((pixels[y1 * w + x1] >> channel) & 255) * fx;
        return a * (1 - fy) + b * fy;
    }

    private static int[] blur(int[] input, int w, int h, double sigma) {
        int radius = Math.min(8, Math.max(1, (int) Math.ceil(sigma * 3)));
        double[] weights = new double[radius * 2 + 1];
        double total = 0;
        for (int i = -radius; i <= radius; i++) {
            weights[i + radius] = Math.exp(-i * i / (2 * sigma * sigma));
            total += weights[i + radius];
        }
        for (int i = 0; i < weights.length; i++) weights[i] /= total;
        int[] temp = new int[input.length], out = new int[input.length];
        for (int pass = 0; pass < 2; pass++) {
            int[] src = pass == 0 ? input : temp, dst = pass == 0 ? temp : out;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    double r = 0, g = 0, b = 0;
                    for (int n = -radius; n <= radius; n++) {
                        int xx = pass == 0 ? Math.max(0, Math.min(w - 1, x + n)) : x;
                        int yy = pass == 0 ? y : Math.max(0, Math.min(h - 1, y + n));
                        int c = src[yy * w + xx];
                        double weight = weights[n + radius];
                        r += ((c >> 16) & 255) * weight;
                        g += ((c >> 8) & 255) * weight;
                        b += (c & 255) * weight;
                    }
                    dst[y * w + x] = rgb(r, g, b);
                }
        }
        return out;
    }
}
