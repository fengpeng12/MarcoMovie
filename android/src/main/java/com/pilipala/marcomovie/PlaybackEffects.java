package com.pilipala.marcomovie;

import android.graphics.*;
import android.media.audiofx.*;
import android.view.View;

/** Effects apply only to this player's audio session and rendering view. */
final class PlaybackEffects implements java.io.Closeable {
    Equalizer equalizer;
    BassBoost bass;

    void audio(int session, int preset) throws Exception {
        close();
        if (preset == 0) return;
        if (session <= 0) throw new IllegalStateException("视频音轨尚未就绪");
        try {
            equalizer = new Equalizer(0, session);
            short[] range = equalizer.getBandLevelRange();
            short bands = equalizer.getNumberOfBands();
            for (short band = 0; band < bands; band++) {
                int frequency = equalizer.getCenterFreq(band) / 1000;
                int gain =
                        preset == 1
                                ? (frequency < 250 ? 300 : frequency > 4000 ? 120 : 0)
                                : preset == 2
                                        ? (frequency >= 500 && frequency <= 4000 ? 350 : -100)
                                        : frequency < 200 ? -500 : frequency > 4000 ? -100 : 200;
                equalizer.setBandLevel(band, (short) Math.max(range[0], Math.min(range[1], gain)));
            }
            equalizer.setEnabled(true);
            if (preset == 1) {
                bass = new BassBoost(0, session);
                if (bass.getStrengthSupported()) bass.setStrength((short) 350);
                bass.setEnabled(true);
            }
        } catch (Exception error) {
            close();
            throw error;
        }
    }

    static void picture(View view, int preset) {
        if (view instanceof VideoOutput) {
            ((VideoOutput) view).picture(preset);
            return;
        }
        if (preset == 0) {
            UiCompat.setLayerPaint(view, null);
            return;
        }
        ColorMatrix color = new ColorMatrix();
        color.setSaturation(preset == 1 ? 1.08f : preset == 2 ? 1.16f : .82f);
        float contrast = preset == 1 ? 1.02f : preset == 2 ? 1.10f : .94f,
                brightness = preset == 1 ? 7 : preset == 2 ? -3 : 4;
        ColorMatrix exposure =
                new ColorMatrix(
                        new float[] {
                            contrast,
                            0,
                            0,
                            0,
                            brightness,
                            0,
                            contrast,
                            0,
                            0,
                            brightness,
                            0,
                            0,
                            contrast,
                            0,
                            brightness,
                            0,
                            0,
                            0,
                            1,
                            0
                        });
        color.postConcat(exposure);
        Paint paint = new Paint();
        paint.setColorFilter(new ColorMatrixColorFilter(color));
        UiCompat.setLayerPaint(view, paint);
    }

    @Override
    public void close() {
        if (bass != null) {
            try {
                bass.release();
            } catch (Exception ignored) {
            }
            bass = null;
        }
        if (equalizer != null) {
            try {
                equalizer.release();
            } catch (Exception ignored) {
            }
            equalizer = null;
        }
    }
}
