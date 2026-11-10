# Subscription and Android 6 regression work

This records implementation and validation on the repair branch. It is not a release announcement or a claim that every imported source plays.

## User-visible fixes

- Listing redirects containing a numeric catalogue ID now search by the visible film title. A real numeric title remains valid. The Android phone/TV route and shared Flutter title extraction are covered separately.
- Home uses one history shelf, with the latest entry first. The TV's separate resume section has been removed; the existing resume actions and saved position remain intact. The stored preference key remains compatible with older backups.
- Subtitle and intro/outro adjustment use the application's own callback type instead of `java.util.function.IntConsumer`, which is absent on Android 6. The bytecode check covers all compiled application classes, not just a source-text match.

## Subscription changes

- UTF-16 BOM text, content-based PHP responses, single-site JSON and root site arrays are recognized. PHP is an HTTP endpoint: its response determines which parser is used.
- Local ZIPs can contain a configuration, a playlist, or an unambiguous Spider script entry with sibling modules. Ordinary JSON helper data and README files do not take precedence over a script. The Flutter archive budget is checked before candidate contents are decompressed.
- Relative HTTP playlist paths resolve against their origin. Plain error CSV text is not accepted as a relative stream.
- Script hosts accept CommonJS/JSON helpers and named/default ES module exports. Android's pinned QuickJS wrapper drains Promise jobs between evaluations, allowing asynchronous initialization and Spider methods that settle locally. Unsettled timers/event-loop work and unsupported Node modules fail explicitly.
- Compact and side-effect ES module imports, re-exports and content-identified PHP script responses use the same local host. Module dependency discovery skips comments and string contents.
- The shared Python adapter expands byte/URL codecs and HTTP request/response behavior, including `requests.Session`, scoped cookies, redirects and session isolation. Compatibility is exercised through the real embedded engine, rather than checking only whether a `.py` file imports. Multipart uploads, streamed responses, proxy adapters and native Python extensions remain outside this host's implementation.
- Script HTTP requests retain authentication on same-origin redirects and clear sensitive headers when the protocol, host or port changes. URL user information becomes Basic authentication and is omitted from the returned URL.

## Verification boundaries

The checked-in tests use local/synthetic inputs and local HTTP services. The API 23 emulator workflow exercises production settings/player subtitle controls, history layout and QuickJS/Python JNI. Its application fixture has identical production bytecode but only the x86 QuickJS library; it does not validate ARM video decoding or CatPaw Node.

The CatPaw rebuild separately applies libuv's existing pre-Android-7 barrier fallback to fix the API 23 linker failure. A successful source build and ELF alignment check are prerequisites, not proof of playback on a 16 KB device.

Still incomplete: the 33 proprietary plugin route ports, custom DRPY forks and proxy contracts beyond the pinned engine, arbitrary CPython/native packages, and actual supplied-source playback on iPhone. Lite has standard CMS support but no general JS/Python/JAR runtime. The [iPhone publication gate](ios-source-acceptance.md) remains in force; do not publish the validation IPA as a completed compatibility release.

## Local DRPY engine and device regression update

A pinned local DRPY engine now handles standalone rule documents, explicit `csp_Drpy` entries, JSON rule objects, content-identified PHP rule responses and local ZIP rule entries. Remote files merely named `drpy2.js` retain their original runtime; arbitrary forks are not silently replaced. The Android dispatcher and shared Flutter dispatcher retain the original source descriptors, avoiding incorrect CatPaw settings links for rule sources.

The engine uses a rebuilt, pinned dependency facade with recorded licenses. Three worker slots queue concurrent searches, preserve source-scoped storage, and enforce request/execution deadlines. HTTP helpers run inside the local host; default external OCR and fallback-image requests are disabled. Flutter local packages now preserve nested helper modules, and the shared host implements the pinned core's local proxy contract for text/byte-array responses. These changes do not establish arbitrary fork compatibility. An imported rule is not counted as a proprietary plugin port.

- [Android 6 regression at 3bffa67](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42363860911): all subtitle, home/history and source-host probes passed. The former callback fails with `NoClassDefFoundError` in the negative control; the fixed settings and player dialogs remain usable and retain their values. This is an API 23 x86 television emulator, not the user's Xiaomi firmware or an ARM decoder test.
- [Android 16 player regression at afe5b62](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42362306403): timeline visibility and pointer seeking passed in portrait, landscape and reverse landscape. This synthetic fixture does not validate a particular Redmi firmware or third-party stream.
- Shared router tests exercise the actual pinned DRPY core on Node 22 and Node 18 with JIT disabled. Flutter client tests cover import through catalogue/search/detail and multiple returned media qualities using local HTTP fixtures. They do not replace iPhone installation/playback acceptance.

The 16 KB source build is a separate validation path. Large-page startup remains blocked unless an APK includes capability evidence matching the actual Node, bridge and C++ library hashes. ELF alignment alone does not establish runtime behavior on a 16 KB device.

## Reviewed Dm84 adapter and embedded runtime evidence

Dm84 now has a shared, parameterized implementation dispatched by Android and Flutter. Its endpoint constants are extracted as data from one exact reviewed imported JAR version. The bootstrap does not execute that JAR, Java bytecode, or native loader. Unknown artifacts remain explicitly unsupported on Flutter; Android retains its original local plugin host only after successful integrity validation and an exact unsupported-artifact or pre-start runtime-unavailable result. Invalid checksums, malformed bootstrap results and protocol errors do not trigger this fallback.

