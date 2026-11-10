# Android 手机 / 平板 0.5.6

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.6`（`versionCode 56`）
- 发布日期：2026-11-08
- 构建提交：`95121d25c30972170a3e1d94e7dcc73b5cced690`
- 安装包：`MarcoMovie-0.5.6-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.6-mobile.apk`）

## 本次修复与改进

1. **首页换源弹窗多列紧凑网格排版**：重构 `SourcePicker` 换源弹窗，竖屏采用双列高密度胶囊网格（横屏与平板采用三列网格），并将顶部标题、“XX 个片源”计数徽章与“默认偏好源”快捷按钮整合于同一导航行，彻底消除单列超宽卡片的大片空白，同屏可见片源数翻倍。
2. **播放页右侧工具条收窄拉长与进度条左右等距对齐**：将手机播放界面右侧竖置工具条宽度收窄至 `48dp`（横屏）/ `52dp`（竖屏），拉长纵向可视高度并上移至底部进度条上方；底部进度条与时间轴实现左右边距严格一致的居中对称布局。
3. **修复横竖屏旋转后无法恢复竖屏 UI 布局**：在 `MainActivity.onConfigurationChanged` 与 `MobileShell` 根视图布局监听中实时同步屏幕方向与视口尺寸，彻底解决从竖屏旋转为横屏再转回竖屏时卡在横屏布局（5 列海报 + 右侧导航栏）的问题。
4. **修复设置页抽屉选择器显示异常**：修正 `MobileShell.showDrawerPicker` 及播放页字幕抽屉在 `Dialog.show()` 之后显式声明 `MATCH_PARENT` 窗口宽高的时序，解决抽屉坍缩为屏幕中央窄条的问题。
5. **设置页布尔开关升级为 iOS 胶囊拨杆样式**：针对仅有“开启 / 关闭”两种状态的设置项（第三方扩展、4K HDR 隧道模式、自动连播下一集、减少透明效果、精简界面动画等），采用 iOS 风格胶囊开关（`IosSwitchView`）原地平滑切换，不再弹出抽屉。
6. **优化设置页卡片点击反馈**：将设置卡片触控反馈升级为毛玻璃表面高亮与微缩放（`0.986x`）动效，消除旧版整卡半透明闪烁与整页重绘跳变。
7. **软件更新优先拉取镜像站资源**：`UpdatePolicy` 与 `UpdateManager` 在检查更新源与下载 APK 安装包时均优先连接高速镜像站（`marcotv.wlj9919.top`），遇到 404 或网络异常时立即无缝回退 GitHub。
8. **iOS 系统更新风格软件更新页与各平台版号独立推进**：参考 iOS `通用 -> 软件更新` 页面重构 `UpdateScreen`（圆角图标徽章、版本号与包体积头卡、线性进度条、分组版本说明与自动更新策略卡片），并引入 `android/edition-versions.json` 支持各平台版号独立推进。
9. **修复网盘配置片源交互与插件 Activity 同步**：支持在手机端完整展示并触发“我的云盘┃配置”片源下的登录与清除凭据动作卡片，同步修复插件弹窗 Activity 绑定与后台详情预取隔离。

## 验证范围

- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
