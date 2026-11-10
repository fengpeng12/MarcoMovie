# Android 电视 / 盒子 0.5.12

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.12`（`versionCode 64`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.12-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.12-preview.apk`）

## 本次修复与优化

1. **首页分类标签遥控器聚焦直接切换（无需二次按确认键）**：
   - 修复 `HomeScreen.navigationKey` 拦截方向键焦点跳转时未更新分类切换时间戳导致聚焦自动切换未触发的问题（`HomeScreen.addTab`）。
   - 现在在电视端首页将焦点移动到「推荐」「热门电影」「热播剧集」等任意分类胶囊时，停留 120ms 即自动切换并加载对应分类内容，无需再次按遥控器确认键。

2. **修复夸克网盘（夸父）等网盘分享线路播放后不生成历史记录的问题**：
   - 部分网盘分享扩展（如 `Wogg`、`Wobg`、`PanHj`、`Panku`、`AiMacPanSite` 等）在 `detailContent` 返回的详情对象中未回填 `vod_id`（返回空字符串 `""`），导致播放页写入历史记录时 `id` 为空并在读取时被过滤丢弃。
   - 在 `SourceController.loadDetail`、`DetailScreen`、`MobileDetailScreen` 及 `PlaybackController.playerPage` 中自动回填列表项 `id`（并在极端缺失时回退剧集地址或标题作为唯一标识），同时在播放结束回调（`OnCompletionListener`）中强制落盘完整播放进度，确保网盘线路起播、中途退出与完整看完均能正常生成和更新观看历史与收藏状态。

3. **修复网盘登录与「网盘与账号」选项弹出 `JsonSyntaxException` 的问题**：
   - 修复 `MyDriveGuard`（`我的云盘 | 配置`）等支持 `action(String)` 的扩展在成功弹出原生登录窗口并返回空串后，被二次调用 `detailContent` 触发 `JsonSyntaxException` 异常提示的问题。
   - 完善 `CspEngine.supportsCustomAction` 对 `BaseSpiderGuard` 包装类的识别及 `detailAction` / `detail` 对 `JsonSyntaxException` 的 `action(String)` 兜底回退，并同步 `Application.mActivityLifecycleCallbacks` 内层 JNI 插件 `ClassLoader` 的 `Activity` 上下文。

4. **内置播放器新增 TVBox 同款 `Exo (Media3)` 与 `IJK (FFmpeg)` 双内核切换**：
   - 在设置页「播放、解码与字幕 -> 播放器内核」及播放页控制栏「播放器与解码」菜单中支持直接切换 `Exo (Media3)`、`IJK (FFmpeg)` 与 `系统播放器`。
   - `IJK (FFmpeg)` 模式内置 FFmpeg 软解扩展优先、快速起播缓冲、非关键帧跳转及 TS/HLS/MP4 双向容错回退，并支持根据扩展源返回的 `playerType` 自动匹配内核。

## 验证范围

- 通过 `check_public_content.py` 公开内容合规扫描與 `build_android.py` 正式签名与对齐校验。
