# FY 本机移植进度

当前状态：协议与 Flutter 应用入口已接入；Android 原生界面尚未接入，
未完成真实线路及 iPhone 真机验收。

## 已实现并测试

- 从已审阅版本的原订阅插件提取配置。验证整个文件、内部方法和 Python
  文本的摘要；只读取数据，不执行插件中的 Android 或 Python 代码。
- 在设备自身的 Node 18 运行时中处理分类、地区/年份等筛选、分页、搜索、
  详情和选集，按原线路标识关联剧集并恢复集数顺序。
- 处理播放页数据、解析服务令牌和表单提交；失败时尝试原配置的备用解析。
  不会把未解析成功的资源标识当作可播放地址。
- 会话按来源保存，并限制到设置它的站点和路径。覆盖多条 Set-Cookie、
  过期/删除、Secure、重定向、解析服务隔离及重新打开后的状态恢复。
- 提供获取验证码图片和提交用户输入的接口。刷新后旧验证码失效，错误输入
  可重试；没有自动识别验证码、远程识别服务或原生进程调用。
- Flutter 的首页、详情、搜索和播放失败提示中提供“完成验证”。用户主动打开
  Glasswork 材质弹窗后输入图片字符，成功后重试原操作；取消、切换来源或删除
  来源会关闭对应弹窗并中止验证请求。后台搜索不会自动弹出验证码。
- 验证后重试筛选保留原条件；搜索只重试对应来源，保留其他来源已返回的结果。

本机回归使用合成网页和测试服务：7 组配置/边界检查、9 组实际共享宿主
调用检查，另有 20 组插件引导和 19 组 DRPY 回归。测试中的固定验证码只属于
本地测试服务。它们不能证明外部网站或 iPhone 实机播放正常。

`39e6adf` 的 [iOS 运行时检查](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42390812235)
在 ARM64/iOS 26.2 和 Intel/iOS 18.5 均通过 60 项检查，其中 9 项新增检查覆盖 FY
分类、手动验证、会话、分页、选集、解析与本地 HLS 清单。所有记录的源码和测试
输入摘要均与该提交匹配。此运行早于 Flutter 界面接入，不能作为新界面的验证。

随后 Flutter 全量本机回归通过 194 项，其中 12 项验证图像数据边界、调用来源、
错误与刷新、取消迟到请求、移除来源、首页/筛选/搜索重试，以及小屏、横屏、
大字体和键盘布局。完整 iOS 构建结果需另行记录。

## 尚未完成

- 在 Android 原生应用中接入 FY 线路和验证交互。
- 在完整 iOS 安装包中核对原订阅的实际导入行为和界面交互。
- 外部站点目录、搜索、各播放线路和实际媒体解码的完整验证。
- iPhone 真机验证。

本次匿名请求在外部站点建立连接时失败，无法据此声称线路已恢复。这里的
专用适配器也不等于完整 CPython：其他 Python 源仍受各自依赖和协议限制。
正式发包继续遵守所有所需订阅类型及插件线路通过验收的要求。

## Flutter 界面接入修改文件

- `flutter/src/core/source_verification.dart`：受限图片响应数据。
- `flutter/src/core/cms_client.dart`：验证请求、取消及首页验证错误传递。
- `flutter/src/core/csp_bridge.dart`、`flutter/src/core/catpaw_host.dart`：FY 入口与可信错误提示。
- `flutter/src/ui/source_verification_dialog.dart`：复用既有 Glasswork 材质的验证码弹窗。
- `flutter/src/ui/adaptive_shell.dart`：首页、筛选和搜索验证后的定向重试。
- `flutter/src/ui/detail_screen.dart`、`flutter/src/ui/player_screen.dart`：详情与播放验证入口。
- `flutter/test/source_verification_test.dart`、`flutter/test/guard_source_test.dart`：交互和线路分派回归。
- `docs/ios-source-acceptance.md`、本文：证据范围和未完成事项。
