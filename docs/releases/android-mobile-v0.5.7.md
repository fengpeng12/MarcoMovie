# Android 手机 / 平板 0.5.7

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.7`（`versionCode 57`）
- 发布日期：2026-11-08
- 构建提交：`37e4b123c74dd8104b6805985d7141179e448fa0`
- 安装包：`MarcoMovie-0.5.7-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.7-mobile.apk`）

## 本次修复与改进

1. **影视选集页海报视野扩容与片名位置下移**：重构 `MobileDetailScreen` 竖版全屏海报视窗（`posterWindowH` 扩展至屏幕高度的 `85%`）与前景主视觉区（`foregroundHeroH` 扩展至海报视窗的 `81%`），将片名、评分与元信息胶囊整体下移约 `100dp`–`110dp`，让上半幅高清竖版海报主体展示更完整、构图更舒展。
2. **渐进磨砂模糊与暗色过渡精准贴合新标题高度**：同步调整 `PortraitBackdropView` 的默认模糊起始线、人物主体居中偏上构图矩阵（`0.26f`）与底部环境色羽化梯度，确保磨砂模糊恰好从下移后的片名顶部平滑展开，既最大化展现清晰海报画面，又完全不影响下方简介与选集列表阅读。

## 验证范围

- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
