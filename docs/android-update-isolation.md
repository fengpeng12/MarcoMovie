# Android phone and TV update isolation

The current repair work follows the owner's order: Android phones first, iPhone
second, then Windows and macOS. Subscription/live-source acceptance remains a
separate requirement; this update change does not complete the source-runtime
or physical-device checks.

## Edition and channel

The installed APK's `com.pilipala.marcomovie.EDITION` metadata chooses the update
edition. Screen size, orientation, touch input and TV mode do not change it.
Only `mobile` and `tv` are accepted; absent or unknown values stop the update.

- Phone/tablet: `updates/android-mobile.json` (stable) or
  `updates/android-mobile-preview.json` (preview).
- TV: `updates/android-tv.json` (stable) or
  `updates/android-tv-preview.json` (preview).

Each edition tries its mirror feed, then its raw GitHub feed. Legacy shared
`stable.json` / `preview.json` remain a migration fallback. A phone must select
the legacy `mobile` object and cannot fall back to the TV artifact at the root.
Independent feeds carry their own platform, versionCode, versionName, minSdk,
notes, size, SHA-256, URL and actual GitHub download URL. Retry preserves that
release's tag rather than inventing a `vVERSION-preview` address. Stable clients
reject prereleases. Cached metadata is subject to the same edition checks.

The downloaded APK still has to pass size/hash, package name, increasing version,
exact versionName, compatible minSdk, edition and signing-certificate checks.
Even a TV APK renamed to a phone filename with a matching feed hash is rejected.

## Clear package names and migration

New Android build outputs use:

| Device | Main package name |
|---|---|
| Phone / tablet | `MarcoMovie-X.Y.Z-android-mobile.apk` |
| TV / box | `MarcoMovie-X.Y.Z-android-tv.apk` |
| Lite edition | `MarcoMovie-X.Y.Z-android-lite.apk` |

The build also produces byte-identical old-name aliases (`-mobile.apk`,
`-preview.apk`, `-lite.apk`) and corresponding checksum files. They are migration
artifacts, not additional editions. New updaters accept both naming schemes
while rejecting another edition's filename or release tag.

Old installed updaters cannot discover independent Android tags/feeds. The first
transition needs either a verified legacy combined release with the aliases
under its legacy tag/feed, or a manual installation from the download page.
Renaming a file alone does not upgrade those old clients. Do not overwrite an
existing published installer or reuse its version code for different bytes.

Independent Android tags are `android-mobile-vX.Y.Z` and `android-tv-vX.Y.Z`;
preview tags append `-preview`. `sync_platform_packages.py` verifies the actual
APK manifest and checksum, writes only that edition's feeds, and patches the
existing download card without changing CSS/layout. A stable release also
advances its preview feed unless a newer preview is already recorded. Legacy
shared feeds and other platforms remain unchanged. APKs over the mirror's file
limit retain their exact GitHub asset URL. This script is not run against the
live mirror during unfinished compatibility work.

## Verification

Local checks cover 56 existing update/layout assertions, 42 edition-metadata
assertions and eight package/alias/feed tests, plus the existing 13 platform-sync
and 15 legacy-mirror tests. The `Android phone and TV update isolation` workflow
runs the production updater and Android package parser on API 23 and API 36.
It verifies both installed editions using isolated signed candidate APKs;
candidate updates are never installed. Its target derivatives omit native
media libraries, so results cannot establish decoder, source or physical-device
acceptance. Inspect the workflow result before claiming those runtime checks pass.

At commit `800383c6ad9a6630ed67fd2ec580c4a605cd2fd9`,
[run 42438513734](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42438513734)
passed 72 independently checked assertions: 18 per installed edition on each
API level. This includes the production download path, two failed mirror
attempts, fallback to the exact same-edition GitHub release, and verification of
the downloaded APK bytes. These emulator checks do not install the candidate
update or establish physical-device playback.
