# Glasswork 接入记录

依据 [Glasswork 的 AI 接入指南 INSTALL.md](https://github.com/kubai087/glasswork/blob/4f0b6744b898b3a9b98fbd913ab24fdb83c53162/INSTALL.md)。该仓库没有 SKILL.md，INSTALL.md 是作者给 AI 编程工具的正式接入指令。对应源文件为同一版本的 glass.css、lens.js、adapt.js、refract.js，许可副本保存在 Flutter shaders 和 Android assets 中。

## 材质覆盖范围

| 表面 | 组件／文件 | 处理 |
| --- | --- | --- |
| 横竖屏 Dock、浮动玻璃控件 | `flutter/src/ui/apple_theme.dart` 的 LiquidGlass、AppleLiquidGlassDock | 统一玻璃背景与边缘，保留布局和交互 |
| 工具栏、弹窗、玻璃卡片 | 同文件 AppleGlassSurface、GlassworkBackdrop、showAppleModalSheet | 通过公共材质组件继承 |
| 播放器浮动控件 | `flutter/src/ui/player_screen.dart` 中的 LiquidGlass | 继承公共材质 |
| 换源卡片、普通设置列表 | `flutter/src/ui/source_choice_sliver.dart`、adaptive_shell | 纯色容器上的列表保持普通材质，避免叠加模糊变灰 |
| 原生 TV／手机 Dock、顶部胶囊 | `HomeDock.java`、`MobileShell.java` | 共用有上限的背景采样、模糊、边缘折射与高光 |
| 原生手机详情页海报上的返回、换源、操作胶囊与资料标签 | `MobileDetailScreen.java` | 共用材质，保留布局、圆角和字体 |
| 原生弹窗、换源、提示 | `AppDialog.java`、`SourcePicker.java`、`MainActivity.java` | 同一材质和减少透明效果设置 |
| 原生播放器浮动控件 | `PlayerChrome.java` | SurfaceView 使用 PixelCopy 小尺寸帧，TextureView 使用位图采样；不可读画面使用暗色回退 |
| Lite 播放器顶部及底部操作层 | `LiteActivity.java` | API14 视频采用同一暗色／边缘高光回退，保持原矩形轮廓 |

## 本轮具体修改

- `flutter/shaders/glasswork.frag` 移植 rim=40、edge=1.1、power=2.6、dispersion=±0.15，边缘折射随圆角变化，中间保留平坦区域。
- 参照 refract.js 加入中心与 12 个螺旋采样的 2px 模糊。参照 adapt.js 采样 5×3 网格，剔除最亮和最暗各两个点，根据纹理和色彩调整浓度。
- 采用项目现有暗色外观对应的 Glasswork dark 参数，饱和度 1.6、亮度 0.8、基础染色 0.16–0.38。按文字对比需求提高染色浓度，替代旧实现对所有颜色的固定亮度封顶。
- `flutter/src/ui/apple_theme.dart` 去掉材质上重复叠加的厚重灰色渐变，调整边缘高光比例。减少透明度／高对比模式使用实色。窗口不支持背景 shader 滤镜时采用模糊、暗色染色和边缘高光回退。弹窗移除独立的 44px 厚重模糊层，改用相同的 LiquidGlass 公共材质。
- `shared/java/com/pilipala/glass/GlassworkMaterial.java` 提供可离线验证的原生像素处理：同源采样／染色参数、2dp 高斯模糊、圆角距离边缘折射与色散。按整幅采样图像的最差颜色提高染色，保证指定前景色的 4.5:1 对比；这不替代界面中每种文字颜色的实机验收。
- `shared/java/com/pilipala/glass/GlassworkSurface.java` 只抓取目标前的背景与兄弟视图，避免把控件自己的文字画进玻璃；每片最多 24,576 像素、最长边 384，单个处理线程和最多 4 项等待。滚动、布局、图片或柔光变化触发刷新，限制到每 100ms 一次，无静止页面轮询；卸载移除监听并丢弃过期结果。`VideoOutput.java` 新增共享异步画面读回，`PlaybackController.java` / `PlaybackControls.java` 随播放状态启动和停止刷新；不可读画面回退为暗色可读面板。
- 原生刷新接线文件为 `ImageLoader.java`、`HomeAmbient.java`；减少透明效果涉及 `Prefs.java`、`SettingsScreen.java`、`MobileShell.java` 与 `HomeScreen.java` 的外观缓存判断。原生界面目前只有暗色外观；像素处理器的浅色模式仅有离线检查，未宣称已有原生浅色主题。
- 许可补充 `lite/licenses/glasswork.txt`；像素测试为 `android/tests/GlassworkChecks.java`、`run_glasswork_checks.py`，备份设置校验更新在 `ReviewFixChecks.java`，并接入 `.github/workflows/build-multiplatform.yml`。

## 验证边界

Windows 开发构建已启动并查看首页、侧边 Dock 和换源弹窗。Windows 当前使用回退材质，不能据此证明背景折射已在 iOS／Android 真机生效。Flutter shader 资源已构建，移动端仍需验证真实背景采样坐标、滚动时性能、播放画面覆盖、文字对比度及减少透明度行为。

原生 TV／手机和 Lite 已通过编译及开发包构建；像素测试覆盖 14 组浅／深色背景、输入不被修改、极小画面及尺寸限制。原生背景采样接线尚无设备执行证据，视频 SurfaceView 已接入 PixelCopy，尚无设备执行证据。当前不声称全端折射一致或设备性能验收通过，不能把材质代码存在等同于真机完成。
