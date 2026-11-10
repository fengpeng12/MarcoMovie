## Windows 0.5.2 — 2026-11-08

此版本为 Windows 桌面端（x64）独立更新，同步各类订阅源、直播源、TVBox 源与影视仓源适配。其他平台保持各自版本独立推进。

1. **订阅源与多仓兼容增强**：支持 GZIP 压缩配置、图片隐写（`**`+Base64）、`2423`（`$#...#$`）Hex-AES 加密配置、顶层 `jar` 与 `parses` JSON 解析列表回退、站点 `ua` 与 `ext.header`/`ext.headers` 请求头提取，以及本地 `.zip` 离线订阅包导入。
2. **脚本与扩展片源适配**：支持 HTTP T4（`type: 4`）远端接口、本地 DRPY 规则引擎（保留规则声明编码）、CatVod JS Spider（ES Module 与 CommonJS 依赖预载）、Python Spider 会话保持与本机回环代理，以及已移植 Guard 源（`Dm84`、`Auete`、`Bttwoo`、`T4`、`FY` 与图形验证码验证弹窗）。
3. **直播目录与直播源增强**：新增 `LiveCatalogParser`，支持 TVBox `proxy://?do=live&type=txt&ext=` 直播目录引用解包、`lives[].api` 脚本直播源（`liveContent`）与播放会话保持、嵌套 `groups`/`channels` JSON 直播结构、`#EXTVLCOPT:` / `#EXTGRP:` / `|Referer=...` 频道级请求头，以及 Base64 / `**`+Base64 / Hex-AES 编码直播列表。
4. **并发请求取消与选集优先**：切换首页分类筛选、切换直播源或离开详情页时主动取消已过期的后台请求，优先保障当前详情页选集加载。
5. **原生真全屏与独立更新**：延续 0.5.1 原生无边框真全屏播放（双击播放画面、`F`/`F11`、全屏按钮统一切换，`Esc` 优先退出全屏并恢复原窗口状态）与 Windows 独立更新通道（`updates/windows.json`）。

### 验证与范围

- 构建提交：`5c586d576103d23abb0c381b2e45acfa2d31e39d`，[GitHub Actions 构建与验证记录](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42482977553)。
- 通过公开内容守卫、DRPY/CatVod/Python/Guard 本地宿主回归检查、Flutter 跨端单测以及 GitHub Actions Windows x64 安装包（`.exe`）与便携包（`.zip`）完整构建校验。
- 已知限制：其余尚未完成跨平台移植的 33 条 Android 专属 Guard / JAR 插件线路及通用实机播放未纳入本版已完成范围。
- 提供 Windows x64 安装版与便携版 ZIP，均附 SHA-256 校验值及对应源码归档。
