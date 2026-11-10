# Local Python HTML support

Android and Flutter (iPhone/iPad, Windows and macOS) load the same read-only
`bs4` adapter over the already bundled Cheerio HTML parser. It runs inside the
source's local JavaScript runtime. Parsing never starts an external process,
contacts a parsing service or executes scripts from the HTML document.

Supported Python operations:

- `BeautifulSoup(markup, 'html.parser')` with string input; omitted or `None`
  features select the same parser.
- `select` and `select_one` for the bundled CSS engine's selectors, including
  descendants, children, attribute selectors, `:not`, `:nth-child` and unions.
- `Tag.get(name, default)`, decoded HTML entities and multi-value attributes
  such as `class` and `rel`.
- `.text` and `get_text(separator, strip=True)`, with script/style/template and
  ruby annotations excluded from normal document text. Selecting such a tag
  explicitly retains its own text semantics.

This is not the full BeautifulSoup/SoupSieve API. `find`, tree mutation,
serialization, XML, `lxml`, arbitrary native modules and their parser-specific
error recovery are not implemented. Missing methods and unsupported parsers
raise errors instead of returning fabricated empty results. The bounded CSS
engine may differ from SoupSieve for selectors outside the verified contract.

The dependency bundle is initialized only when `bs4` is imported. Each source
owns its parser and node objects; retained catalogue nodes work across detail
and play calls, and source teardown releases them with the runtime. No global
node registry or files are created. Flutter caches only immutable bundled asset
text across sources.

Limits are two Mi UTF-16 code units of markup, 50,000 document nodes, 10,000
results per `select`, and 2,048 characters per selector. `select_one` returns
only its first result and does not allocate the full Python result list.
Existing source memory and execution limits still apply.

`scripts/fixtures/python_html_expected.json` was produced by running the
self-authored `python_html_contract.py` with CPython and BeautifulSoup 4.15.0.
Twenty outputs cover document order, missing nodes/attributes, entities,
Unicode whitespace, nested text, unclosed markup and special text containers.
The normal Python host regression compares those values and checks bounds.
One additional oracle group covers 14 `re.sub`/`re.subn` results, including
Unicode whitespace/word/digit classes, numeric backreferences, replacement
escapes, count and case/multiline flags. These substitutions supplement the
bundled interpreter's incomplete `re` module. They accept string patterns and
string replacements; compiled patterns, callable replacements, zero-width
matches, named groups, lookbehind, word-boundary escapes and additional flags
remain explicitly unsupported. This is not a full CPython regular-expression
implementation. Patterns are limited to 2,048 characters, replacements to
65,536, input/output to two Mi UTF-16 code units and matches to 100,000.
Flutter also exercises the actual imported Python path with a loopback HTTP
catalogue, details, retained nodes and a playback address. Those are parser and
protocol tests, not video-decoder or physical-iPhone acceptance.

The native iOS and Android regression fixtures load the same production
assets. Their results must be recorded for the commit under review; older
runtime results do not establish this new feature's native compatibility.

## Smaller parser initialization

Python HTML now loads its own 257,284-byte Cheerio slim dependency instead of
initializing the full 1,269,961-byte DRPY bundle. It retains the same pinned
Cheerio/htmlparser2 versions and HTML-mode options, while omitting unrelated
template, JSONPath, cryptography and parse5 initialization. The source's Skulpt
8-second execution limit, native deadline, parser bounds and per-source state
isolation remain unchanged. A smaller asset is not by itself proof of faster
device execution or a resolved timeout.

`scripts/prepare_python_html.py` rebuilds it using the existing npm lock and
esbuild 0.25.12; `--check` verifies its recipe, dependency records, code and
license digests without network access. Android and Flutter build preparation
run this check. The complete reviewed npm notices accompany the new asset.
Node tests compare the existing HTML/regular-expression oracles and real HTTP
contracts. Native phone, TV and iOS results are recorded separately; the phone
probe now also records Python HTML initialization duration, including failures.

FY remains incomplete. Its imported module still needs file/module adaptation,
cookie persistence, verification/OCR behavior and an exact plugin dispatch
path. Adding HTML operations does not enable `csp_FyGuard`, complete any of the
33 outstanding plugin obligations, or satisfy the iPhone release gate.

A private regression runs four unchanged original FY method bodies over six
self-authored HTML cases and compares them with CPython/BeautifulSoup. Before
the substitution addition, FY swallowed a missing `re.sub` exception and returned
an empty detail list. The verified cases cover catalogue/search fallbacks,
duplicates, metadata, line-to-episode binding and episode reversal. This is
method-level evidence only: fixture markup replaces fetch, and the original
module's initialization, remote service and verification paths are not tested.
