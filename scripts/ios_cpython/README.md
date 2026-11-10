# Experimental iOS CPython probe

This directory is an independent, disposable native test application. It does not
change Marco Movie's existing runtime, application package, source routing or UI.
It contains no real subscription, account, external media or imported plugin code.

## Locked inputs

* BeeWare `Python-Apple-support` tag `3.14-b14`, Python **3.14.10**, iOS support tarball.
* URL: https://github.com/beeware/Python-Apple-support/releases/download/3.14-b14/Python-3.14-iOS-support.b14.tar.gz
* SHA-256: `703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee`
* Download size: 37,299,470 bytes.
* All eight pure-Python wheels and their transitive required dependencies are
  pinned by filename, version, immutable URL and SHA-256 in
  `pure-dependencies.lock.json`. The package license/metadata files are preserved.
* No `pip install`, wheel build, `.pth` execution, arbitrary source download or
  package entry point is used. The runner expands reviewed pure wheels itself.

The support package's actual header is Python 3.14.10; its framework Info.plist
still says 3.14.9. The native probe checks **Py_GetVersion()**, not that plist.
The upstream utility is actually `Python.xcframework/build/utils.sh`, despite
examples referring to `build_utils.sh`. This runner mirrors its packaging scheme
directly and records each extension's input hash and resulting paths.

## Run

Requirements for native execution: full Xcode on macOS, Python 3.10 or newer on the
host, an installed iPhone simulator runtime, and network access to the pinned
GitHub/PyPI artifacts. Neither a developer account nor a provisioning profile is
needed for the simulator; frameworks and the probe app are ad-hoc signed.

```sh
python3 run_cpython_probe.py
```

The host architecture selects arm64 or x86_64. Run this on separate Apple Silicon
and Intel Mac hosts to verify both simulator architectures. By default, the oldest
installed available iPhone runtime >= iOS 14 is chosen. To select a specific one:

```sh
python3 run_cpython_probe.py --udid SIMULATOR_UDID
```

Optional paths are local directories, not URLs:

```sh
python3 run_cpython_probe.py --cache-dir ./downloads --output-dir ./probe-output
```

Host-only checks (including Windows) are separate from native execution:

```sh
python3 -S local_checks.py --cache-dir ./downloads
python3 run_cpython_probe.py --stage-only --arch arm64
```

An unsigned/ad-hoc **device architecture build** can also be checked on macOS:

```sh
python3 run_cpython_probe.py --platform device --build-only
```

That command does not install on a phone and does not establish device acceptance.
The runner never uses signing identities or provisioning profiles automatically.
The optional `--identity` is an explicit codesign identity; it does not by itself
make a device app installable. In the existing `ios-runtime.yml` workflow, manually
select `experiment: cpython` to run the independent experimental job. The default
`native` selection preserves the existing engine validation. Push events never run
the CPython job; the two experiment modes have separate concurrency groups. No
Marco Movie application is built or released by this experimental job.
The `probe_arch` choice defaults to `both`; `arm64` or `x86_64` runs only the
selected experimental architecture when investigating a failure. Final acceptance
still requires both architectures, and the native-engine job ignores this choice.
Its two Mac runner labels are accompanied by recorded actual CPU architecture;
runner labels alone are not evidence that both architectures executed.

## What is exercised

`CPythonProbe.mm` starts CPython once on a dedicated native thread with isolated
UTF-8 configuration, no environment import paths, no site initialization or
bytecode writes, and an explicit app executable path. All CPython APIs are called
with the correct attached interpreter state. The app's main thread keeps a timer
running while tests execute.

`probe_fixture.py` runs only our synthetic protocol:

* io, os.path, JSON Unicode, hashlib, ssl and eight standard-library native imports;
* actual Apple `.fwork` loading of the extensions on iOS;
* a local HTTP server inside the same app process, including Chinese JSON POSTs,
  cookies, requests.Session, CSS selection through bs4's `html.parser`, and a
  finite network read-timeout test;
* a Python Spider ABI for home, recommendations, category pagination, search,
  opaque detail IDs, episode lists and player resolution;
