# Android Node runtime build

`build_catpaw_node.py` pins the Node source revision and NDK, compiles for API 23,
and rejects output whose ELF LOAD segments do not support 16 KB pages. A build
passing this check still needs execution on a 16 KB Android environment before
the application runtime guard can be removed.

The `v8-char16-libcxx19.patch` backports V8 commit
[`182d9c05e78b1ddb1cb8242cd3628a7855a0336f`](https://chromium.googlesource.com/v8/v8.git/+/182d9c05e78b1ddb1cb8242cd3628a7855a0336f),
authored by Andrey Kosyakov, using the
[FreeBSD Node 18 backport](https://github.com/freebsd/freebsd-ports/blob/2024Q4/www/node18/files/patch-libc%2B%2B19).
It changes the inspector's string storage to the standard `char16_t` type while
preserving its `uint16_t` protocol interfaces. The patch is checksum-verified,
checked against the pinned source before application, and recorded in output
provenance. V8's BSD license is included in Node's bundled `LICENSE`, copied to
the build artifact.

Other local compatibility adjustments match c-ares feature probes to API 23
and keep host/target compiler configuration separate. No prebuilt ELF headers
are rewritten.
