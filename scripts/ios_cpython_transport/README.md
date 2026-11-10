# Experimental requests bridge contract

This component runs real, build-locked `requests` and `urllib3` against an injected
one-hop transport. It is not installed in Marco Movie and does not implement
NSURLSession or hard native cancellation. The fixed transportProbe optionally
extends the disposable Flutter experiment while retaining its original 42-check
fixture. Test HTTP traffic reaches only two test-owned loopback servers.

## Python caller

```python
session = BridgeSession(native_bridge)  # retain for the Spider instance
with session.call(CallContext(12, call_id=opaque_32_hex_identity)):
    result = session.get(url, timeout=(3, 5))
# A later Spider operation supplies a NEW CallContext; cookies remain in Session.
```

`RequestsBridgeAdapter(bridge)` subclasses the real HTTPAdapter without creating a
socket pool. `BridgeSession` installs it for both schemes, disables environment
proxies/netrc, limits redirects to five by default, and adds the stricter redirect
credential policy below. Native hosts must use `BridgeSession` for that policy;
mounting the adapter alone on an ordinary Session does not change its redirect
rules. The context variable binds one Spider operation's identity and monotonic
deadline to every request/hop, and is restored on scope exit. There is no source
execution, source loader or global requests monkey patch here.

## Native callback API, version 1

`bridge(request_envelope, call_context) -> response_envelope` is synchronous from
the Python owner's perspective. A native implementation may perform asynchronous
network work while releasing/restoring the owning Python thread state. It must
not call Python objects from its network completion thread. Byte values below are
real `bytes`, suitable for native C API/typed-data transport, not JSON arrays.

Request fields (all required, no other fields):

| Field | Contract |
| --- | --- |
| `version` | Integer `1` |
| `callId` | Opaque 32 lowercase hex identity of this Spider operation |
| `requestId` | A fresh opaque 32 hex identity for this single HTTP hop |
| `url` | HTTP(S), no userinfo, fragment removed; exact target for this hop |
| `method` | GET, HEAD, POST, PUT, PATCH, DELETE or OPTIONS |
| `headers` | List of `[lowercase_name, string_value]` pairs |
| `body` | PreparedRequest's bytes; string bodies use UTF-8; at most 6 MiB |
| `connectTimeoutMs`, `readTimeoutMs` | Positive integers, capped by call time remaining |
| `deadlineRemainingMs` | Positive wall-clock time remaining for the WHOLE call, not a fresh per-hop budget |

The native side MUST perform exactly one hop: no automatic redirects, cookie jar,
authorization retry, proxy selection or hidden HTTP retry. Default TLS must verify
hostname and the platform's standard trusted CA chain. `verify=False`, custom CA
files/client certificates and proxies are rejected by this bounded profile; this
does not mean ordinary verified HTTPS is unsupported. The loopback tests do not
establish a future native TLS implementation's correctness.

The bridge receives `context.check()`, `context.cancelled`, `context.deadline`
(host monotonic clock) and `context.remaining_ms()`. A native implementation must
register tasks by both identities and wire cancellation/deadline to those tasks.
The adapter checks before sending, on return, after validation/decompression and
before delivery. A late success after cancellation/deadline is rejected before
Session can store its cookies. Checks do not terminate a blocked native function;
`cancel()` records intent and this experiment never reports hard cancellation.

Response fields (all required, extras rejected):

```text
version, callId, requestId, url, status, reason, headers, body
```

Identities and URL must match the exact request hop. Native redirects or stale
callbacks are protocol errors. `status` is an integer final status 200–599;
intermediate 1xx responses must be handled by the transport. `headers` is an ordered
list of string pairs preserving each original Set-Cookie separately. `body` is the
complete transfer-decoded bytes (HTTP chunk framing removed) but still contains
any Content-Encoding compression. Native must bound body/header accumulation too,
before returning it to Python; adapter checks alone cannot limit native buffering.

The experimental Dart HttpClient implementation retains separate header values,
including Set-Cookie, but normalizes header names/group ordering. Its HTTP parser
already resolves some wire framing (for example, Transfer-Encoding takes priority
over Content-Length). The adapter's ambiguity checks apply to headers actually
reported by the bridge, not to unavailable original wire text. Dart's parser has
its own 1 MiB receive-header bound; this profile's 32 KiB bound is checked after
parsing. This component does not replace that parser or claim a 32 KiB pre-parse
allocation limit.

Raise `BridgeTransportError('timeout' | 'cancelled' | 'connection' | 'tls')` for a
transport failure. The adapter maps these to real requests exception types (or
`CallCancelled`, a RequestException). Do not put remote response bodies, URLs with
credentials or arbitrary native exceptions into that error string. HTTP 4xx/5xx
are ordinary responses, never transport exceptions.

## Response, cookies and redirects

PreparedRequest JSON/form encoding is not repeated. Arbitrary binary data remains
bytes. The returned object is a real requests.Response built with a real urllib3
HTTPResponse. Its original-response Message and HTTPHeaderDict preserve duplicate
Set-Cookie for requests/http.cookiejar parsing. Domain, path, secure and expiry
rules are evaluated by the real cookie implementation. `.json()` and
`.raise_for_status()` retain their requests behavior.

