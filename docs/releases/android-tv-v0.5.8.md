# Android 电视 / 盒子 0.5.8

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.8`（`versionCode 58`）
- 发布日期：2026-11-09
- 构建提交：`43084c56dc6b42c56884566f7792090268c18d71`
- 安装包：`MarcoMovie-0.5.8-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.8-preview.apk`）

## 本次修复与改进

1. **设置页全量专属矢量图标体系升级**：
   - 在 `SettingsScreen` 与 `MobileShell.SettingIconView` 中为电视端设置各层级条目（`首页与壁纸`、`播放与字幕`、`搜索与数据`、`软件更新` 及所有子项）配备语义化专属矢量图标与多色圆角徽章（涵盖界面缩放、导航栏字号、海报网格、壁纸画框、毛玻璃透明度、动态闪电、HDR 输出、播放器内核、硬件解码芯片、音频声波、画幅比例、倍速与缓冲仪表盘、连播下一集、片头片尾时间轴跃迁、字幕视窗、配置源码、直播天线、线路切换、插件扩展、网盘云盘、备份保险箱、诊断脉冲与清空回收桶等 22 种专属图标）。

## 验证范围

- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
