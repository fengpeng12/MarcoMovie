# Local Python package fixture

The fixture is self-authored. It does not contain or execute a subscription plugin.

`python_package_contract.py` is the source passed to `createPythonSpider`.
`python_package_fixture.json` contains `modules` and the fourth `packageData`
argument: a canonical `entry` path and a map of canonical paths to raw-byte
Base64 strings. `python_package_expected.json` is the independent CPython result.
These three files can be copied unchanged to native host probes.

Regenerate the expected result with CPython:

```text
python scripts/fixtures/python_package_oracle.py
node --jitless scripts/test_python_package.js
```

The generator materializes the synthetic package in a temporary directory and
runs CPython there. Only the host test uses the virtual package implementation.
No network or user files are read. Directory-opening error subclasses differ
between Windows and POSIX CPython, so that case checks their common `OSError`
contract. Text `tell()` positions are validated by round-trip seeking; they
need not equal CPython's implementation-specific newline decoder cookies.

The supported package contract is read-only `open` / `io.open`, contexts,
iteration, UTF-8 strict decoding (`utf8`, `utf-8`, `UTF_8`, and `utf-8-sig`),
binary reads, standard newline modes, and seeking within bounded data. Relative
paths start at the entry's directory; `__file__` provides each module's own
virtual path under `/__package__/`. Parent traversal is allowed only within
that virtual root. Resources are limited to 256 files, 2 MiB decoded bytes per
file, and 6 MiB total. File declarations must be canonical and have no control
characters, backslashes, colons, or quotes. Missing resources cannot fall back
to disk or HTTP. Package imports use the supplied local module map.

This does not implement a host filesystem, file descriptors, write persistence,
custom openers, non-UTF-8 codecs, decoder error replacement, mutable buffer
views, `readinto`, `os`, `pathlib`, or `subprocess`. Unsupported operations fail
explicitly. Text decoding is bounded but eager over the remaining file, so a
later invalid UTF-8 sequence can fail an earlier small read. The virtual text
stream does not reproduce CPython's buffering or opaque cookie representation.
An imported source is still limited by the surrounding Python host's supported
language and modules; this fixture is not a full-CPython compatibility claim.
