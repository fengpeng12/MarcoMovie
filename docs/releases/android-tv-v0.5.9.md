# Android 电视 / 盒子 0.5.9

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.9`（`versionCode 59`）
- 发布日期：2026-11-09
- 构建提交：`3b8a60c13a900cb8177f513e04b60449a08d1fe6`
- 安装包：`MarcoMovie-0.5.9-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.9-preview.apk`）

## 本次修复与改进

1. **修复网盘配置中心点击网盘配置偶发闪退（双层 `DexClassLoader` 与主线程生命周期同步）**：
   - 在 `CspEngine` 中递归穿透双层加载器（`Init.loader()` 与 `BaseSpiderGuard` 委托类加载器），自动发现并绑定内层 `com.github.catvod.spider.InitOrigin` 单例的活跃 `Activity` 字段（`InitOrigin.get().d`），避免插件反射 `ActivityThread.mActivities` 失败或取到空上下文。
   - 将 `replayForegroundActivity` 对 `Application.mActivityLifecycleCallbacks` 的替换注册与首次 `onActivityCreated` / `onActivityStarted` / `onActivityResumed` 生命周期回放统一收敛至主线程执行，并移除每次 `CspEngine.call()` 重复回放生命周期回调的逻辑，消除插件内部进度浮层（`f0.d.d()`）在每次请求时反复向 `android.R.id.content` 拆卸与挂载视图导致的电视端焦点遍历与布局偶发闪退。
   - 在 `MainActivity.requestPermissions` 中增加跨线程派发与活跃状态保护，防止扩展在后台工作线程调用 `ActivityCompat.requestPermissions` 引发异常；同时将 `com.wexfnw.*` 与内层 `BaseDexClassLoader` 纳入 `ListingRoute` / `MainActivity` 扩展异常拦截范围。

2. **修复点击网盘扫码登录及网盘配置卡片无反应的问题**：
   - 在 `SourceController.sourceAction` 中，当扩展未重写 `Spider.action(id)`（返回空串）时，自动回退调用 `detailContent(id)` 以触发 `csp_PanConfigGuard` / `csp_PanConfig` 系插件在 `detailContent` 内挂载的扫码登录弹窗（夸克、UC Cookie/Token、百度、115、天翼、移动、光鸭、迅雷、哔哩）、手动凭据输入弹窗、网页配置中心及线路排序弹窗。
   - 识别并静默处理配置中心返回的占位详情 JSON（`设置成功后刷新配置中心`），避免宿主弹出二次列表框遮挡插件自身的二维码弹窗；并在扫码弹窗关闭恢复焦点或执行清理/开关操作后自动刷新当前配置分类卡片状态。
   - 适配顶部“网盘与账号”面板（`AccountPanel` + `SettingsScreen.accountAction`）：在 `PanConfig` 配置源下点击“网盘登录与启用”直接弹出全网盘扫码与登录菜单，点击“登录凭据配置”唤起网页配置中心，点击“网盘优先顺序 / 搜索顺序”唤起网盘线路排序；电视端进入配置中心时直接平铺展示全部 12 个网盘分类标签并隐藏无关筛选按钮。

## 验证范围

- 通过 `UpdateLayoutChecks` 与 `UpdateEditionChecks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
