# Owned-fixture Dart HTTP transport

This pure Dart component is for the isolated iOS CPython/Flutter experiment. It
does not load user scripts or become a Marco Movie production network backend.
Its only allowed targets are one to four host-owned
`http://127.0.0.1:port/<32-lowercase-hex-token>` bases. Paths must stay within that
token namespace. Other hosts, HTTPS, credentials, fragments, encoded separators
and path traversal are rejected before opening a connection. This iteration makes
no HTTPS/TLS acceptance claim and never installs a bad-certificate callback.

```dart
final transport = FixtureHttpTransport(allowedOrigins: [ownedOriginA, ownedOriginB]);
final response = await transport.request(envelope);
transport.cancel(callId);
transport.close();
```

The parent Python adapter's version-1 envelope is unchanged. Request and response
bodies must be `Uint8List`, with a separate 6 MiB limit for each body. Prepared
JSON/form/binary bytes are sent without re-encoding. Success contains exactly the
eight response fields. Failure is `FixtureTransportException` with fixed `kind`
`timeout`, `cancelled`, `connection` (or reserved `tls` for a future verified
transport); malformed/unsupported protocol uses `FormatException`. A Flutter
handler should map these to fixed transport error codes, without including the
exception's URL, remote content or credentials.

Each hop owns its own `HttpClient`, with `autoUncompress=false`, redirects disabled,
direct proxy selection, no cookie jar and no authentication callback. Explicit
Cookie/Authorization values are sent as supplied by the Python adapter; redirect
credential policy belongs to that adapter. A 401/4xx/5xx is an ordinary response.
Chunk framing is removed by Dart, but gzip/deflate remain compressed wire bytes
for the Python adapter's bounded decoder.

`headers` contains Dart's parsed header pairs. Each Set-Cookie value, including
commas in Expires and repeated cookie names, is preserved separately. Values are
never split or joined on commas, nor reconstructed from cookie objects. This is
not a byte-for-byte raw-header API: Dart can normalize header names, dates and
framing. In Dart 3.10.8 its parser uses a fixed 1 MiB header-receive ceiling; the
profile then rejects more than 128 pairs or 32 KiB after parsing. The public API
cannot lower that parser ceiling. It also discards Content-Length when accepting
Transfer-Encoding, so this bridge cannot detect every original wire-framing
conflict. Visible conflicting/duplicate singleton headers are rejected. A stricter
raw-wire parser would require separate review; none is claimed here.

The first hop anchors a monotonic call deadline (at most 45 seconds). Later hops
can shorten it, never extend it; shortening also re-arms already active hops of
the same call. A separate connect timer bounds `openUrl`; the read timer bounds
upload/header wait and then each body-idle interval. Both timers physically close
the request-owned client. The total timer continues across phases and progress.
Cancellation marks the call, closes only that call's clients immediately and
settles each result once. A settled result ignores late socket completion. Closed
transports cannot be reopened. `activeRequestCount` is only an experiment assertion
aid, not a production UI control.

Identity history is bounded to 64 calls and 256 requests per transport instance,
without eviction or identity reuse. Cancelled/expired calls remain tombstoned.
The protocol allows fresh request IDs for multiple hops in a still-live call;
because it has no `endCall` message, the native owner must still supply a new
call ID for every Python operation. This component cannot distinguish a legitimate
later hop from a reused operation with the same unexpired call ID. The native
bridge must also check deadline/cancellation before delivering data to Python;
relative channel transit time is not recoverable from the envelope alone.

The native caller must release its owning Python thread state while waiting.
MethodChannel handling is asynchronous; neither the UI thread nor an executor
responsible for processing cancellation may synchronously wait for this request.

## Local checks

No packages are required:

```sh
dart analyze scripts/ios_cpython_transport/dart
dart run scripts/ios_cpython_transport/dart/fixture_http_transport_test.dart /private/report.json
```

Tests use real local HTTP servers and record unique named checks for byte fidelity,
headers/cookies, prepared bodies, no redirect/auth retry/uncompress, input limits,
header and body timeouts, drip-feed total deadlines, cancellation isolation,
shortened concurrent deadlines, late results, capacity and connection failures.
The local run is a Windows Dart check, not an iOS MethodChannel, TLS or user-source
compatibility result. iOS acceptance belongs to the separate native experiment.
