# Experimental Flutter / CPython coexistence probe

This creates a separate disposable Flutter app, not Marco Movie. It never routes
user subscriptions to CPython or changes the production app or release workflow.
The source-session bridge accepts **only the bundled `synthetic-v1` fixture**. A
separate `transportProbe` runs another fixed bundled module against two owned
loopback servers. Neither entry accepts arbitrary code, modules, native libraries,
external source endpoints or filesystem paths.

Run on macOS with the reviewed Flutter **3.38.9**, Xcode/iOS Simulator and CocoaPods:

```sh
python scripts/ios_cpython_flutter/run_flutter_probe.py \
  --arch arm64 --output-dir /tmp/cpython-flutter-results \
  --cache-dir /tmp/cpython-downloads
```

Use `--arch x86_64` on an Intel Mac. `--udid` can select an available iPhone
simulator; otherwise the shared runner selects the oldest available iOS >=14.
`--stage-only` is possible on other hosts, and deliberately reports `passed:false`
and `runtime_tested:false`. It cannot establish iOS or Flutter acceptance.

The runner imports `scripts/ios_cpython/run_cpython_probe.py` for the same locked
CPython SDK/wheels, safe extraction, framework mapping/signing and app-specific
simulator diagnostics. It imports `prepare_catpaw_runtime.py` for the existing
pinned Node18 iOS runtime. The production CatPaw native bridge and QuickJS package
are copied to the new temporary project; the source checkout is not modified.
All source hashes and dependency inputs are recorded. No framework binary is
committed here. Only this disposable app is terminated after results/timeouts.

The experimental MethodChannel exposes capabilities/open/call/release, unguessable
session handles, two own-GIL subinterpreters and explicit method/argument gates.
Each fixture source has a separate interpreter and Spider instance; calls are
serialized on one native worker thread. Python source-created threads are disabled
in this narrow experiment. Source calls do not expose cancellation or claim a hard
budget; the additional transport probe only cancels its registered HTTP waits.
Python and its native extensions still share the process/app permissions.

The Flutter app starts the existing local embedded Node18 bridge and executes
QuickJS through its real Dart FFI package. Node serves only synthetic localhost
catalog/search/detail/player/binary data. Native CPython requests/bs4 traverse all
six Spider methods; a binary proxy callback verifies exact non-UTF8 bytes, headers,
status and retained same-instance state. This first probe tests the callback
contract, **not a media-player proxy lease or actual media decoding**.

Checks also cover method/source/origin rejection, opaque handles, capacity,
isolated module state, exceptions without session corruption, release/stale-handle
behavior, recreation, and continued Node/QuickJS/UI operation. Validation requires
all 42 original named checks, each uniquely true, actual Python 3.14.10,
Node18.20.4 and the selected native architecture. The added transport probe below
adds 18 required checks. An aggregate passed flag is insufficient.

The same built app runs twice in separate processes: Python first, then Node
first. A fixed signed fixture-order resource selects the order; the non-starting
capability query verifies lazy Python initialization. Both runs record actual
SIGPIPE/SIGINT states before/after Python and after Node/QuickJS, retain separate
results and must pass. The original source fixture rejects HTTP redirects and
never follows its deliberate off-loopback redirect negative case. The separate
transport fixture exercises requests-driven redirects only within its two
host-provided loopback origins.

## Added HTTP transport probe

After the original source sessions are released, a fresh own-GIL interpreter
executes the bundled `transport_fixture.py` with the real
[requests adapter](../ios_cpython_transport/README.md). Its C callable converts
bytes to standard typed data, releases its owning Python thread state, and posts
an asynchronous MethodChannel request. The Flutter main thread performs bounded
HTTP work without waiting synchronously for Python. The completion callback
handles only native values; Python objects are created after the owner resumes.

`cancelTransport` is handled outside the Python worker queue. It settles a
registered HTTP wait once and asks the request-owned Dart client to close. Late
callbacks cannot complete the old wait again. This cancels this transport's I/O;
it cannot interrupt arbitrary Python bytecode, extension functions, or raw sockets.

The 12 Python-side checks cover real Response objects, bytes, JSON/form bodies,
duplicate cookies, path/Secure rules, cross-origin inherited credentials versus
new destination cookies, deadlines, actual cancellation, recovery, and close.
Six Flutter-side checks require a live UI heartbeat, the native cancellation
acknowledgment, drained HTTP tasks, clean fixture servers, and surviving Node and
QuickJS state. Reports retain the original 60 unique passing checks per launch
with a matching nested 12-check transport inventory. These are
new requirements, not a claim that the earlier 84-check run covered this transport.

The Dart client disables automatic redirects and decompression and returns
multi-valued parsed headers. Its parser normalizes field names/grouping and may
resolve framing before headers reach the adapter; the component documents those
limits. Only the injected loopback token paths are reachable in this experiment.
No external HTTPS, user-source networking, or production session lifecycle is
accepted by these checks.

Artifacts: `inputs.json`, app-emitted `app-result.json`, host `result.json`,
`diagnostics/`, and a local `build.log` for compile failures. SDK/App directories
are test build outputs only. The existing `ios-runtime.yml` workflow can run this
manually with `experiment: cpython_flutter` and the desired `probe_arch`. It first
checks simulator availability and uploads only JSON evidence, app-scoped
diagnostics and the build log. Push events do not run this experiment. It does
not upload an application or publish a release.

Host-only protocol/validator checks:

```sh
python scripts/ios_cpython_flutter/local_checks.py \
  --node /path/to/node18 --cache-dir /tmp/cpython-downloads \
  --output-dir /tmp/cpython-flutter-host-checks
```

Still unverified until separately exercised: actual iPhone/iOS14, background
resume, player memory/threads and playback leases, arbitrary user Python sources,
native third-party wheels, secure filesystem isolation, and hard cancellation of
Python/native work. Existing production script runtimes remain unchanged.

## Shared source-loader integration

An additional 29 required checks execute the shared `NativePythonSource` loader
and the product `PythonHttpTransport` in this real Flutter/native process. A
bundled memory package supplies relative modules, a JSON resource, all seven
Spider/proxy operations and `liveContent` returning JSON or raw M3U text. The
same source is retained through playback resolution and actual HTTP GET/HEAD
binary proxy requests. Two same-name packages run in separate interpreters;
release revokes the old proxy URL, even after a new source is created.

The suite now requires 89 uniquely passing checks per launch, 178 per CPU over
both launch orders. This is a new acceptance target, not a reinterpretation of
the older 120-check result. Input manifests hash the shared Python files and
product Dart transport separately. The experiment accepts only the bundled
`native-source-v1` package and does not open arbitrary-source production routing.

## Recorded simulator result

[Run 42407978951](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42407978951)
at `fc2eaef` completed successfully on ARM64/iOS 18.5. Python-first and Node-first
launches each passed all 42 unique required checks, for 84 in total, with actual
CPython 3.14.10 and Node 18.20.4. All 112 recorded repository-input hashes match
that exact commit. Both launch orders preserve the other engine's SIGINT state
and leave SIGPIPE ignored. The bounded readiness observation preceded the app
run; it was not counted as an application check. Intel Flutter execution and the
production/physical-device limitations above remain unverified. This result
predates the added HTTP transport probe and does not enable arbitrary Python
subscriptions in Marco Movie.
