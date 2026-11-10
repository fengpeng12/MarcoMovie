package com.pilipala.glass;

import java.util.Arrays;
import java.util.Random;

/** Pixel-level readability and bounded-work regressions, independent of Android rendering. */
public final class GlassworkChecks {
    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }

    public static void main(String[] args) {
        int w = 192, h = 64;
        Random random = new Random(940);
        for (boolean dark : new boolean[] {true, false}) {
            for (int pattern = 0; pattern < 7; pattern++) {
                int[] scene = new int[w * h];
                for (int i = 0; i < scene.length; i++) {
                    int x = i % w, y = i / w;
                    scene[i] =
                            pattern == 0
                                    ? 0xffffffff
                                    : pattern == 1
                                            ? 0xff000000
                                            : pattern == 2
                                                    ? ((x / 4 + y / 4) % 2 == 0
                                                            ? 0xffffffff
                                                            : 0xff000000)
                                                    : pattern == 3
                                                            ? 0xffff0000
                                                            : pattern == 4
                                                                    ? 0xff00ff00
                                                                    : pattern == 5
                                                                            ? 0xff0000ff
                                                                            : 0xff000000
                                                                                    | random
                                                                                            .nextInt(
                                                                                                    0x1000000);
                }
                int[] before = scene.clone();
                int[] output = GlassworkMaterial.render(scene, w, h, 24, 1, dark);
                check(Arrays.equals(before, scene), "source frame must remain unchanged");
                check(output.length == scene.length, "output dimensions");
                int ink = dark ? GlassworkMaterial.DARK_INK : 0xff1d1d1f;
                for (int c : output) {
                    check((c >>> 24) == 255, "opaque captured material");
                    check(
                            GlassworkMaterial.contrast(ink, c) >= 4.5,
                            "4.5:1 contrast across the whole frame");
                }
                if (pattern != 2 && pattern != 6) {
                    check(
                            output[20 * w + 75] == output[40 * w + 110],
                            "uniform backdrop stays flat in center");
                }
            }
        }
        int[] small = GlassworkMaterial.render(new int[] {0xffffffff}, 1, 1, 100, .1f, true);
        check(small.length == 1, "tiny surface clamps lens samples");
        try {
            GlassworkMaterial.render(new int[65537], 65537, 1, 0, 1, true);
            throw new AssertionError("unbounded capture accepted");
        } catch (IllegalArgumentException expected) {
        }
        try {
            GlassworkMaterial.render(new int[10], 8, 8, 0, 1, true);
            throw new AssertionError("incorrect dimensions accepted");
        } catch (IllegalArgumentException expected) {
        }
        System.out.println(
                "Glasswork: 14 light/dark backdrop cases, immutable input, small and bounded dimensions passed");
    }
}
