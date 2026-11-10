# Independent platform releases

The owner allows each platform to release independently after its own checks. Version numbers do not have to match. A release must name its platform, build commit, tested fixes and remaining limitations.

**Standing release authorization (2026-11-10):** the owner instructed that future optimizations and fixes should be synchronized and published directly after the necessary checks, without a separate confirmation. This includes the Android TV category-focus fix in 0.5.15. Advance the affected platform's version, publish its verified package and matching source, and synchronize the download site and update feed. Report the actual validation scope; a build or emulator check does not establish physical-device acceptance.

**Current maintenance release authorization (2026-11-10):** the owner explicitly authorized synchronizing the reviewed fixes to GitHub and publishing each platform with its own version. iOS 0.5.13 was already published before this request. The earlier broad plugin-acceptance gate is retained as a historical limitation, not a claim that these maintenance builds complete every plugin route or physical-device acceptance. Every release must state its actual test scope and remaining limitations.

Desktop/Apple tags use `windows-vX.Y.Z`, `ios-vX.Y.Z` and `macos-vX.Y.Z`. They do not trigger the legacy `v*` all-platform publisher. Build the desired platform with the existing workflow dispatch, verify the artifact, and attach the package, SHA-256 file and corresponding source archive before publishing. Do not replace existing versioned assets. Keep the legacy all-platform release as GitHub's global latest so old clients are not directed to another platform's package.

Android phone/tablet and TV editions now have separate update feeds, independent
per-edition version configuration (`android/edition-versions.json`), and explicit
`android-mobile` / `android-tv` package names. See [Android update isolation](android-update-isolation.md)
for the release tags, old-client migration aliases and runtime verification scope.
Android phone/tablet 0.5.9 and TV 0.5.9 were independently published on November 9;
see the platform-specific records below.

See [installation package names](installation-package-names.md) for explicit
system/device and installer/portable labels across all platforms. Old-name assets
remain byte-identical compatibility aliases; mirror sync prefers the clear name
when that release actually supplies it, without changing the page layout.

Clients from 0.5.1 first read their own `movie/updates/{platform}.json` feed, then select the newest matching official GitHub release containing that platform's package. Other platform versions, drafts and prereleases are ignored. Clients at 0.5.0 still use the legacy shared feed; install the first independent platform update from the download page, then subsequent updates use the new platform feed.

The mirror runs `scripts/sync_platform_packages.py`. It patches existing download-card package URLs, byte sizes and hashes, writes the relevant platform feed, and updates only the existing changelog section with version-specific notes. It does not render a new HTML page or alter CSS, layout, images, unrelated prose/packages or legacy Android update channels. Large files retain the site's existing verified GitHub download behavior. Corresponding source remains attached to each platform's release.

## Required notes for every update

For each actual platform release, add a `docs/releases/{tag}.md` record and a platform/version entry in `CHANGELOG.md`. Use that reviewed record as the GitHub Release body. Name the platform, version, release date, additions, fixes, test scope, remaining limitations, and exact build commit. Describe only changes included in that package: an iOS build must not claim a later Android fix or unfinished plugin port. Unreleased work stays explicitly unreleased.

The mirror keeps the same complete Release body in the platform feed and `movie/updates/history/{tag}.md`, indexes versions in `movie/updates/history.json`, and shows them inside the existing changelog section. It retains older records across updates and labels preview releases separately. A new independent official release with an empty body is rejected before any mirror file is written. Updating notes does not replace package bytes, hashes, styling or other platforms' downloads. Verify the published text and platform/version mapping on GitHub and the live mirror after each release.

On November 7 the owner separately authorized a mirror layout revision. The
Movie page now puts downloads before the changelog, shows each package's own
version, supports platform filters and collapses historical entries. Release
Markdown is rendered as escaped headings, lists and paragraphs while the full
original text stays archived. Future automatic package updates preserve this
layout and update the visible version together with the package URL and hash.

