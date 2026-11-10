# Local QuickJS host dependency

Based on quickjs_engine 0.1.7 from pub.dev (MIT), bundling QuickJS-NG 0.14.0.
Preserve upstream copyright notices in LICENSE and native/cxx/quickjs/.

- The native jsNewRuntime signature now accepts the deadline already passed by Dart.
- Each source operation gets a fresh runtime with one wall-clock deadline covering
  all eval calls and promise jobs; JS cannot reset the budget by chaining tasks.
- macOS CocoaPods compiles the same patched source as all other platforms instead
  of loading the upstream prebuilt, unpatched dylib.
- No upstream prebuilt binary is shipped in this copy.
- Non-Error JavaScript throws (including Python host exceptions) are wrapped as
  script failures instead of causing a Dart JSError cast failure.

This is not a complete TVBox/DRPY/Python or Android JAR implementation.
