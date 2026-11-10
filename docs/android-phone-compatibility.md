# Android phone compatibility work

The current work order is Android phone/tablet, then iPhone, then Windows/macOS.
Each stage includes subscription import, catalogue, search, details, playback and
live channels. Passing parser fixtures alone does not complete a device stage.

## Live HTTP headers

TVBox-style live source and inline group `origin` fields now set the HTTP `Origin`
header. Existing `ua`, `referer`, `header` and `headers` handling is retained.
Source-declared headers stay attached to same-origin channel requests.

When a catalogue redirects across origins, its removed Authorization/Cookie
headers are no longer restored into the resulting stream. The original source
object is unchanged, so a later independent load can still use its credentials.

The isolated host-Java regression covers 21 catalogue assertions and five real
loopback-network checks: mixed-case credential removal, no restoration into
streams, PHP endpoint/UTF-16 decoding with relative media URLs, same-origin
credential retention and cancellation of in-flight requests. These are client
transport checks; no claim is made that all remote channels or Xiaomi firmware
now play successfully.

## Legacy live directory wrappers

The reader now recognizes TVBox `proxy://do=live&type=txt&ext=...` and the
equivalent loopback `/proxy` form. Plain percent-encoded URLs, standard/URL-safe
Base64, and local-package-relative lists use the existing bounded HTTP/file
reader. This is a catalogue reference, so it does not start an Android JAR host.
Nested placeholders are separated from ordinary inline channels without losing
either; group headers and the legacy `group` name are retained. Invalid,
duplicate or recursive references fail with a directory error, and a remote
configuration cannot use this wrapper to read a local file.

The protocol behavior was checked against the upstream
[TVBox configuration reader](https://github.com/takagen99/Box/blob/main/app/src/main/java/com/github/tvbox/osc/api/ApiConfig.java).
Local regression now covers 31 catalogue assertions and 12 real-loopback HTTP
checks. Device execution of the six new local-package assertions is tracked
separately in the Android 6 source-host workflow; parser success is not playback.
At `4424cbe`, [run 42439415853](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42439415853)
passed all six new assertions on the actual API 23 runtime (86 total source-host
checks), including local-package lookup, inherited headers and preserving inline
channels. This still does not verify third-party media playback.

## Local plugin live catalogues

Custom `proxy://` catalogue addresses now select the local source listener, just
like its reserved loopback HTTP form. An unrelated localhost service or a path
such as `/proxy-other` does not select that listener. The direct text-directory
wrapper above still bypasses the plugin host.

Catalogue requests to the current authenticated listener carry upstream Origin
and Host as internal transport metadata. The callback receives the original
values, and returned remote channels inherit ordinary source headers. The source
definition is unchanged, and unrelated endpoints, wrong/duplicate tokens and
browser Origin checks retain their original behavior. Local tests exercise the
actual HTTP reader and loopback listener, not just URL string matching.

`phone-source.yml` runs the shared source probe inside an Android 16 phone image
with the phone edition's bytecode and x86_64 QuickJS/Python JNI. It includes live
catalogue headers and source state across reload, separately from the existing
Android 6 TV probe. Neither isolated fixture contains ARM decoders or proves
third-party stream playback.

The newer `api`/`ext` live configuration now uses a separate source-engine call:
upstream
[LiveParser](https://github.com/FongMi/TV/blob/fongmi/app/src/main/java/com/fongmi/android/tv/api/parser/LiveParser.java)
dispatches it to `liveContent(url)`. Phone and TV now share that dispatch for JS,
Python Spider and Android CSP. It preserves opaque arguments, structured ext,
explicit/inherited JARs, and separate instances for same-name definitions. Text
and JSON-array results pass through the bounded catalogue reader; missing methods
and runtime failures remain errors. Plain lists still use the ordinary reader.

The native probe additionally loads an independently authored, separate DEX/JAR
fixture and executes `liveContent` through the shipped CSP host. Its TXT/JSON,
state and initialization checks run alongside actual QuickJS/Python calls. These
are fixture compatibility checks, not a claim that proprietary plugins or remote
channels all work. The first phone run at `5e8d4d1` passed the new proxy-reader
checks but failed later in a Python HTTP fixture; it is not an overall pass.

At commit `1d4871a`, the completed
[Android 16 phone run](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42443360552)
passed all 100 source assertions, including all 20 live-related cases. The
[Android 6 TV run](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42443360580)
passed the same 100 source assertions plus 25 subtitle and 96 home/history
assertions. The retained JSON results were checked against their counts and
fixture editions independently of the workflow status. This validates the local
source engines and catalogue path on those emulator runtimes; physical devices,
ARM media decoding and third-party stream availability remain separate gates.

## Separate update editions

The [HTTP T4 adapter and system results](http-source-compatibility.md) cover
generic remote `type: 4` endpoints independently of local CatPaw and JAR adapters.
Its API 23 and API 36 fixtures now pass all 122 source assertions, including the
22 T4 checks. The [Python startup follow-up](python-host-startup.md) retains the
earlier phone failures and records the fixed-library compilation change. These
system fixtures do not close physical-phone or remote-media acceptance.

[Update isolation](android-update-isolation.md) records the phone/TV feeds,
explicit package names, old-name migration and APK verification tests. This work
does not publish a new installer or change the live mirror.

## Remaining acceptance

- Exercise imported user subscriptions on the Android phone runtime, including
  HTTP(S) JSON/PHP endpoints, text lists, JS/Python scripts, local packages,
  multi-repository configurations and live channels.
- The [published-default Node packaging path](android-node-runtime-packaging.md)
  passed separately from the candidate and source-runtime checks at `b9b5444`.
  Continue physical phone decoder, source and playback validation; aligned
  libraries alone do not complete this stage.
- Keep JAR/runtime limitations, remote service failures and successful playback
  distinct. The original cross-platform plugin obligations and iPhone publication
  gate remain open.
