package com.pilipala.marcomovie;

public final class PlaybackFailureChecks {
    public static void main(String[] args) {
        int checks = 0;
        for (int code : new int[] {2001, 2004, 3001, 6006, 1000}) {
            if (PlaybackFailure.decoderFallback(code))
                throw new AssertionError(
                        "Do not retry transport, parser or DRM failures as decoder errors");
            checks++;
        }
        for (int code : new int[] {4001, 4002, 4003, 4004, 4005, 5001, 5002}) {
            if (!PlaybackFailure.decoderFallback(code))
                throw new AssertionError("Missing decoder/output recovery category");
            checks++;
        }
        if (!PlaybackFailure.message(2004, 403).contains("可能"))
            throw new AssertionError("403 must not assert login expired");
        checks++;
        if (!PlaybackFailure.message(2004, 404).contains("链接"))
            throw new AssertionError("Missing expired-link guidance");
        checks++;
        if (!PlaybackFailure.message(4004, 0).contains("解码"))
            throw new AssertionError("Missing format guidance");
        checks++;
        System.out.println("PASS " + checks + " playback error categorization checks");
    }
}
