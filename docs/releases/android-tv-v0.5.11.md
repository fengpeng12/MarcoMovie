# Android 电视 / 盒子 0.5.11

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.11`（`versionCode 61`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.11-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.11-preview.apk`）

## 本次修复与改进

1. **修复云盘配置中心（`csp_MyDriveGuard` / `csp_MyDrive`）点击「登入自己网盘」或右侧导航栏「网盘」按钮时弹出 `JsonSyntaxException` 或 `IOException` 错误框的问题**：
   - **精确识别自定义 `action` 实现（`CspEngine.supportsCustomAction` + `SourceController.sourceAction`）**：通过解包 `BaseSpiderGuard` 内层 `Spider` 实例并检测是否覆写 `Spider.action(String)`，对原生实现 `action` 的网盘扩展（如 `MyDrive`、`Wexokconfig`）仅调用 `action(String)`，不再于其正常返回空串并弹出原生登录框后误调用用于解析云盘目录 JSON 的 `detailContent(List)`（消除在原生弹窗上方叠加 `扩展来源请求失败：JsonSyntaxException` 的问题）。
   - **首次调用自动预热（`CspEngine.ensureConfigHomeWarmed`）**：当用户直接从普通点播首页点击右侧导航栏「网盘」按钮（尚未进入配置中心分类页）时，在执行 `action` 或 `detailAction` 前自动静默预热一次 `homeContent(true)`，确保扩展内部网盘列表与上下文完成初始化。
   - **新增免 JSON 校验的交互通道（`CspEngine.detailAction`）**：对通过 `detailContent` 响应配置动作的扩展（如 `PanConfig`、`Wexconfig`、`Config`），调用专用 `detailAction` 而不触发 `CspEngine.detail` 的非空与 JSON 格式强制校验，彻底消除 `扩展来源请求失败：IOException`。

2. **修复在 `Wexconfig`、`Config` 等配置源下点击「网盘」面板弹出 `LoginShow`、`panSortShow`、`panSourceSortShow` 字符串提示框的问题**：
   - **多配置源动作适配（`SettingsScreen.accountAction`）**：精准区分 `MyDrive`、`PanConfig`、`Wexconfig`/`Wexokconfig` 与通用 `csp_Config` 配置中心；为 `Wexconfig`/`Wexokconfig` 接入真实网盘动作码（`quarkcookie`、`ucpancookie`、`uctvpancookie`、`aliyuntoken`、`baidupanlogin`、`115pancookie`、`tianyilogin`、`ydyuncookie`、`pan123login`、`panxunleiuser`、`bilicookie`、`pankaiguan` 及排序码 `panpaixu`），并为 `csp_Config` 等通用配置中心动态读取分类与操作项列表（或自动匹配 `pan_order` 排序卡）。
   - **拦截内部动作码回显（`SourceController.isInternalActionCode`）**：当扩展原样返回传入的动作标识符时不再将其作为提示消息弹窗。

3. **修复 `MyDrive` 网盘文件卡片识别（`SourceController.isConfigOrNetdiskActionCard`）**：
   - 在 `MyDrive` 已登录的网盘目录分类下，保留以 `{` 开头的 JSON `vod_id` 视频条目进入详情与播放流程，不再误判为配置动作卡。

## 验证范围

- 通过 `CompatChecks`、`UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 正式签名校验。
