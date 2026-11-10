# Android adaptive player controls

Phone controls use the measured playback layer rather than cached display size
or a requested orientation. A real layout change, including a smaller parent
viewport, schedules a new placement. Rotation requests no longer swap cached
width and height before the window has actually changed.

The control area intersects the visible parent bounds with the window's cutout,
gesture and navigation insets. Navigation space remains reserved while bars are
temporarily hidden, and window insets are translated into the playback layer's
coordinates so an already inset or centered container is not padded twice.
The video surface retains its own aspect-ratio behavior.

Progress width is limited to the space left beside the right tool Dock. The
former 220 dp minimum cannot force the bar outside a smaller viewport. Bottom
placement uses the actual available height and, in portrait, the measured Dock
height. No user-adjustable offset setting is introduced.

## Verification scope

The isolated local build and API 23 callback checks pass. The Android 16 player
workflow exercises gesture and three-button navigation separately, with actual
system-player seeking on a generated local audio fixture. Each run checks
normal landscape, reverse landscape, portrait, a deliberately smaller parent
viewport and restoration to the full viewport. It checks the whole timeline,
progress region and Dock against visible safe bounds, and verifies touch seeking.

At `d956ab0`, [Android 16 run 42440372966](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42440372966)
passed all 27 assertions in each navigation mode (54 total). The reviewed
screenshots also show the timeline within the available area and compact headings
clear of the central buttons. The first gesture-navigation attempt was interrupted
by an emulator SystemUI startup ANR; its failed evidence is retained separately.
The failed job alone was rerun on the same source revision and passed.

[Android 6 run 42440373128](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42440373128)
at the same revision passed 25 subtitle, 96 home/history and 86 source-host
assertions, including the player subtitle dialog and live-directory wrappers.

Inspect that workflow's results and screenshots before recording a runtime
pass. The smaller viewport is an intentional layout fixture, not a reproduced
Xiaomi firmware fault. These checks omit ARM decoder libraries and do not
establish real Redmi/Xiaomi video-decoder or third-party-source acceptance.
