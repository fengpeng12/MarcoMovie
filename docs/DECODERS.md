# 内置解码组件

Marco Movie 0.3.3 将以下组件随 ARM 32 位 APK 提供，无需另外安装解码器应用。

| 组件 | 用途 |
| --- | --- |
| Media3 1.5.1 + FFmpeg 6.1.6 | 软件解码 AAC、AC3、E-AC3、DTS/DTS-HD、TrueHD、FLAC、ALAC、Opus、Vorbis、MP3、AMR、部分 PCM 音频 |
| Media3 + libgav1 0.19.0 | AV1 视频软件解码 |
| Media3 + libvpx 1.15.2 | VP9 视频软件解码 |

格式列表表示编译启用的能力，不是所有封装、声道、位深和文件的通过清单。H.264、H.265 仍使用 Android 设备提供的解码器；没有集成 FFmpeg 视频解码器。音频扩展输出 PCM，不等于 Dolby Atmos / DTS:X 对象音频透传，也不改变功放或电视的能力。DRM 内容仍需合法许可和兼容设备。

## 使用方式

在“设置 → 播放 → 解码方式”选择自动、硬件或软件优先。自动模式优先使用设备解码器；遇到可识别的解码错误，最多重试一次软件路径。音频错误只优先切换音频，避免不必要地将视频改成软解码。网络、地址失效、解析及授权错误不会触发这次重试。

硬件模式限制视频使用设备硬件，音频仍可使用扩展。软件优先模式优先使用 AV1 / VP9 / FFmpeg 扩展；没有视频扩展的格式使用系统提供的软件解码器。系统播放器不使用这些 Media3 扩展。

“解码组件”页面检查实际加载情况；播放菜单里的“播放信息”显示正在工作的音视频解码器。仅安装了库不代表某次播放使用了它。

## 性能与验证边界

电视的 CPU、内存、散热、分辨率和码率会影响软解码。低分辨率样本成功不能代表 4K、高码率、10 位、HDR、长时间播放都流畅。建议保留自动模式。具体实测记录见 [STATUS.md](STATUS.md)。

## 构建与对应源码

二进制由本项目从官方固定提交构建，不提取其他播放器的闭源组件。`android/decoder-dependencies.json` 固定下载地址和 SHA-256；库摘要及上游提交在 `android/src/main/assets/decoder-licenses/provenance.json`。

[解码组件发布页](https://github.com/Pilipala9919/MarcoMovie/releases/tag/decoders-1.5.1-armv7-v1) 同时提供原生库、完整对应上游源码包、构建配方和摘要。源码包中的各 `*-source.tar` 保留上游源码和许可证；`build/` 提供固定提交与编译参数。也可在本仓库用 Linux、Python 3、CMake、Ninja、Make、Git、NDK r26b 运行：

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk-r26b
python scripts/native/build.py
```

输出在 `native-output/`。脚本按固定提交获取源码并构建；可修改源码和构建脚本后重新构建库，将依赖清单指向新归档并更新摘要，再构建和自行签名应用。自行签名可能不能覆盖原签名安装包。

Media3 扩展 Java 源码采用 Apache-2.0 并保留版权头。本项目未采用尚未实现的 `ExperimentalFfmpegVideoRenderer`；将 FFmpeg Java 注解替换为已有 AndroidX 注解以适配构建，VP9 的加载名称由应用适配静态链接方案。FFmpeg 禁用 GPL 组件与编码器，仅启用列出的解码器；保留上游完整许可文件，不将所有上游文件都解释为此次二进制启用的功能。

独立音频设置：“优先使用兼容音频解码”只改变音频扩展顺序；“优先选择 AAC 音轨”只影响媒体已有的可用音轨，不做转码。二者均不作用于系统播放器。原生构建额外应用 `scripts/native/patch_ffmpeg.py`，初始化 TrueHD 声道布局，并在跳转时保留上下文后清空缓冲；针对 [Media3 #1843](https://github.com/androidx/media/issues/1843) 记录的问题，修复结果由本项目合成样本实测确认。
