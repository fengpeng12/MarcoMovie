# Mobile fixes under validation — 2026-11-07

These checks were first recorded on the repair branch before platform-specific releases. See each release's notes and build commit for its published scope.

## Changes

- Android: keep the full brand readable on narrow screens; bind the five-tap privacy entry, separate app configuration/preferences, and exclude private playback/search records and downloads from the public UI. PIN confirmation is cancellable and salted; this is not filesystem encryption or a sandbox for third-party plugins.
- Android: expose video filters, cache successful home data for five minutes, retain the home view when returning from details, reject stale category/live responses, and retry failed pages without skipping ahead.
- Android player: use the active playback source to decide whether to hide seeking. A previously browsed live catalogue must not hide a later VOD timeline. Respect display cutout and system gesture insets around controls.
- iPhone/shared Flutter: keep source controls in the header row, increase primary settings rows, use the existing Glasswork surface for the PIN pad, and include unsupported routes in source search/group results with their status intact.
- Keep actual episode/provider metadata. Do not manufacture cloud providers, MKV filenames, file sizes, or 4K labels from ordinary direct links.
- Live HTTP: preserve distinct HTTP/network/format errors, close cancelled requests, and strip credentials case-insensitively on cross-origin redirects.

## Evidence and limits

- 30 focused Flutter checks passed: header/modal layout, PIN material, settings size, source preference/search, deletion races and source metadata.
- 19 live parsing/HTTP checks plus redirect credential and cancellation checks passed. PIN verifier checks passed.
- Four native ELF/ZIP validation tests passed; these validate the checker, not a finished CatPaw runtime.
- Native phone/TV APKs and the layout instrumentation APK build locally. Instrumentation has not run on the reported phones.
- [Android 16 emulator run 42353338253](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42353338253) passed on commit `5de7cb5`: the production player page retained a visible timeline after live browsing, rotated to landscape/reverse landscape/portrait, and accepted pointer seeking in all three orientations. Screenshots were inspected. This fixture uses local silent WAV media and the Android system player; ARM native libraries are omitted from its test-only x86 APK. It is not video decoder, CatPaw, or Redmi firmware acceptance.
- A host Java request/parse check read five remote live catalogues from the user-supplied subscription. This does not establish Android TLS behavior or playable streams. The local plugin-proxy catalogue is a separate unverified path.
- Reported devices: Xiaomi 14 Ultra / Android 16 (live source failure), Redmi K80 Pro / Android 16 (landscape timeline absent). No physical-device result is recorded for these fixes.
- The remaining plugin ports and CatPaw 16 KB runtime/device validation are incomplete. The owner subsequently authorized independent platform versions: verified fixes may release separately without claiming those outstanding adaptations are complete. iOS 14.5 physical-device testing remains deferred by the owner.