* an eight-byte synthetic HLS prefix. It contains no real media segments and is
  **not a video decoder/playback test**;
* bundled certifi CA loading. This is **not an external TLS handshake test**.

Native checks additionally cover a cooperative Python-loop deadline, the fact
that a blocking C `sleep` outlives the trace deadline, an isolated own-GIL
subinterpreter importing the same pure dependencies, module-global separation,
return to the main interpreter, and a responsive UIKit main loop. The probe does
not finalize/reinitialize the process-wide runtime after each call.

The disposable host keeps `install_signal_handlers=0` and explicitly ignores
`SIGPIPE`, matching CPython's ordinary disconnected-write behavior without taking
over the host's `SIGINT` handler. Reports record the actual dispositions before
the policy and after Python initialization. Required regressions check native
closed-pipe `EPIPE`, Python closed-socket `BrokenPipeError`, and preservation of
the host's interrupt disposition. This closes an embedding policy gap; it does
not by itself establish the cause of any earlier intermittent simulator exit.

## Output and acceptance

Every invocation creates a new directory under `probe-output/` containing:

* `inputs.json`: archive/wheel/probe hashes, architecture, extension mappings and,
  after signing, framework binary hashes.
* `CPythonProbe.app`: the isolated native test artifact.
* `app-result.json`: emitted **by the iOS app**, containing interpreter version,
  detailed checks, loaded framework paths, dependency versions and limitations.
* `result.json`: host phase, selected simulator/runtime, actual host/runner CPU,
  `GITHUB_SHA`, GitHub run ID, result and failure data.
* `diagnostics/`: only this probe app's recent crash reports and process-filtered
  system log, native stderr/faulthandler and per-import/check progress, if available.
  CrashReporter collection is limited to files named for this app. CI uploads
  these and the evidence JSON files; it does
  not upload the SDK, support archive, Python wheels or whole app.

Native acceptance requires process exit zero, `result.json.passed == true`,
`runtime_tested == true`, the actual pinned Python version/architecture, and at
least 40 uniquely named, individually true checks including every required check.
The runner independently validates the app report, its iOS fixture platform and
all executed dependency versions; an aggregate `passed` flag is not sufficient.
`staged_only` and `compiled_signed_only` deliberately keep `passed: false` because
they provide no runtime acceptance. Failures retain evidence and fail the command.
If no app result arrives, the native watchdog records a failure; the external
runner then ends **this test app**. It cannot safely kill just one Python source
inside a production application.

Even successful execution on a newer simulator does not validate physical iOS 14,
Flutter integration, Node/CPython coexistence, long-term memory behavior, real
subscriptions or native third-party extensions. `physical_device_tested` and
`flutter_integration_tested` remain false; the selected OS version is recorded.

## Known boundaries

* A CPython subinterpreter is not a security sandbox. Python and C extensions share
  the process and app filesystem permissions. A per-source directory does not
  prevent a script from reaching another file in the same app container.
* Trace callbacks can be removed and do not stop arbitrary C code, a stuck native
  extension, a blocking syscall or excessive allocation. Do not reuse this probe's
  timeout as a claimed hard execution budget. The production app cannot use iOS
  subprocess isolation as a general replacement.
* These wheels use bs4's standard `html.parser`; lxml and Crypto/PyCryptodome are
  absent. Native iOS extensions require separate device/simulator builds,
  frameworks, signing and multi-interpreter compatibility tests.
* PyCryptodome's native-loader code opens `.so` paths using ctypes/cffi. A normal
  Python extension's `.fwork` conversion alone does not adapt that raw loader.

Official references:

* https://docs.python.org/3.14/using/ios.html
* https://docs.python.org/3.14/library/intro.html#ios
* https://docs.python.org/3.14/c-api/subinterpreters.html
* https://docs.python.org/3.14/c-api/threads.html
* https://docs.python.org/3.14/library/signal.html#note-on-sigpipe
* https://github.com/beeware/Python-Apple-support/tree/3.14
* https://briefcase.beeware.org/en/latest/reference/platforms/iOS/xcode/
