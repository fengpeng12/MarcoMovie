# CatVod JavaScript profile

This is a bounded, app-owned implementation of selected `catvod` ES module APIs.
It is not the complete FongMi host and does not make arbitrary JavaScript, Android
JARs, or Node packages portable. Existing short-name Spider, Cat, Python, and DRPY
entrypoints retain their own behavior.

The protocol was checked against [FongMi TV's module implementation](https://github.com/FongMi/TV/tree/4512b4c9f82534ff66acfde06ccdd68f35b074f0/quickjs/src/main/assets/js/lib)
and [CatVodSpider's development contract](https://github.com/FongMi/CatVodSpider/blob/0454bea588bc75f488bac6b4773eb26c13d7c43c/docs/development.md).

## Implemented surface

| Export | Behavior |
| --- | --- |
| `Spider` | One instance, bound prototype methods, opaque `siteKey`, `this.net`, full catalog/search/detail/play methods, `proxy`, `proxyUrl`, `page`, and logging. Omitted catalog methods have the documented empty base results. |
| `net.req` | Promise resolving to status, headers and content. Transport, validation and unsupported-option failures return `{code:'',headers:{},content:'',error:...}`. HTTP errors retain their status and body. |
| `net.json` | Promise for decoded JSON; rejects transport errors, non-2xx status, malformed JSON and non-text buffer modes. |
| `proxyUrl(params, local)` | Generates this source's existing same-device proxy route. Parameters must have string values; `do` and `siteKey` are reserved. Only `local=true` is supported. |
| `page` | Validated pagination of an array, with an optional known total. |
| `md5X`, `sha256X` | UTF-8 string digests using the bundled CryptoJS implementation. The original MIT license is packaged with it. |

The existing complete-name entrypoint adapter supplies string page numbers and
detail ID arrays, preserves an original string `ext`, serializes an object `ext`,
and retains source `this`, returned values and Promises. `require('catvod')` is not
an ES import and is not provided. Static imports from nested modules work; internal
module names cannot be replaced by imported subscription content.

Normal idle source closure attempts the source's `destroy()` once with a 500 ms
budget, permits no new HTTP operations, and always releases the runtime. A failed,
cancelled or interrupted source is discarded immediately. This cleanup limit is
intentionally narrower than the upstream host's five-second hook.

## HTTP options and limits

Supported options are `method`, `headers`, `params`, `body`, `data`, `postType`,
`buffer`, `redirect`, `timeout`, `callTimeout`, and `cookie:false`. Unknown options
fail explicitly. This profile does not silently discard an unsupported setting.

- Methods: GET, HEAD (`HEADER` alias), POST, PUT, PATCH, DELETE, OPTIONS.
- Query values: finite string/number/boolean values; arrays repeat the key; null
  values are omitted. Existing query values are retained.
- Headers: string values, no duplicate case-insensitive names or CR/LF/NUL.
  Host, Content-Length and connection/framing headers are managed by the transport
  and cannot be supplied. Header input has a 32,768-character serialized limit.
- `data`: JSON by default, or an object of scalar form values with `postType:'form'`.
  The profile serializes these identically on each host.
- `body`: text or an array of integers 0–255, with an explicit Content-Type. It
  cannot be combined with `data`. GET/HEAD do not accept a body. Binary requests
  are transmitted as their original bytes, not as JSON arrays.
- `buffer`: 0 text, 1 unsigned integer array, 2 Base64, 3 actual ArrayBuffer.
  Binary responses use a lossless internal Base64 transport on both hosts.
- Text supports UTF-8, ASCII and ISO-8859-1/Latin-1. Other declared character sets
  fail explicitly; binary modes remain usable for arbitrary bytes.
- `redirect`: 0 or 1. Redirects to another origin remove inherited/forwarded
  credentials. Explicit request headers remain scoped to the initial request.
- `timeout`: positive integer milliseconds (default 10,000), additionally bounded
  by the host operation budget. A supplied `callTimeout` must be positive and may
  only shorten that budget. Unbounded calls (`callTimeout:0`) are unsupported.
  Each CatVod request has its own cancellation owner: one timeout does not close
  another request or a subsequent fallback. Closing the source cancels all of them.
  Timing is not identical to upstream's separate connect/read/write deadlines:
  Flutter additionally treats `timeout` as a whole-request limit; Android uses
  it for connection/read inactivity, capped at 20 seconds. Android currently has
  no separate write-inactivity timer; uploads remain bounded by `callTimeout`
  and the source operation deadline. Matching the upstream per-phase semantics
  remains a compatibility gap, not a completed part of this profile.
- Request/response body cap: 6 MiB, additionally subject to the runtime memory and
  operation limits. Requests share the host's per-operation count limit.
- There is no implicit cookie jar in this profile. Explicit Cookie headers work;
  `cookie:true` fails because shared WebView Cookie integration is not implemented.

The module captures the host's request and proxy functions before source code runs.
It does not change the existing global `req` API. No Node or filesystem capability
is exposed by importing `catvod`.

## Not implemented

No empty implementations are supplied for Local persistence, HTML query plans,
network sessions/Cookie APIs, TTL caches, batch/map, streaming response handles,
WebSockets, downloads, isolated `js.eval`, dialogs, WebView actions, live danmaku,
WASM, Chinese script conversion, AES/DES/RSA, or secure random generation. The
private upstream `catvod:host` module is not exposed. The existing bounded proxy
supports ordinary text/byte responses and Range/HEAD, not upstream stream handles.

The same-device proxy retains source state while a player owns its lease, revokes
the route when a subscription is removed or its runtime is discarded, and does
not infer an upstream URL for relative HLS paths.

## Validation

`scripts/test_catvod_profile.cjs` evaluates the actual shared module with owned
local HTTP fixtures. `flutter/test/catvod_profile_test.dart` exercises real QuickJS,
the Dart HTTP transport, nested imports through CmsClient, binary and Range paths,
strict failures, cancellation, source destruction and subscription removal.
Existing script/proxy lifecycle tests must also pass. Device-native checks and
physical-device acceptance are separate evidence; host Node tests alone do not
establish iPhone or Android behavior.

The complete local Flutter suite passes 279 tests, including 13 new CatVod
checks. Shared-module checks pass on Node 22 and Node 18 with JIT disabled.
The Android transport adds 22 real-socket JVM checks; its earlier 16 player,
13 HTTP and 46 proxy checks also pass.

At commit `a89d6e0`, [Android 6 run 42408801667](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42408801667)
passed all 80 unique source-host checks, including the 13 new CatVod checks, on
the API 23 x86 emulator. Its 96 home and 25 subtitle assertions also passed.
Package hashes are the same-run build records; APK bytes were not uploaded for
independent rehashing. This is actual JNI execution, not an ARM device or decoder test.

[iOS native run 42408801642](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42408801642)
at the same commit passed all 200 unique checks on both ARM64/iOS 26.2 and
x86_64/iOS 18.5 simulators, including eight new CatVod groups. Both reports'
32 production and 15 fixture input hashes match that exact commit. The CatVod
native fixture supplies a synthetic HTTP bridge; real Dart HTTP is covered by
the separate local Flutter tests, not by this native fixture. None of these
results establishes physical iPhone playback or every external subscription or
plugin route.

[Full iOS build 42408802415](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42408802415)
at `a89d6e0` also passed all 279 Flutter tests. Independent inspection of its
unpublished validation IPA verified ZIP integrity, all four declared JS host
assets (including the crypto license), 19 pinned DRPY assets, exact shared
Python/Node host bytes, and 37 device-arm64 Mach-O images targeting iOS 14 or
earlier. The QuickJS operation-deadline export is present. The IPA is 35,315,507
bytes, SHA-256 `1ddc12ae34cc5d63833a3828f047dbc5f2ad1490be84fdcee6b56e280a7a4f7d`.
Package inspection does not establish minimum-OS runtime or physical playback.
