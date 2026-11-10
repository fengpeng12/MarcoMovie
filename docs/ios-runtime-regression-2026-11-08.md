# iOS native runtime regression, 2026-11-08

[Run 42444469196](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42444469196)
at `1efc779382ca16835b024f7978a9d574ea723e58` passed all 200 native assertions
on both ARM64 and Intel iPhone simulators using iOS 18.5 and SDK 18.5. The embedded
runtime reported Node 18.20.4. Every recorded production and fixture SHA-256 was
independently checked against that exact commit; neither architecture contained
a duplicate or false assertion.

This follows failed [run 42443360741](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42443360741):
the ARM64 simulator timed out launching before acceptance, and Intel reached 172
passing assertions before the first Foundation HTTP client callback timed out.
The failure evidence is retained. The follow-up selects an available iPhone
runtime compatible with the active SDK and adds a bounded raw-loopback diagnostic.
It does not alter the production Node engine, replace the Foundation acceptance
checks with socket success, or establish the cause of the earlier timeout.

Both new results report successful raw-loopback connectivity and HTTP health,
followed by every original runtime check. This is simulator source-runtime
evidence only: no Flutter interface, media decoder, physical iPhone, or arbitrary
third-party subscription acceptance is implied. The unfinished Python/module and
33 original plugin-route gates in [iPhone source acceptance](ios-source-acceptance.md)
remain open. No installation package is released by this workflow.
