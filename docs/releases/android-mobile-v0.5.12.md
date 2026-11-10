# Android 手机 / 平板 0.5.12

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.12`（`versionCode 62`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.12-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.12-mobile.apk`）

## 本次新增与改进

1. **新增首页推荐卡片（「今日首推」巨幕卡片）独立开关**：
   - 在手机与平板端「设置 -> 界面外观与偏好 -> 界面显示与交互」中新增「首页推荐卡片」胶囊开关（`Prefs.SHOW_HERO_BANNER` / `show_hero_banner`，默认开启），并同步支持「完整高级设置 -> 首页与壁纸」中的同名开关与配置备份/还原校验。
   - 关闭后自动隐藏首页「推荐」分类顶部的「今日首推」巨幕大卡，直接展示紧凑海报墙；在设置页切换后返回「主页」立即生效。
   - 为「首页推荐卡片」设置项配备专属翡翠绿矢量首推卡片图标（`SettingIconView.ICON_HERO_CARD`）。

## 验证范围

- 通过 `ReviewFixChecks`、`CompatChecks`、`UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 正式签名校验。
