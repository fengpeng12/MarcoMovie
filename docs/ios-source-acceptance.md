# iPhone subscription release gate

The owner requires working TXT, JS, JSON, Python, PHP endpoints and local packages before the next iPhone package is published. This includes the previously requested multi-repository subscriptions, authenticated CatPaw `.js.md5`, Emby, and outstanding plugin routes. All runtimes must execute locally; a desktop/Android bridge is not an acceptable substitute.

This is an acceptance checklist, **not a declaration of compatibility**. The 0.5.1 IPA produced by workflow 42403618700 is validation-only and must not replace the official 0.5.0 iPhone download.

The current validation build at `4a05051` passed all 255 Flutter tests. Its IPA
SHA-256 is `ac6beefa350743bde9e171ffcb1c4b3726e90a72bdb0f1d76c096da5bb1f2c76`.
Independent package inspection verified ZIP integrity, 19 pinned DRPY assets,
the exact shared JS/Python host assets, 37 device ARM64 binaries with deployment
targets no newer than iOS 14, and the exported native execution-deadline symbol.
[Native runtime run 42404468117](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42404468117)
at `f2af2ae` passed 188 unique checks on each of ARM64/iOS 26.2 and Intel/iOS 18.5;
all 29 production and 11 fixture input hashes matched that commit. The prior
Intel proxy check exhausted a previous operation's test budget; the follow-up
renews the same eight-second budget before that separate test. Neither these
simulator results nor the validation package establish physical-iPhone playback
or complete the source-specific release requirements below.

| Input | Existing implementation | Evidence still required before release |
| --- | --- | --- |
| TXT / M3U | Content-based playlist parsing | Actual supplied playlists load their groups/channels and play on iPhone, including relative URLs and required request headers |
| JSON / XML | CMS interfaces and subscription configuration parsing | Supplied subscriptions complete catalogue, search, detail, episode selection and playback; failures of individual sites stay distinguishable |
| JS | QuickJS Spider / ES module host; local CatPaw host for matching packages | Requested scripts, modules and synchronous DRPY APIs work end to end; script import alone is insufficient |
| Python | Skulpt Spider, requests / bounded JSON, read-only package data, local and asynchronous remote sibling modules, local proxy callbacks | Requested Python modules and parser dependencies work; lxml/native extensions/full CPython are not currently claimed supported |
| PHP / extensionless endpoints | Fetch endpoint and parse its actual response content | The supplied endpoint is reachable and its actual configuration/API format works; `.php` does not identify a client-side executable format |
| Local package | ZIP entry configuration, relative script/module paths and lists; Flutter DRPY packages retain nested local helpers and JSON data | Each requested package's entrypoint, dependencies, files and playback resolve on iPhone without an external device |
| Multi-repository | Nested warehouse import and ownership | The supplied warehouse and selected child subscriptions pass the same playback checks, not just directory import |
| Authenticated `.js.md5` / CatPaw | Authentication, digest, local service host and proxy integration | Actual supplied service package completes local startup, catalogue, search, detail, playback/proxy and restart on iPhone |
| Emby | Login, libraries, episodes, playback negotiation and progress reporting | Real server/session playback on iPhone with the required direct/transcode and progress behavior |
| Android / Guard plugins | Selected explicit portable adapters; reviewed Dm84, Auete, Bttwoo and T4 paths are scoped to exact imported artifact versions | All 33 routes still require individual platform/playback acceptance. Auete and one T4 search path currently require manual website verification; Appgz remains experimental and is not enabled in application dispatch. Partial protocol/media-prefix checks do not complete this gate |

For each representative source, retain separate results for import, catalogue/search, detail/episodes, resolved media, actual playback and application restart. Record the tested iPhone/iOS and package version. Mark a source as incomplete if only its file type or catalogue is recognized. Do not hide incomplete sources or relabel an ordinary HTTP adapter as a plugin port.

The user's supplied configuration/service URLs and authentication details remain private test data. Dead endpoints, unavailable content or authentication requirements must be recorded separately from parser/runtime failures, rather than silently reported as successful adaptation.

