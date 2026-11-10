# Python JSON compatibility

The shared on-device Python host supports `json.loads`, `dumps`, `load`, `dump`
and `JSONDecodeError`. The previous bridge silently discarded encoding options
and converted large integer identifiers through JavaScript numbers. That could
change signed request bodies, ordered data and episode identifiers.

The implementation preserves Python integer precision, object insertion order,
duplicate keys for `object_pairs_hook`, Unicode escaping, compact separators,
indentation, key sorting, `default`, numeric/object hooks and `allow_nan`.
Decode errors carry `msg`, `doc`, `pos`, `lineno` and `colno`; they remain a
subclass of `ValueError`. `load` and `dump` call the supplied stream's actual
`read`/`write` methods and propagate failures. They do not create an operating
system filesystem or pretend to persist cookies. Python HTTP JSON request bodies
use this same encoder, preserving large IDs through the transport.

The scope is bounded to 2,097,152 input/output characters (or input bytes), 80 nested containers and
100,000 values. UTF-8 bytes, including a byte-order mark, are accepted. UTF-16/32
byte inputs and custom encoder/decoder classes currently fail explicitly.
Unknown options are rejected rather than silently ignored. This is not a claim
of complete CPython, `io`, `os`, native extensions or arbitrary source support.

`scripts/fixtures/python_json_contract.py` is an independent CPython oracle;
its checked-in output covers 28 groups. The no-JIT Node test and native iOS
probe execute the shipped Python assets against that output. Flutter regressions
also exercise actual QuickJS, source-session continuity and a local HTTP server,
including exact request bytes and malformed responses. Runtime/build outcomes
must be checked separately; these synthetic fixtures do not establish live
third-party playback or physical-iPhone acceptance.

API reference: [Python JSON documentation](https://docs.python.org/3/library/json.html).
