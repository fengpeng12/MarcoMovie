# Native Python source loader — integration candidate

This is a shared loader for a Python Spider in one dedicated interpreter. It is
not selected by the production subscription dispatcher yet. The existing
Skulpt backend and published installers remain unchanged.

The loader preserves the supplied extension string, constructs and initializes
the Spider once, and retains source/module/session state through home,
recommendations, category, search, detail, play, `liveContent` and proxy calls.
Relative modules, namespace packages, `importlib.resources` and `pkgutil` read
from the supplied memory package. Same-name modules from different sources must
run in separate interpreters. The package has a 256-file, 2 MiB per-file and
6 MiB total limit. A package cannot replace host modules or load native wheels.

`requests.Session` remains a real class, including imported aliases and
subclasses. HTTP requests use the app-owned transport with a per-operation
identity and deadline; retained sessions keep their own cookies. Source headers
are not automatically added to every request. Import, construction and `init`
belong to the first operation, so they do not escape that operation's budget.
Native callers may supply an exact 32-character hexadecimal operation identity;
invalid identities fail before the source is imported.

Missing methods and source exceptions are reported. A three-argument search is
selected by signature binding before execution, avoiding a second execution if
the source itself raises `TypeError`. Live JSON is decoded, while M3U/TXT and
empty text are returned unchanged. A missing live method is not a successful
empty catalogue. Proxy results retain status, MIME, headers and binary bytes in
the existing three-to-five-item protocol; binary data is explicitly base64.

Closing a source revokes its resources, loaders and HTTP sessions. Proxy URLs
are supplied by the native owner and refer to the originating source instance.
This loader does not implement secure filesystem isolation or hard interruption
of arbitrary Python/C code. Its current failure policy retires a failed source;
production routing still needs bounded lifetime, cancellation and playback-lease
integration. Native extensions such as lxml are not enabled by this work.

`scripts/test_native_python_source.py` runs each owned source in a fresh host
process using the pinned requests wheels. The iOS Flutter experiment additionally
uses this exact loader and `flutter/src/core/python_http_transport.dart` through
the real native bridge. Its added requirements cover all source methods, memory
package resources, repeated calls, same-name isolation, actual HTTP binary GET
and HEAD proxy responses, and release/recreation without rebinding old URLs.
The experiment still accepts only bundled test sources. These checks must pass
on the selected simulator before any claim of iOS runtime acceptance; they do
not establish physical iPhone, arbitrary user-source or decoder acceptance.