The layout was deployed from mirror commit `acf776a`. Checks retained all eight
package/checksum URLs and hashes plus 47 historical release records. The live
375-pixel and 1280-pixel layouts, download and release filters were verified;
13 sync/rendering tests passed. [The subsequent automatic-sync
run](https://github.com/Pilipala9919/mtv/actions/runs/42381304827) also passed.
This website deployment did not replace any application installer.

## Published Android maintenance update

[Android phone/tablet 0.5.9](releases/android-mobile-v0.5.9.md) and [Android TV/box 0.5.9](releases/android-tv-v0.5.9.md) (version code 59), [Android phone/tablet 0.5.8](releases/android-mobile-v0.5.8.md) and [Android TV/box 0.5.8](releases/android-tv-v0.5.8.md) (version code 58), [Android TV/box 0.5.7](releases/android-tv-v0.5.7.md) and [Android phone/tablet 0.5.7](releases/android-mobile-v0.5.7.md) (version code 57),
[Android phone/tablet 0.5.6](releases/android-mobile-v0.5.6.md) and
[Android TV/box 0.5.6](releases/android-tv-v0.5.6.md) use build commit
`95121d25c30972170a3e1d94e7dcc73b5cced690` (version code 56), building on
[Android phone/tablet 0.5.5](releases/android-mobile-v0.5.5.md) and
[Android TV/box 0.5.5](releases/android-tv-v0.5.5.md) (`162918594f96fc3d0725606a3faf564a72a98864`).
The 0.5.3 release eliminates `PixelCopy` backdrop blur and full-screen hardware
layer reallocations on the playback overlay to fix Dolby Vision / HDR toolbar
pull-up stutter on TV, adds progress-only HUD during D-pad fast-forward/rewind,
reworks the TV subtitle adjuster (6 color/style presets on OK, immediate save),
enables category bar auto-switching on focus and customizable navigation bar
font/button scaling (`85%`–`140%`), and fixes mobile category/filter overlap,
detail cover poster resolution and play button text overflow, dialog clipping
and button backgrounds, and mobile playback chrome controls.

Both releases include matching source archives, SHA-256 files and byte-identical
legacy aliases. They do not replace the legacy global latest release. Users on
0.5.0 must manually select the correct device package once; thereafter each
edition follows its own update feed. The mirror receives the same version notes
and package links without changing its styles or other platforms' installers.
Automated/emulator/package checks are not universal physical-device playback
acceptance. The 33 outstanding plugin-route acceptances, full native Python
support and the iPhone publication gate remain open.

## Published Windows and macOS updates

[Windows 0.5.2](releases/windows-v0.5.2.md) (`windows-v0.5.2`) and [macOS 0.5.1](releases/macos-v0.5.1.md) (`macos-v0.5.1`) advance each desktop platform's version independently (Windows `0.5.1 -> 0.5.2`, macOS `0.5.0 -> 0.5.1`) from build commit `5c586d576103d23abb0c381b2e45acfa2d31e39d` ([build 42482977553](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42482977553)), synchronizing the cross-platform subscription, multi-depot, live catalogue (`LiveCatalogParser`, `lives[].api` script live sources, `proxy://?do=live&type=txt&ext=` directory unpacking, Base64/encrypted playlists), TVBox / Yingshicang (`jar` fallback, `parses` JSON parser fallback, `ua`/`ext.header` extraction, GZIP config payloads), HTTP T4, DRPY, CatVod JS, Python Spider session/proxy, ported Guard sources (`Dm84`, `Auete`, `Bttwoo`, `T4`, `FY`), and macOS native borderless fullscreen playback.

Previously, [Windows 0.5.1](https://github.com/Pilipala9919/MarcoMovie/releases/tag/windows-v0.5.1) was published from `56b2eb80b93bae98b8754952d779bff1b7a9582a` after [build 42356451432](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42356451432) passed 83 Flutter tests and produced the installer/portable packages. Downloaded packages passed checksum/ZIP checks, the app and installer report 0.5.1, and all six uploaded package/source/checksum files match the local verified bytes. Native fullscreen UI evidence is recorded in `desktop-fullscreen-2026-11-07.md`.

The mirror deployment at commit `fe533ad` passed Cloudflare Pages checks. Live checks confirmed the two Windows download URLs, SHA-256 files and platform update feed. Existing CSS, the iPhone 0.5.0 download and legacy Android update channel are unchanged. No iPhone 0.5.1 release was created; its workflow artifact remains validation-only under the gate above.

## TV seek follow-up

Remote left/right taps remain 15 seconds. After a 500 ms hold delay, preview speed starts at 30 playback seconds per held second and increases linearly by 30 per second, capped at 240. The target uses elapsed time rather than key-repeat counts. Release commits the target once; cancel/back aborts, reversing direction resets acceleration, and targets clamp at the media boundaries. The status displays the current preview speed. Twenty-four seek checks cover the curve, cap, jitter, symmetry, cancellation and boundaries; this is not physical remote acceptance.
