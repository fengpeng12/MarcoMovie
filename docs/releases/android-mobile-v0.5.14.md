# Android 手机 / 平板 0.5.14

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.14`（`versionCode 65`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.14-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.14-mobile.apk`）

## 本次修复与优化

1. **修复夸克网盘（夸父）等网盘分享线路播放后不生成观看历史与收藏异常的问题**：
   - 在 `SourceController.loadDetail`、`MobileDetailScreen` 与 `PlaybackController.playerPage` 中自动继承并回填列表项 `vod_id`，并在剧集播放完成回调（`OnCompletionListener`）中立即持久化完整播放进度，解决部分网盘扩展详情返回空 `vod_id` 导致看完后无历史记录的问题。

2. **修复「网盘与账号」与云盘配置选项提示 `JsonSyntaxException` 无法进入的问题**：
   - 修复 `MyDriveGuard`（`我的云盘 | 配置`）等扩展在响应 `LoginShow`、`pushCkShow`、`panSortShow`、`panSourceSortShow` 动作时因 `BaseSpiderGuard` 包装识别或空返回值二次触发 `detailContent` 导致抛出 `JsonSyntaxException` 的问题。
   - 增加 `detailAction` / `detail` 对 `JsonSyntaxException` 的 `action(String)` 自动回退，并同步 `Application.mActivityLifecycleCallbacks` 内层 JNI 插件 `ClassLoader` 的 `Activity` 上下文，确保网盘扫码、Cookie 推送与排序弹窗正常打开。

3. **内置播放器新增 TVBox 同款 `Exo (Media3)` 与 `IJK (FFmpeg)` 双内核切换**：
   - 在手机端「设置 -> 播放、解码与字幕 -> 播放器内核」及播放页顶栏「播放器与解码」菜单中支持直接切换 `Exo (Media3)`、`IJK (FFmpeg)` 与 `系统播放器`。
   - `IJK (FFmpeg)` 模式启用内置 FFmpeg 扩展优先解码、快速起播缓冲、宽松 TS/MP4 提取器容错及 HLS/直链双向回退，并支持按扩展源返回的 `playerType` 自动选择对应播放器内核。

## 验证范围

- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 正式签名与对齐校验。
