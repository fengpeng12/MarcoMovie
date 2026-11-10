# Local JS and Python proxy callbacks

Some Spider sources return a local playback address and generate manifests or
media fragments on later HTTP requests. The host must keep that same source
instance alive across catalogue, detail, player resolution and proxy callbacks.
Resolving an address once does not implement this protocol.

The ordinary proxy bridge accepts the TVBox-style buffered result
`[status, MIME, body, headers?, base64?]`. Text, byte arrays and explicitly marked
Base64 bodies are supported. Python `bytes` and JavaScript typed bytes cross the
host boundary as Base64, preserving values such as zero, 128 and 255. The decoded
body limit is 6 MiB, subject to the source runtime's memory/execution budget.
Native stream handles and CatVod's separate `js2Proxy` response protocol are not
implied by support for this array form.

Android uses the existing device-local listener and serializes callbacks on the
same QuickJS source instance. It forwards `Range` to the source and validates a
returned `206` response against its buffered bytes and `Content-Range`; it does
not automatically slice a complete `200` response. `HEAD` omits the body while
preserving valid size metadata. Closing or replacing the source revokes its old
route, and closing the listener cancels its active request scopes and sockets.

Python exposes legacy `getProxyUrl` / `localProxy` and newer `proxyUrl` / `proxy`
interfaces. JavaScript exposes `getProxy` and `proxyUrl`. URLs belong to a specific
live source instance; a caller cannot select another source by altering `siteKey`.
The listener is local to the device. The legacy `local=False` argument does not
start a LAN listener or require another device.

The Flutter host protects a player's source from browsing-cache eviction for the
entire player page. The lease ends after the decoder is disposed, so pause,
episode changes and quality changes do not create an ownership gap. Removing
the subscription revokes its route. Failed source instances cannot silently
rebind an old playback URL to newly initialized state.

On a Flutter proxy request cancellation, transport is cancelled and the host has
at most 500 ms, within the original operation budget, to settle the top-level
promise and tracked requests. State is reused only after that cleanup succeeds.
An unresolved promise, execution timeout or unsafe failure revokes the instance
and its address. This does not roll back arbitrary script mutations.

The Flutter loopback listener continues to reject browser `Origin` requests.
Only URLs verified as belonging to the source receive local transport-header
adaptation: upstream `Origin` travels as internal metadata and is restored for
the source callback. Remote media keeps its required `Origin`. Host and other
connection-level headers are not copied from an upstream subscription onto the
local player request.

Local tests exercise real sockets, state retention, binary bodies, single ranges,
HEAD, cancellation, route revocation and the Flutter QuickJS engine. JVM/Node
tests and Android/iOS native probes have separate evidence. These fixtures are
not acceptance of a third-party subscription or physical-device video decoding;
the [iPhone release gate](ios-source-acceptance.md) remains in force.
