# Android 手机 / 平板 0.5.10

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.10`（`versionCode 60`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.10-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.10-mobile.apk`）

## 本次修复与改进

1. **新增搜索页线路/片源筛选能力（`MobileShell.renderSearchTab`）**：
   - 在搜索页状态栏与结果列表之间新增横向可滑动的片源筛选胶囊栏，展示 `全部 (N)` 及各返回结果的片源标签 `片源名 (k)`，随并发搜索流式返回实时更新各线路计数。
   - 当命中片源达到 2 个及以上时，左侧提供 `筛选线路 ▾` 快捷按钮，点击可拉起底部抽屉菜单从全部命中线路中快速点选过滤；从搜索结果进入详情页再返回时自动保留当前筛选状态。

2. **修复多个扩展片源（如饭太硬、王二小、玩偶等）弹幕无法正常获取与显示的问题**：
   - **代理端口探测与 UTF-8 参数解码（`LocalProxy` + `CspEngine` + `ProxyAddress`）**：在 `LocalProxy` 中响应 `/proxy?do=ck` 端口健康检查（返回 HTTP 200 `ok`）并将 HTTP 请求行解码升级为 `UTF-8`，解决扩展内部 `Proxy.adjustPort()` 探测失败落回 `-1` 端口以及中文片名参数（如 `vodName`）被按 Latin-1 解码导致弹幕搜索无结果的问题；同时在 `CspEngine` 实例化 Spider 后立即向内层 `DexClassLoader` 同步宿主代理端口。
   - **异步弹幕事件桥接（`com.fongmi.android.tv.event.RefreshEvent` + `PlaybackControls`）**：新增 `RefreshEvent.danmaku(String)` 宿主回调桥接，接收扩展在 `playerContent` 返回后通过后台线程异步推送的弹幕地址，自动完成本机代理重写并实时加载至播放器弹幕层。
   - **弹幕网络与 XML/JSON 容错解析（`DanmakuView` + `DanmakuData`）**：支持跨协议 301/302/307/308 重定向与代理鉴权头注入，清理 XML 非法控制字符，并在扩展拼装的 `<d p="...">` 弹幕包含未转义 `&` 或 `<` 触发 DOM 异常时自动回退正则容错提取。

3. **修复部分电视直播频道提示“需要解析或使用了特殊协议”及无法起播的问题**：
   - **代理重写前置与协议扩展（`PlaybackController` + `LiveController` + `Cms`）**：在 `PlaybackController.openPlayer` 校验 `Cms.isMedia` 之前先行调用 `ensureProxy` 与 `LocalProxy.rewrite`，解决 `proxy://` 直播流被误判为不支持协议的问题；扩展支持 `rtmps://`、`rtsps://`、`mmsh://`、`mmst://`、`srt://`、`rist://`、`webrtc://` 及 `webview://` 网页嗅探直播流，并在多源频道首条线路不可播或播放报错时自动切换备用线路。
   - **直播地址 `$线路名` 剥离与无后缀 HLS 嗅探（`LiveCatalog` + `MoviePlayer`）**：修复带 `?` 查询参数的直播地址未能剥离末尾 `$线路名` 标签以及 `host:port/path` 缺省协议头的解析问题；在 `MoviePlayer` 中为无 `.m3u8` 后缀的直播地址开启 `sniffMime` 头部探测与容器报错自动回退 `HlsMediaSource` 重试。

## 验证范围

- 通过 `CompatChecks`、`UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 正式签名校验。