Each Flutter site retains its own subscription's plugin declaration and any site-specific override, including the original MD5 constraint. Reordering, merging subscriptions, backup and restart therefore cannot attach a route to a different subscription's global plugin. Import authentication is scoped to the download origin and is removed on cross-origin redirects.

The private Windows Flutter client check exercised the actual importer, shared bootstrap, pinned DRPY engine, home, two category pages, exact-title search, details and playback resolution using the imported plugin. A bounded 64 KiB media response returned HTTP 206 with an ISO-BMFF video header. This verifies the client and media retrieval path for one sample; it is not decoder, audio/video sync, seek, HLS proxy or iPhone playback evidence. Public fixtures contain no supplied endpoints, plugin binary or resolved media addresses.

[Embedded Node regression at a3347c0](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42366622265) passed all twelve behavior checks on API 23/4 KB, API 35/4 KB and API 35/16 KB: DRPY catalogue/filter/Unicode search/detail/play, CatPaw import/worker calls, and release/reopen. The initial 16 KB fixture failed while the linker loaded the bridge through Android's incremental installation path. Full installation fixed that failure with identical library hashes. This derivative contains the production application bytecode and the isolated Node libraries; it does not validate the full APK's other native decoders or Xiaomi firmware.

The proprietary-route ledger remains unchanged: these checks do not complete all 33 routes or satisfy the iPhone publication gate. The production runtime pin and capability packaging are tracked separately from this isolated runtime evidence.

## Auete follow-up and search failures

A second scoped shared adapter supports the reviewed Auete artifact, with independent adapter-specific cache/storage identity. Constructor and player constants are extracted only from exact reviewed code-item hashes; no constructor or page script is executed. A custom `ext.siteUrl` variant is explicitly unsupported by the portable adapter; Android retains its original local plugin path for that variant. The original imported site descriptor and subscription ownership remain unchanged.

Private protocol checks passed home/recommendations, category filtering and pagination, details, and HLS URL resolution. The media probe received a master playlist, media playlist and a bounded transport-stream prefix. **Actual search is incomplete:** the source returns a manual image-verification form even with its session cookie. The adapter returns `drpy_verification_required`, not an empty successful result. Synthetic local-server search tests do not override this real-service limitation; no iPhone or player decoding acceptance is claimed.

Search UI retains healthy results while distinguishing website verification, request failures and genuine empty results. Flutter clears per-source notices when the query, subscription registry or privacy session changes; cancellation suppresses late notices. Android TV stops spelling retries once website verification is required, and the phone/TV interfaces retain that status instead of reporting confirmed absence of matching content.

## Bttwoo follow-up and category filtering

A third scoped adapter implements the reviewed Bttwoo artifact's catalogue, search, episode and playback-address protocol locally. Its bootstrap reads only exact fingerprinted constant arrays from the imported artifact. The implementation does not execute the original Android loader or evaluate website scripts. Private shared-host checks exercised the six source methods, two category pages, a valid HLS playlist and a bounded transport-stream prefix. These checks do not establish decoder, seeking or physical-device acceptance.

Auete and Bttwoo keep source-specific state separate from Dm84 even when all three originate in the same imported JAR. Unsupported artifact versions and nonempty custom site URL variants are not silently redirected to a different source. Android retains its existing local plugin path for unsupported variants; Flutter reports the limit explicitly.

Source-delegated category filters are no longer applied a second time against incomplete video-card metadata. For example, an opaque source value such as `dzp` need not appear in a film title or synopsis. The Flutter client and home page preserve the returned page and its actual empty state; they do not fabricate matches or probe a later page to disguise an empty source response. Static local playlists retain their ordinary metadata filtering.

The Auete adapter maps a category's declared genre label to its own filter value, and leaves an already-valid value unchanged. Auete's unsupported region/year filters and Bttwoo's unsupported subfilters return an explicit error. The exact synthetic empty-category row inserted by the pinned DRPY core is normalized to an empty list; arbitrary source rows with a similar ID are retained.

## T4 configuration and Python transport follow-up

The shared T4 adapter handles two supplied entries by extracting their encrypted
extension configuration as data from an exact reviewed artifact. No imported
native loader is executed. Flutter and Android pass that configuration with the
original subscription ownership; distinct extensions cannot reuse another
site's generated rule. Bounded host requests, strict configuration fields,
actual CMS pagination and opaque identifiers have regression coverage.

The private Flutter client reached catalogues, details and sampled HLS manifests
for both entries. One entry's search requires website verification; an earlier
media request on the other entry returned HTTP 403. These outcomes remain
distinct from client parsing errors and do not count as iPhone playback
acceptance. The separate Appgz protocol experiment is not enabled in application
dispatch because its live catalogue/episode/media path remains unverified.

Python Session cookies retain object attributes and binary request bodies are
preserved across Flutter/Android transport. The [iPhone evidence and remaining
gaps](ios-source-acceptance.md) record the native simulator checks, missing Python
dependencies and the follow-up source-scoped session lifecycle repair. The original 33
route acceptance obligations remain open; adding a protocol adapter does not
complete that ledger.
