# Desktop player fullscreen

- Double-click the video surface to enter/leave native fullscreen on Windows and macOS. The fullscreen button and F/F11 use the same transition.
- Hide the native titlebar and window buttons during fullscreen. Windows uses the monitor bounds, including the area normally occupied by the taskbar; macOS uses native AppKit fullscreen.
- Escape exits fullscreen first; a subsequent Escape leaves the player. Returning from the player restores the fullscreen state captured when it opened. Native window management restores window placement/maximization.
- Desktop button text reflects actual fullscreen state, independently of window aspect ratio. Mobile orientation behavior is unchanged.
- Serialize native transitions and wait for macOS fullscreen completion events. Failed entry restores window controls; leaving the player during a transition queues restoration.

## Verification

Six focused channel tests cover native fullscreen/titlebar ordering, queued Mac transitions, route disposal during entry, initially fullscreen windows, failure recovery and system-triggered exits. Four existing source playback tests also passed. Static analysis reports no errors or warnings in the changed player code (existing style/deprecation infos remain).

On Windows 11, a local test harness opened the actual production PlayerScreen with a generated local MP4 and in-memory preferences. UI verification confirmed double-click entry from normal and maximized windows, fullscreen bounds of 2048 x 1152 at origin 0,0 without a native titlebar, Escape exit, double-click exit, F11 entry and window restoration when leaving the player. The harness and media are private test artifacts, not distributable packages.

The Windows release build was then repeated with the production `lib/main.dart` entrypoint and passed. The final local executable uses the production entrypoint, not the test harness.

The [macOS build at e1d633c](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42354522011) passed all 81 Flutter tests and produced the release app and workflow artifact. The public guardrails and offline Java checks also passed. This artifact is a repair-branch build, not a new official release.

macOS native UI verification is still pending. Passing mocked transition tests or a cross-platform build is not a Mac device result. This change is on the repair branch; it does not publish a release or update the mirror.
