# Android 手机 / 平板 0.5.8

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.8`（`versionCode 58`）
- 发布日期：2026-11-09
- 构建提交：`43084c56dc6b42c56884566f7792090268c18d71`
- 安装包：`MarcoMovie-0.5.8-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.8-mobile.apk`）

## 本次修复与改进

1. **设置页全量专属矢量图标体系重构（告别同页单一重复图标）**：
   - 重构 `MobileShell.SettingIconView` 与各级设置子菜单（`片源与直播配置`、`播放、解码与字幕`、`界面外观与偏好`、`备份、更新与诊断` 及高级设置页 `SettingsScreen`），为全部 22 类设置项绘制专属语义化矢量图标与独立色彩徽章：
     - **片源与直播配置**：剪贴板夹板（`ICON_CLIPBOARD`）、代码括号 `</>`（`ICON_LINK_CODE`）、本地文件夹（`ICON_FOLDER_FILE`）、双天线电视直播屏（`ICON_LIVE_TV`）、双向切换箭头（`ICON_SWITCH_SOURCE`）、模块化扩展积木（`ICON_PLUGIN_EXT`）。
     - **播放、解码与字幕**：播放核心圆环（`ICON_ENGINE_CORE`）、多引脚硬件解码芯片（`ICON_DECODER_CHIP`）、HDR 柔光显示屏（`ICON_HDR_TUNNEL`）、双三角下一集连播（`ICON_AUTO_NEXT`）、时间轴弧形跃迁箭头（`ICON_SKIP_TIMELINE`）、字幕双轨视窗（`ICON_SUBTITLE`）。
     - **界面外观与偏好**：四角外扩缩放框（`ICON_UI_SCALE`）、`Aa` 导航排版字标（`ICON_NAV_FONT`）、双层毛玻璃圆片（`ICON_GLASS_BLUR`）、动态闪电（`ICON_MOTION_SPARK`）、清空回收桶（`ICON_TRASH_CLEAR`）。
     - **更新、备份与诊断**：环形更新云标（`ICON_UPDATE_CLOUD`）、心电脉冲诊断屏（`ICON_DIAGNOSTIC_LOG`）、备份保险箱（`ICON_BACKUP_SAFE`）及壁纸画框、海报网格、音频均衡波、画幅比例、仪表盘与历史循环图标。

## 验证范围

- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
