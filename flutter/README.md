# Marco Movie · Flutter 客户端

本目录覆盖 Windows、macOS、iPhone、iPad。原生 Android 手机/平板版、电视版和 Lite 使用各自安装包。各端使用共用配置格式的部分字段，但插件运行环境和备份字段支持并不完全相同，详见[兼容与验证边界](../docs/COMPATIBILITY.md)。

应用不内置影视资源或订阅，配置由用户自行提供。

## 界面与操作

- 四栏 Dock：竖屏底部，横屏右侧；拖动预览，松手切换。宽屏详情采用分栏布局。
- 设置一级只显示分类标题，当前值和说明在二级页面。
- 片源选择显示分组与数量；管理页面可调整顺序、删除单条来源并保存。
- 桌面播放器支持 F / 双击全屏、Esc 先退出全屏、空格暂停、方向键快进快退及调节音量。移动端使用方向切换和触控操作。
- 玻璃材质参考 Glasswork；支持的 Flutter 渲染器使用折射 shader，其他环境使用模糊回退，减少透明度选项使用实色。效果仍须在对应设备验收。

## 备份与恢复

备份是用户主动导出/导入 JSON，**不是云端自动同步**。Flutter 备份包含公开订阅、禁用状态、线路管理、收藏/历史、播放和外观偏好；恢复替换公开订阅并保留当前设备的私密订阅。常规导出排除私密订阅及混合订阅内标记为私密的来源。

Android 可读取共用的配置、历史、收藏字段；不应通过 Android 再导出后假定所有 Flutter 专用字段仍保留。恢复前校验数据结构；存储介质故障不具备数据库事务保证。

## 构建

当前流水线固定 Flutter **3.38.9**，并提交 `pubspec.lock` 保持依赖可复现。iOS 14 目标必须检查实际 Flutter 引擎、原生插件和 Framework 最低系统版本，不能只修改 Info.plist 或二进制声明。Windows 机器不能完成 iOS 编译及真机验收。

```sh
cd flutter
flutter create --platforms=windows,macos,ios --project-name=marco_movie .
python prepare_platform.py
flutter pub get
cmake -S packages/quickjs_engine/native -B packages/quickjs_engine/native/build -DCMAKE_BUILD_TYPE=Release
cmake --build packages/quickjs_engine/native/build --config Release --parallel 4
flutter test
flutter build windows --release
# 以下在 Mac 上执行
flutter build macos --release
flutter build ios --release --no-codesign
```

`src/` 为受版本控制的源码，`prepare_platform.py` 同步到生成目录 `lib/` 并准备品牌资源、平台配置。不要只修改生成的 `lib/`。自动构建入口见 [workflow](../.github/workflows/build-multiplatform.yml)；产物名称以实际上传的附件为准。
