# Marco Movie Android Lite 0.5.2

发布日期：2026-11-10。各平台独立推进版本。

## 修复

- HLS 分片、密钥和重定向分别检查来源，跨来源请求不再继承 Cookie、Authorization 等登录信息。
- 在系统支持时明确启用 TLS 1.2 / 1.3；不支持时返回清晰提示，并保留证书校验。
- 纠正正式版 TLS 兼容说明：标准包没有打包 Conscrypt，Android 4.0 不因此获得现代 HTTPS 能力。

## 验证与范围

18 份 Lite 源码使用 API 14 重新编译并通过 D8；53 项既有检查、3 项 TLS 能力检查和实际 HLS 代理隔离检查通过。

本次发布基于源码、自动化与安装包检查；没有把这些结果当作 iPhone、电视或其他设备的实机播放验收。真实片源、硬件解码和设备体验仍取决于实际设备与服务。
Android 4.0 的标准 TLS 实现仍不支持 TLS 1.2；此更新没有提供 API 14 的新 TLS 引擎。

构建提交：`d26b46302ac038f1749c8cb53916f739f33addba`。

[构建与检查记录](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42755615534)。安装包、校验文件和对应源码一并附在此版本；Android 包使用既有签名，校验结果见随包 build-report.json。
