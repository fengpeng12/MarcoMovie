# Android 手机 / 平板 0.5.11

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.11`（`versionCode 61`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.11-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.11-mobile.apk`）

## 本次修复与改进

1. **修复云盘配置中心点击登录或顶栏「网盘」按钮时弹出 `JsonSyntaxException` 或 `IOException` 错误框的问题**：
   - 在 `CspEngine` 中精确检测内层 `Spider` 是否覆写 `action(String)`（`supportsCustomAction()`），对 `MyDrive` 等原生支持 `action` 的扩展不再回退调用 `detailContent`，并为 `PanConfig`、`Wexconfig`、`Config` 等扩展提供不强制要求返回非空 JSON 的 `detailAction(String)` 接口与首次调用 `homeContent(true)` 自动预热。

2. **修复非 `MyDrive` 配置源下点击「网盘」面板弹出 `LoginShow`、`panSortShow`、`panSourceSortShow` 字符串提示框的问题**：
   - 在 `SettingsScreen.accountAction` 中为 `Wexconfig`/`Wexokconfig` 映射真实网盘扫码与排序动作码（`quarkcookie`、`ucpancookie`、`aliyuntoken`、`panpaixu` 等），为 `csp_Config` 等通用配置源通过底部抽屉动态加载网盘分类与操作卡片列表，并在 `SourceController.sourceAction` 中过滤内部动作码回显。

3. **修复 `MyDrive` 已登录网盘目录中 JSON `vod_id`（`{...}`）视频文件的详情与播放路由**。

## 验证范围

- 通过 `CompatChecks`、`UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 正式签名校验。
