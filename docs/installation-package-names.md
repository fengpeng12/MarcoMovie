# 安装包命名

后续构建使用以下名称，`X.Y.Z` 为对应平台自己的版本号：

| 适用设备 / 用途 | 文件名 |
|---|---|
| 安卓手机、平板 | `MarcoMovie-X.Y.Z-android-mobile.apk` |
| 安卓电视、盒子 | `MarcoMovie-X.Y.Z-android-tv.apk` |
| Android Lite 精简版 | `MarcoMovie-X.Y.Z-android-lite.apk` |
| Windows 64 位安装版 | `MarcoMovie-X.Y.Z-windows-x64-setup.exe` |
| Windows 64 位免安装版 | `MarcoMovie-X.Y.Z-windows-x64-portable.zip` |
| Mac 桌面版 | `MarcoMovie-X.Y.Z-macos-desktop.zip` |
| iPhone、iPad 未签名包 | `MarcoMovie-X.Y.Z-ios-iphone-ipad-unsigned.ipa` |

同一文件旁提供同名 `.sha256` 校验文件。Mac 名称不额外宣称处理器架构；
具体兼容范围以该次构建的验证记录为准。iPhone 包保留未签名标识。

旧名称的文件作为更新兼容入口保留，内容必须与新名称完全相同。
发布同步程序优先使用新的清晰名称，同时兼容已有旧名称下载卡片；
只更新对应安装包链接、大小与校验信息，不改变镜像站排版。
Windows 的应用内更新入口继续使用旧版能识别的 `windows-setup.exe` 名称，
公开下载卡片显示新的 `windows-x64-setup.exe` 名称。发布前核对两者的大小与
SHA-256 完全一致；兼容文件缺失或不一致时，整次同步停止，不写入部分更新。

这些是后续打包规则，不代表本次已发布各平台新版本。
尤其 iPhone 的订阅与插件验收要求仍有效；命名调整不会绕过发布条件。
