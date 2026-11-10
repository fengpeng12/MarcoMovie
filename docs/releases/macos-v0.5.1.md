## macOS 0.5.1 — 2026-11-08

此版本为 macOS 桌面端独立更新，同步桌面端原生全屏播放修复及各类订阅源、直播源、TVBox 源与影视仓源适配。其他平台保持各自版本独立推进。

1. **桌面端原生真全屏播放**：双击播放画面、按 `F`/`F11` 或点击全屏按钮统一切换无标题栏真全屏；`Esc` 键先退出全屏，再次按下离开播放页，退出全屏或返回详情页时自动恢复原窗口大小与位置。
2. **订阅源与多仓兼容增强**：支持 GZIP 压缩配置、图片隐写（`**`+Base64）、`2423`（`$#...#$`）Hex-AES 加密配置、顶层 `jar` 与 `parses` JSON 解析列表回退、站点 `ua` 与 `ext.header`/`ext.headers` 请求头提取，以及本地 `.zip` 离线订阅包导入。
3. **脚本与扩展片源适配**：支持 HTTP T4（`type: 4`）远端接口、本地 DRPY 规则引擎（保留规则声明编码）、CatVod JS Spider（ES Module 与 CommonJS 依赖预载）、Python Spider 会话保持与本机回环代理，以及已移植 Guard 源（`Dm84`、`Auete`、`Bttwoo`、`T4`、`FY` 与图形验证码验证弹窗）。
4. **直播目录与直播源增强**：新增 `LiveCatalogParser`，支持 TVBox `proxy://?do=live&type=txt&ext=` 直播目录引用解包、`lives[].api` 脚本直播源（`liveContent`）与播放会话保持、嵌套 `groups`/`channels` JSON 直播结构、`#EXTVLCOPT:` / `#EXTGRP:` / `|Referer=...` 频道级请求头，以及 Base64 / `**`+Base64 / Hex-AES 编码直播列表。
5. **平台独立更新与请求取消**：切换为按 macOS 独立更新清单（`updates/macos.json`）检查更新，避免其他平台发版导致错误升级提示；切换分类筛选、直播源或离开详情页时主动取消过期请求。

### 验证与范围

- 构建提交：`5c586d576103d23abb0c381b2e45acfa2d31e39d`，[GitHub Actions 构建与验证记录](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42482977553)。
- 通过公开内容守卫、DRPY/CatVod/Python/Guard 本地宿主回归检查、Flutter 跨端单测以及 GitHub Actions macOS 应用包完整构建与签名校验。
- 已知限制：其余尚未完成跨平台移植的 33 条 Android 专属 Guard / JAR 插件线路及通用实机播放未纳入本版已完成范围。
- 0.5.0 客户端首次升级请从[下载页](https://marcotv.wlj9919.top/movie/)手动下载安装 macOS 0.5.1 应用包；自 0.5.1 起使用 macOS 平台独立更新通道。
