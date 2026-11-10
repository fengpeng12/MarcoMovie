## Windows 0.5.3 — 2026-11-09

此版本为 Windows 桌面端（x64）独立更新，修复含 `//` 注释与 `#EXTINF` 切片去广告规则的 TVBox / 影视仓订阅源导入失败问题，并同步最新已审阅 Guard 插件特征库。其他平台保持各自版本独立推进。

1. **修复含 `#EXTINF` 规则与行内注释的 JSON 订阅源导入失败**：此前当 TVBox / 影视仓配置（含 `**`+Base64 图片隐写解包后的 JSON）同时包含 `//` 注释行与 `"rules"` 中的 `#EXT-X-DISCONTINUITY\r*\n*#EXTINF:...` HLS 去广告正则时，会被误判为 M3U 直播列表并直接送入未剥离注释的 JSON 解析分支，导致 `FormatException: Unexpected character (at line 13, character 1)`。现已在 `CmsParser`、`LiveCatalogParser` 与 `CmsClient` 统一先剥离 JSON 注释并识别顶层 `{`/`[` 结构，确保此类主流单仓/多仓订阅源正常导入。
2. **同步最新 Guard 源特征指纹**：为 `Dm84`、`Auete`、`Bttwoo`、`T4`、`FY` 数据提取器补充最新已审阅插件包（SHA-256 `da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096`）特征映射，兼容新旧两代插件包常量与扩展配置提取。
3. **延续 0.5.2 订阅源、直播源与原生全屏能力**：包含 GZIP / `**`+Base64 / `2423` Hex-AES 解包、HTTP T4 / DRPY / CatVod JS / Python Spider、直播目录 `proxy://` 与脚本直播源、请求主动取消，以及桌面端无边框真全屏播放与独立更新通道（`updates/windows.json`）。

### 验证与范围

- 构建提交：`6233f553666d2e1b0e8ad98d64f79621d0f8eb36`，[GitHub Actions 构建与验证记录](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42513080513)。
- 通过公开内容守卫、DRPY/CatVod/Python/Guard 本地宿主回归检查、Flutter 跨端单测（新增含 `//` 注释与 `#EXTINF` 去广告规则的 TVBox JSON 回归测试）以及 GitHub Actions Windows x64 安装包（`.exe`）与便携包（`.zip`）完整构建校验。
- 已知限制：其余尚未完成跨平台移植的 33 条 Android 专属 Guard / JAR 插件线路及通用实机播放未纳入本版已完成范围。
- 提供 Windows x64 安装版与便携版 ZIP，均附 SHA-256 校验值及对应源码归档。