The profile is fully buffered: `.content` contains validated decoded bytes and
`.raw` is already closed, with real status/header/original-message metadata. It is
not a live raw socket or a streaming handle. UTF-8/other response charset behavior
is supplied by real requests, not by a fake JSON/text wrapper.

Redirects are driven by requests.Session, so `allow_redirects=False`, history,
`max_redirects`, 302 method rewriting and 307 body preservation apply. All hops use
the same CallContext and a diminishing total budget. Same-origin redirects retain
normal credentials. Once ANY hop changes scheme, host or port, inherited
Authorization, Proxy-Authorization, Cookie and Cookie2 are removed for the rest of
that redirect chain—even if it returns to the initial origin. Subsequent cookies
newly set by the destination are parsed into a chain-local CookieJar keyed by exact
origin. Only that target origin's new cookies are eligible on later hops, with real
domain/path/secure/expiry checks. Thus A's old cookie does not return in A→B→B, but
B's own Set-Cookie still authenticates B→B; Max-Age deletion also works. This is
intentionally stricter than ordinary requests cookies. A later independent
top-level request uses normal cookie domain/path rules; the policy does not pretend
HTTP cookies normally isolate ports. Old destination credentials already in the
shared jar are excluded from a cross-origin redirect chain.

## Supported limits and explicit omissions

- Request bytes, encoded response bytes and decompressed response bytes: each at
  most 6 MiB. Headers: 128 pairs and 32 KiB; ASCII token names, Latin-1 values,
  no injection controls. Duplicate singleton framing/location/encoding headers,
  length mismatch and conflicting Content-Length/Transfer-Encoding fail.
- Content encodings: identity, one gzip stream, zlib-wrapped deflate. Unsupported
  encodings, concatenated gzip, invalid compression and expansion overflow fail.
  Session advertises only gzip/deflate. The response header metadata is preserved.
- Positive scalar or `(connect, read)` timeout in seconds; absent timeout defaults
  to 10 seconds per phase, capped by the caller budget (maximum 45 seconds).
  None/zero/unbounded components and custom timeout objects are unsupported.
- Streaming bodies/responses, multipart, custom adapters, userinfo URLs, custom
  framing/Host headers, proxy/TLS overrides and unsupported methods fail explicitly.
  Content-Length is verified and then derived by transport; connection lifetime is
  transport-owned. No option is silently converted to a pretend successful result.
- The adapter is not a Python sandbox: unrelated code importing socket/ctypes or
  mutating Session internals is outside this API, not magically intercepted.

## Local validation

The optional native glue in `FlutterPythonTransport.h/.mm` converts the fixed
Python envelope to Foundation values, releases the owner thread state, and invokes
`transport.request` on the Flutter main channel. Dart completes with the response
or one of the exact error codes `timeout`, `cancelled`, `connection`, `tls`,
`protocol`. The owner restores its thread state before constructing any Python
result/exception. Other callbacks never touch PyObject values.

`cancelTransport({version:1,callId})` is handled immediately outside the Python
worker queue: it settles registered native waits and invokes Dart
`transport.cancel`. On observing cancellation, only the Python owner updates its
CallContext's flag; the main callback never accesses Python. Waiting is bounded by
the call's remaining budget (at most 45 seconds). Callback settlement wakes the
owner, but the pending record remains cancellable until the owner restores its
thread state and atomically claims delivery. Cancellation before that point wins;
after it there is no pending HTTP wait to cancel. Entries are removed once and
late callbacks cannot settle them again. This does not interrupt subsequent or
arbitrary Python/C code. The fixed probe creates and destroys its own own-GIL
subinterpreter, counts against the experiment's two-session capacity, and accepts
only two different-port HTTP loopback origins with fixed-shaped token paths.
It never accepts source text, arbitrary import names or filesystem paths.

`transport_fixture.py` declares twelve `transport_*` checks. The fixed `c`-repeated
call identity targets `/slow`; Dart must trigger the real native cancelTransport
entry after 30 ms, not fabricate a cancelled result. Native compile/execution and
the original two startup orders still need the macOS simulator run; Python host
checks do not establish those outcomes.

Requires Python 3.11.5+ and all pure wheels already in the existing cache, matching
`scripts/ios_cpython/pure-dependencies.lock.json`. No package download is performed.

```sh
python scripts/ios_cpython_transport/local_checks.py \
  --cache-dir /path/to/cpython-cache \
  --output-dir /path/to/private-check-results
```

The checker extracts verified pure wheels into an isolated result directory and
checks actual loaded versions/paths. It exercises real PreparedRequest/Session,
two real local HTTP origins, bytes, JSON/form, gzip, size limits, cookie attributes,
same/cross/multiple redirects, error status/JSON, cancellation and ignored late
responses. Synthetic malformed bridge replies verify protocol rejection. Output
records unique named checks, input hashes and exact adapter/checker source hashes.
It never calls user endpoints or counts local checks as iOS/native acceptance.

The contracts were checked against the locked wheels and official
[requests adapter source](https://requests.readthedocs.io/en/latest/_modules/requests/adapters/),
[Session redirect implementation](https://requests.readthedocs.io/en/latest/_modules/requests/sessions/),
and [cookie extraction](https://requests.readthedocs.io/en/latest/_modules/requests/cookies/).
