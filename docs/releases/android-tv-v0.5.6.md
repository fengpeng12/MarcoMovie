# Android 电视 / 盒子 0.5.6

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.6`（`versionCode 56`）
- 发布日期：2026-11-08
- 构建提交：`95121d25c30972170a3e1d94e7dcc73b5cced690`
- 安装包：`MarcoMovie-0.5.6-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.6-preview.apk`）

## 本次修复与改进

1. **修复点击配置网盘闪退及重置片源（0.5.3–0.5.5 回归修复）**：修复冷启动 `recreate()` 与 Android 10/11+ 隐藏 API 限制导致扩展插件 `Init` 未绑定当前活跃 `MainActivity`、进而在点击“登入自己网盘”或“网盘与账号”弹窗时闪退的问题；同时识别 `vod_tag="action"` 网盘配置卡片并跳过后台 `prefetchDetail`，防止后台预取详情干扰网盘交互或误触发崩溃保护重置片源。
2. **首页换源弹窗三列高密度网格重构**：同步升级电视端 `SourcePicker` 换源弹窗为三列紧凑胶囊网格，顶部标题栏整合片源总数徽章与“默认偏好源”入口，显著减少卡片空白区域并减少遥控器翻页次数。
3. **设置页 iOS 风格胶囊开关与焦点反馈优化**：电视端设置页内的布尔开关项同步配备 `IosSwitchView` 胶囊指示器，按遥控器确认键原地平滑切换状态，消除整页重绘引起的焦点闪烁。
4. **全屏字幕调节与抽屉窗口尺寸加固**：统一在 `Dialog.show()` 之后锁定全屏与右侧抽屉的窗口布局尺寸，确保在各类电视固件与缩放比例下稳定展示。
5. **软件更新优先拉取镜像站与 iOS 风格更新页重构**：检查更新与下载 APK 安装包均优先拉取镜像站（`marcotv.wlj9919.top`），失败自动无缝回退 GitHub；软件更新页同步升级为 iOS 系统更新卡片式高级 UI，并支持各平台版本号独立推进。

## 验证范围

- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 全部单元与回归测试。
- 通过 Android TV 实机 `HomeProbe` 与 `LayoutProbe`（100% / 110% / 120% 缩放）自动化验收。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
