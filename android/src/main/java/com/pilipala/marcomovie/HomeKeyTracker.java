package com.pilipala.marcomovie;

/** Three discrete Up taps in one second; holding a key never triggers the shortcut. */
final class HomeKeyTracker {
    int taps;
    long first;

    boolean up(long time, int repeat) {
        if (repeat != 0) {
            reset();
            return false;
        }
        if (taps == 0 || time < first || time - first > 1000) {
            first = time;
            taps = 1;
            return false;
        }
        if (++taps == 3) {
            reset();
            return true;
        }
        return false;
    }

    void reset() {
        taps = 0;
        first = 0;
    }
}
