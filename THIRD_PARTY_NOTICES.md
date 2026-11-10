# 第三方组件与致谢

Marco Movie 的作者为 Pilipala。以下第三方组件保留其自身版权与许可，不能将其归为项目作者原创。

| 组件 | 说明与许可记录 |
| --- | --- |
| AndroidX Media3、Guava、Kotlin 及相关依赖 | `android/media-dependencies.json`；完整许可及声明在 `android/src/main/assets/media-third-party-notices.txt` |
| OkHttp / Okio | Apache-2.0；`android/src/main/assets/third-party-notices.txt` |
| Gson、其他接口依赖 | `android/dependencies.json` 与 `android/src/main/assets/source-engine-third-party-notices.txt` |
| QuickJS 及 Java/Android wrapper | `android/src/main/assets/js-host/quickjs.LICENSE`、`quickjs-wrapper.LICENSE` |
| jsoup、CryptoJS、JSONPath | `android/src/main/assets/js-host/` 中相应 LICENSE 文件；宿主适配层与第三方库分别保留 |
| libtorrent / FrostWire jlibtorrent | `android/torrent-dependencies.json` 与 `android/src/main/assets/torrent-third-party-notices.txt` |
| Rime 简体拼音词典、Unicode Unihan 数据 | `android/src/main/assets/search/` 中许可及 provenance 清单 |
| Glasswork | [kubai087/glasswork](https://github.com/kubai087/glasswork)，参考提交 `4f0b674`；MIT，许可副本见 `flutter/shaders/GLASSWORK-LICENSE.txt`。Flutter shader 和原生材质为平台适配，不是浏览器实现的直接嵌入。 |

固定依赖版本和摘要用于构建复核，不表示采用各项目最新版本。源码和 APK 都保留第三方许可记录。运行时用户自行载入的内容扩展不随本仓库提供，其权利和行为不由这份组件清单覆盖。

品牌图片由项目作者提供并通过 AI 辅助衍生；应用图标和桌面横幅不含第三方影视海报。系统字体来自运行设备，不随项目单独分发。

## 原生解码组件

FFmpeg 6.1.6（本次配置为 LGPL-2.1-or-later）、Media3、libgav1、cpu_features、Abseil（Apache-2.0）及 libvpx（BSD 许可及专利声明）。完整许可随 APK 保存在 `android/src/main/assets/decoder-licenses/`，固定源码提交、对应源码和修改说明见 [解码组件说明](docs/DECODERS.md)。这些组件归各上游作者所有。

## Local source interpreters

- quickjs_engine 0.1.7, MIT, from https://pub.dev/packages/quickjs_engine/versions/0.1.7. The checked-in package includes QuickJS-NG 0.14.0 copyright and license notices in its source files. Local changes add request deadlines, source builds on macOS, and UTF-8 compilation on Windows. See flutter/packages/quickjs_engine/LICENSE and MARCO_PATCHES.md.
- Skulpt 1.2.0, MIT, from https://github.com/skulpt/skulpt. Runtime and standard-library bundle retain upstream code, with LICENSE in android/src/main/assets/python-host. The Spider bridge is project code. Flutter bundles the same files during platform preparation.
- html Dart package, BSD-3-Clause, resolved by flutter/pubspec.lock.

## CatPaw local runtime

- Node.js 22.22.3 for desktop, and nodejs-mobile 18.20.4 for Android/iOS, from their official release archives. Build scripts pin SHA-256 hashes; desktop archives include LICENSE, and mobile notices are included as `shared/catpaw/node-mobile-LICENSE.txt` from the matching upstream tag. The app-owned host and native bridges are GPL-3.0-only. User-imported CatPaw bundles are not redistributed with the app.
- node-fetch 3.3.2 and its dependencies provide the Fetch API for the iOS no-JIT runtime. Exact package versions and integrity values are in `shared/catpaw/fetch-provenance.json`; their licenses are in `fetch-LICENSE.txt`. The CommonJS build uses esbuild 0.25.12 without functional upstream modifications.
