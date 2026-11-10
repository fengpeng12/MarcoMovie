# HTTP T4 source compatibility

The Android phone/TV source router and Flutter client now distinguish remote TVBox
`type: 4` APIs from plain `type: 1` JSON CMS. The imported endpoint is used as supplied;
the adapter does not contain catalogue or playback URLs, and does not require another
user device to host a plugin. This is separate from local `catpaw://` services and the
reviewed `csp_T4` binary adapter.

The request contract follows the public [FongMi SiteApi implementation](https://github.com/FongMi/TV/blob/fongmi/app/src/main/java/com/fongmi/android/tv/api/SiteApi.java):

| Operation | Request |
| --- | --- |
| Home | `filter=true` |
| Category | `ac=detail`, `t`, `pg`, URL-safe Base64 UTF-8 JSON `ext` |
| Detail | `ac=detail`, opaque `ids` |
| Search | `wd`, `quick=false`, `pg` |
| Playback | opaque `play`, `flag` |

The site's extension is sent as `extend`. A remote extension document is fetched
lazily and cached per source instance, following [Site.fetchExt](https://github.com/FongMi/TV/blob/fongmi/app/src/main/java/com/fongmi/android/tv/bean/Site.java).
Extensions longer than 1000 characters use form POST. Endpoint query parameters and
source headers are retained; existing cross-origin credential rules still apply.
Redirects 307/308 preserve POST, while 301/302/303 switch to GET. Malformed responses
remain errors. Flutter marks opaque episode IDs for resolution by the owning source,
including download and history paths that use `needsSourceResolution`.

Local verification covers 22 Java HTTP assertions and 18 Flutter tests including
existing redirect and playback-header tests. They use synthetic local HTTP services
and actual production request code, not prerecorded results. The same 22 Java
assertions also run inside `SourceHostProbe`; Windows/macOS Flutter HTTP checks have
a separate workflow. A complete APK build, system-runtime result, physical-device
playback, and third-party endpoint availability remain distinct acceptance steps.

This does not claim that every JAR, Python dependency, webpage parser, proprietary
plugin or third-party service is supported. No installer release is implied.

## System results at `936e925`

- [Windows/macOS HTTP run 42445466014](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42445466014):
  18 tests passed on each OS, including the eight T4 tests. Retained JSON events
  were independently checked for skips, failures and test counts.
- [Android 6 TV run 42445465886](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42445465886):
  all 122 source assertions passed, including 22 T4 assertions, plus 25 subtitle
  and 96 home/history assertions. This uses the x86 Android TV system image.
- [Android 16 phone run 42445465902](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42445465902):
  both attempts failed at the same Python initialization timeout after the first
  30 existing assertions, before reaching T4. Neither is a passing phone result.
  Original errors and logs are retained; the execution limit was not relaxed.
  A smaller HTML parser dependency is being investigated separately.

The full public checks passed at that commit. That run did not authorize an
installer release.

## Phone initialization follow-up at `dd8484f`

After the [Python startup changes](python-host-startup.md), the
[Android 16 phone run 42448199091](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42448199091)
passed all 122 source assertions, including the 22 T4 cases previously not reached.
The [TV run 42448199093](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42448199093)
passed the same source cases plus 25 subtitle and 96 home/history assertions.
[Windows/macOS run 42448199050](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42448199050)
each passed 36 HTTP/Python tests, retaining all eight T4 tests without skips.
Recorded result counts and fixture editions were independently checked. Physical
device playback and the remaining plugin acceptance requirements are still open.