Remote Python dependencies now load on demand from the entry script's directory,
including package `__init__.py`, nested modules and imports first reached during
detail/playback. They use the source's existing bounded HTTP transport, preserve
same-origin request headers and strip credentials on cross-origin redirects.
Local packages never fall back to remote module lookup. Modules are retained only
inside their source session; cancelled loads cannot populate a replacement
session. Local HTTP/QuickJS fixtures cover these behaviors. Real supplied sources
and physical playback remain separate acceptance requirements.

The general [script proxy bridge](script-proxy-compatibility.md) retains the source
instance while the player uses it, preserves binary callback bodies and handles
request cancellation without silently reusing a stale playback address. The
[package reader](python-io-compatibility.md#imported-package-files) supplies
read-only script-local files. These are shared protocol capabilities, not a list
of copied media URLs or a declaration that every plugin now works.

An [isolated CPython experiment](../scripts/ios_cpython/README.md) evaluates a
full native interpreter and locked pure-Python dependencies. It is separate from
the product runtime; its simulator results do not enable full CPython support
in the application or satisfy the release gate above.

## Embedded runtime follow-up

The production iOS Node startup implementation is shared with a simulator-only native regression app. Its test scope is Node startup, real CatPaw workers, the jitless Fetch shim, DRPY catalogue/search/detail, nested local helpers, local proxy text/binary/range responses, and source reset/reopen. The workflow does not publish an IPA and must retain its actual result before being reported as passed. It does not exercise Flutter widgets, a physical iPhone, or video decoding.

The local DRPY proxy implements the pinned engine's three-element status/type/body contract. Text and byte arrays are accepted; unsupported response shapes fail explicitly. Playback URLs stay tied to their source, and active proxy playback is protected from background-source eviction. Closing the iOS host clears source workers/settings sessions without terminating the process-wide Node runtime; failed cleanup must be retried before loading new sources.

The same simulator fixture also compiles the production iOS QuickJS bridge and
loads the production Python adapter assets. It checks ES modules, Python sibling
modules, asynchronous response handling, byte codecs and the native execution
deadline. Its Python HTTP response is synthetic; the Node Fetch check uses a real
local socket. Neither is a claim of arbitrary native Python package support.

CatPaw and script detail responses may omit catalogue IDs and metadata. The
client now merges those responses with the selected catalogue item, retaining its
identity for history/reopen without replacing returned episode lists. Non-Error
script exceptions retain their original failure instead of producing a Dart cast
error.

CatPaw signed media routes under `/spider/<site>/<version>/proxy/` now retain
their source-scoped local address, signature query, relative HLS segments and
keys. Only GET/HEAD playback access is allowed through this additional route;
normalized traversal and management paths remain rejected. Private checks on the
supplied package reproduced a local `route_not_exposed` failure and, after this
fix, retrieved the returned HLS manifest. This is protocol evidence, not decoder
or physical-iPhone acceptance. A different sampled route still returned an empty
playback URL; another returned HTTP 401. Those source results are not counted as
working playback.

## November 7 runtime and protocol evidence

[Native runtime run 42378486540](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42378486540),
at commit `6134540`, passed 24 checks on both ARM64/iOS 26.2 and Intel/iOS 18.5
simulators. In addition to Node/CatPaw/DRPY, it exercised production QuickJS and
Python cookie iteration and binary-body bridging. Python socket transport is
tested separately with local HTTP fixtures; its native probe response is
synthetic. Neither result establishes physical-iPhone video decoding.

The T4 follow-up at `19f993f` passed [28 native checks on both simulator
architectures](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42380192628),
including the generated adapter's catalogue, pagination, opaque detail ID and
local HLS-manifest request. [Full iOS build
42380195025](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42380195025)
also passed 172 Flutter tests and produced a validation IPA. The first attempt
was blocked by a CRLF/LF asset hash mismatch; asset generation now normalizes
the bytes and CI checks the manifest before building. No official iPhone
release was created by either workflow.

Python binary request bodies now cross the host boundary as bounded, validated
Base64 and are written as bytes by Flutter and Android. Session cookies expose
their names, values, domains, paths and flags without confusing same-name cookies
from different domains. These additions do not supply BeautifulSoup, subprocess,
native OCR or a complete CPython standard library. A subsequent scoped
[read-only HTML adapter](python-html-compatibility.md) adds the verified subset
of BeautifulSoup operations; it does not supply the remaining native modules.

The subsequent Flutter lifecycle fix keeps JS/Python state in a source-owned
isolate across catalogue, detail and the player's separate client instance.
Configuration, subscription identity and privacy scope form the session key.
Calls to one source are serialized; cancellation or failure discards that
runtime. Both the native deadline and Python execution clock restart per
operation; browsing time between calls does not consume the next call's budget.
Pending timers and transport
requests cannot leak into the next operation. Locking private space, removing
subscriptions and closing the shell release the corresponding sessions, while
generation checks reject source loads that finish after removal.

This is bounded in-memory state, not persistent cookie files: at most six source
contexts are retained, idle contexts may be evicted for a newly selected source,
and app exit clears them. Local Flutter regressions exercise real loopback HTTP
cookies and episode-cache continuity, separate subscription/private contexts,
deadline renewal, an idle interval exceeding Python's eight-second limit,
cancellation, close-while-busy and timer cleanup. Native iOS
and full-build evidence for this new change must be recorded separately; the
earlier `19f993f` checks do not cover it. FY still needs its actual parser/module
and verification flow, so this lifecycle repair does not enable that route or
establish arbitrary Python-source compatibility.

[Runtime run 42384846761](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42384846761)
at `f4c2aae` passed 30 checks on both ARM64/iOS 26.2 and Intel/iOS 18.5,
including renewed native and Python operation clocks. The earlier `53bad49`
full-build test exposed Python's clock counting idle time between calls; an
8.2-second idle interval reproduced it locally before the fix. The earlier
Intel run at `37fcab4` timed out during simulator installation, before app tests;
the successful new run retains separate evidence rather than counting that
setup failure as a pass.

[Full iOS build 42384849189](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42384849189)
at `f4c2aae` passed 179 Flutter tests and produced a validation IPA. Independent
inspection verified its checksum/ZIP integrity, 17 pinned DRPY assets and the
shared host/Python assets, 37 arm64 iOS binaries with deployment targets no newer
than iOS 14, and the actual exported `_jsSetOperationTimeout` native symbol.
The IPA SHA-256 is
`623a54d4f9018b3270305999ab530343c69ee85c65ff5ff9d84773198b74da6a`.
This validation package predates the subsequent Dart exit-listener cleanup;
that cleanup has separate local full-suite/focused lifecycle coverage. No
official release or mirror installer update was made. Remaining plugin routes,
Python dependencies and physical-device playback acceptance still apply.

T4 now extracts each site's encrypted extension as data from an exact reviewed
artifact, then runs the CMS protocol in the local DRPY worker. Pagination and
opaque catalogue/episode identifiers are retained. The original T4 category
contract does not forward extended filters, so unsupported filters are reported
explicitly. A private Windows Flutter client check retrieved catalogues, details
and HLS manifests for two supplied entries; one search still required website
verification. A separate earlier media request returned HTTP 403. These sampled
results are not full stream/decoder or iPhone acceptance.

Appgz's original encrypted protocol has a separate experimental implementation
and synthetic tests. It is distinct from a similarly named CatPaw entry. Actual
upstream requests have not completed the catalogue/episode/playback path, so it
is not advertised or enabled by the application's portable-adapter dispatcher.

## Read-only Python HTML follow-up

The shared Python host now supplies the documented [HTML subset](python-html-compatibility.md)
on Android and Flutter. Twenty oracle outputs match CPython/BeautifulSoup 4.15.0;
the Node 18 no-JIT regression also checks malformed selectors and bounded input,
node and result counts. The full local Flutter suite passes 181 tests, including
actual Python import, loopback HTTP catalogue/detail/play and retained DOM nodes.
Native iOS/Android coverage for this change remains pending until its workflow
results are recorded. FY's files, remaining modules, verification flow and plugin
dispatch are still incomplete; this does not increase the accepted route count.

The preceding lifecycle-only [iOS build 42386308316](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42386308316)
at `3c9c449` succeeded. Its validation IPA is 35,172,252 bytes with SHA-256
`09ce8f1fd499869fd8d5b9511288cb39d6851c62e8a3d14a239b7628aed9314a`.
ZIP integrity, all 17 manifest assets, source-host bytes against that exact
commit, 37 device ARM64 Mach-O images and the exported renewed-deadline function
passed inspection. It includes the exit-listener cleanup but predates the HTML
adapter. It remains unpublished and is not physical-iPhone acceptance.

The HTML adapter at `0b78d7d` passed all 50 checks on Intel/iOS 18.5 in
[runtime run 42387422689](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42387422689).
Its production and fixture hashes match that commit. ARM64 timed out while
launching the simulator app, before any check result; it is not counted as a
pass. [Android 6 run 42387422660](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42387422660)
found the packaged HTML library exceeded the Java host's one-MiB asset-read
limit. The follow-up allows two MiB only for that exact bundled dependency;
remote script/response limits remain unchanged.

An exact-method FY regression then found an additional missing `re.sub` call
that the original detail method swallowed, producing an empty list. The shared
host now has bounded string substitution and 14 independent CPython oracle
outputs. Six private fixture cases using four unchanged FY methods match the
original parser's metadata and line/episode binding after this repair. They do
not execute the original module's file imports, initialization, verification or
live requests, and do not establish that FY is usable end to end.

The follow-up at `3589662` passed all 51 native checks on both ARM64/iOS 26.2
and Intel/iOS 18.5 in [runtime run 42388317399](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42388317399).
All production and fixture hashes were verified against that exact commit.
[Android 6 run 42388317453](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42388317453)
passed the subtitle/home probes and all 23 source-host checks. This confirms the
bundled dependency read-limit repair on API 23, not ARM media decoding.

[iOS build 42388319104](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42388319104)
also succeeded at `3589662`. Its unpublished validation IPA is 35,176,777 bytes,
SHA-256 `a6b90a47f0d228a37976a172d7c0cd10267c01554a304b1c44c260f979f85545`.
ZIP integrity, all 17 pinned assets, exact host/Python bytes, 37 device ARM64
images and the exported renewed-deadline symbol passed inspection. It predates
the experimental FY protocol below and is not an official iPhone release.

## Experimental FY protocol

FY now has a separate [local protocol implementation](fy-port-status.md).
The reviewed imported artifact is read only as data to extract its origin and
parser configuration. No Android DEX, native library or original Python module
is executed. Seven data-contract tests and nine production-host tests pass
under Node 18 without JIT, including catalogue/detail/play, persistent scoped
cookies, parser fallback, manual image-verification actions and redirect limits.
The same synthetic protocol fixture passed in the iOS native probe at
`39e6adf`: [run 42390812235](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42390812235)
passed all 60 checks on ARM64/iOS 26.2 and Intel/iOS 18.5, with every recorded
production/fixture hash checked against the exact commit. Its nine FY checks
cover image verification, retained cookies, catalogue/detail and parser/HLS
manifest requests. They do not exercise a real external service or decoder.

The subsequent Flutter change enables the exact FY aliases and provides a
user-operated Glasswork verification dialog in home/detail/search/player error
states. The full local Flutter suite passes 194 tests, including 12 new response,
interaction and retry checks. Search retries only the verified source; filtering
keeps its current selection. Dismissing/removing the owner cancels the dialog's
requests and ignores late results. No background request opens it automatically.
Android's native dispatcher/interface and live-source/device acceptance remain
outstanding. The Flutter interface requires its own full iOS build evidence;
the preceding native probe must not be used as UI acceptance.
Current anonymous upstream attempts fail during connection establishment.
These implementation and fixture results do not increase the accepted count
of the original 33 playable plugin-route obligations.
