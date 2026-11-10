# Android 手机 / 平板 0.5.9

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.9`（`versionCode 59`）
- 发布日期：2026-11-09
- 构建提交：`3b8a60c13a900cb8177f513e04b60449a08d1fe6`
- 安装包：`MarcoMovie-0.5.9-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.9-mobile.apk`）

## 本次修复与改进

1. **修复网盘配置中心（`csp_PanConfigGuard` / `csp_PanConfig`）点击网盘扫码与配置卡片无反应的问题**：
   - 在 `SourceController.isConfigOrNetdiskActionCard` 与 `sourceAction` 中完整识别专用配置中心片源下的全部操作卡片；当扩展 `Spider.action(id)` 返回空串时自动回退调用 `detailContent(id)` 触发插件内置的各网盘扫码登录弹窗、手动输入 Cookie/Token 弹窗、清理凭据、网页配置中心及代理加速开关。
   - 过滤配置中心占位详情返回（`设置成功后刷新配置中心`），防止覆盖插件二维码弹窗，并在扫码弹窗关闭或切换配置开关后自动刷新当前网盘分类列表状态。
   - 顶栏“网盘”胶囊面板（`AccountPanel` + `SettingsScreen.accountAction`）新增 `PanConfig` 全网盘扫码抽屉菜单、网页配置中心推送与网盘线路排序直接联动；进入配置中心片源时自动定位首个分类并隐藏无关筛选按钮。

2. **增强双层 `DexClassLoader`（`InitOrigin`）扩展稳定性与生命周期同步**：
   - 在 `CspEngine` 中递归穿透 `Init.loader()` 内层类加载器，自动同步 `InitOrigin.get().d` 活跃 `Activity` 引用，将 `Application.mActivityLifecycleCallbacks` 包装注册及首次生命周期回放移至主线程，并在 `MainActivity.requestPermissions` 中拦截后台线程权限请求，杜绝点击网盘配置时偶发闪退。

## 验证范围

- 通过 `UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
