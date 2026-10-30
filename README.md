# F50 Manager · iOS / iPadOS

原生 SwiftUI + CoreBluetooth 客户端，iOS / iPadOS **17.0+**，中文优先。开发分支：

`feature/ios-688b4729-e714-465e-86ba-3c53fb331ea6`

此目录是独立 Git 仓库：上层 ZTE-F50-OP 目录没有 Git 元数据，且包含刷机包和私有诊断资料。未将上层内容纳入版本控制，未修改 Android、协议或设备端，未配置远程或推送。

## 已实现

- 用户主动扫描、选择 F50；预置证书固定的 **TLS 1.3 + f50mgr/1 ALPN**，经 BLE GATT 传输，无 HTTP / TCP 中转。
- 概览：蜂窝制式、运营商、信号、频段/带宽、流量速率和累计、8 核 CPU、内存、温度、运行时间、接口地址。未知显示 `—`，缓存保留年龄，不虚构零或成功状态。
- 短信：收件/已发送、分页、完整正文、单条发送及逐条删除。保护操作按现有 V12 约定在已固定证书的 TLS 会话中授权，再显示服务端摘要供用户确认。
- 网络：能力控制的制式、LTE/NR 频段设置/清除；Wi-Fi Host / EoIP 切换、守护事务确认保留/回滚；独立重启确认。
- 离线演示、浅深色、iPhone/iPad 布局、动态字体、VoiceOver 标签。
- 明确确认、单次提交、断线不重放；短信/待确认操作在后台清除。系统权限和配对弹窗导致的 inactive 只遮盖隐私，不中断配对。

## 与 Android 的差异和边界

**现有公开广播没有移植成可用的 iOS 首页传输。** Android 从原始扩展广播读取同 UUID 的多个 Service Data AD 分块；CoreBluetooth 不提供同等原始报告/分块视图，不能可靠重组现有协议。iOS 首页明确使用用户主动建立的**加密管理连接**，不是“无连接广播”，不会暗中退回连接模式。

- 前台轮询，后台断开；不提供后台常驻、自动重连、短信推送。
- 首版不开放系统切换、小区锁定、owner enrollment/revoke 或固件刷写。
- 目前只预置 Android 同源的公开设备身份 `W3MJZCCR`。未预置/证书变化会拒绝连接，无 TOFU、忽略证书或自动重固定。
- 访问码沿用服务端 V12 约定，不是强认证秘密；证书固定才是设备身份校验。授权仅在当前连接中有效。
- “短信已提交”不表示送达；“设置已下发、未验证”不表示成功。超时结果可能未知，**不自动重试**。
- Wi-Fi 事务不会自动确认。断开后设备的独立回滚守护仍由设备端负责。
- 旧固件若没有明确声明列表读取不标已读，客户端不读取短信列表，避免静默副作用。
- **构建/模拟器/离线 TLS 测试不等于真机验证。** 实际 F50 + iPhone 配对、MTU、指示流控、读写兼容性仍未联调。开发中未访问或更改真实 F50。

## 打开和运行

已有完整 `F50Manager.xcodeproj`、共享 scheme 和固定版本 `Package.resolved`；无需先安装 XcodeGen。

1. 用完整 Xcode（验证环境为 26.3）打开 `F50Manager.xcodeproj`，等待 Swift Package 依赖解析。
2. 模拟器可以体验演示；蓝牙实测必须使用真机。
3. 真机运行需在 **Signing & Capabilities** 选择你自己的 Development Team，必要时修改 bundle identifier。仓库没有开发证书、私钥、Team 或 provisioning profile。
4. 启动后先点击“查找并连接设备”。首次授权系统蓝牙权限，并处理系统配对提示；其他客户端需要先释放设备的唯一管理连接。

命令行构建：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/build.sh build     # iOS Simulator，无签名
./scripts/build.sh test      # 默认 iPhone 17 Pro 模拟器
DESTINATION='platform=iOS Simulator,name=iPad Pro 11-inch (M5)' ./scripts/build.sh test
./scripts/build.sh device    # iOS arm64，无签名；不代表可直接安装
```

本次同时提供 `artifacts/F50Manager-0.1.0-unsigned.ipa`（约 8.8 MiB，arm64）。**它没有签名，不能直接作为已签名应用安装**；真机运行仍需你自己的签名。产物不纳入 Git。

脚本在已有 XcodeGen 时重新生成工程，否则使用仓库工程；输出到 `build/`，测试结果在 DerivedData/Logs/Test。iOS 是用户编译位置规则的 macOS-only 例外，未启动 MS-A2。更改工程结构时同步更新 `project.yml` 并重新生成工程。

## 结构与验证

- `F50Core/Transport/`：帧、证书、memory TLS、BLE 状态机、单请求 RPC。
- `F50Core/`：数据映射、短信/动作验证、显式演示、可注入会话边界。
- `F50App/AppModel.swift`：前台生命周期、能力、授权、轮询和两阶段动作。
- `F50App/Views/`：原生三页 UI，`Legal/` 包含依赖许可。
- `Tests/`：协议向量、分帧/上限、TLS 正反例、输入、授权/隐私和不重放测试。
- `UITests/`：演示三页、禁用写操作、大字体、提示条与导航不重叠。
- [验证记录](docs/VALIDATION.md)，[架构与协议边界](IMPLEMENTATION.md)。
- 演示截图：[iPhone 首页](docs/screenshots/iphone-demo-dashboard.png)、[iPad 首页](docs/screenshots/ipad-demo-dashboard.png)、[短信](docs/screenshots/iphone-demo-messages.png)。

依赖固定为 SwiftNIO 2.81.0、NIOSSL 2.29.0；后者包含标准 BoringSSL TLS 实现。传递依赖修订见 Package.resolved。没有实现自制加密。许可可在“设备 → 开源许可”查看。

协议来源：本项目相邻的 [SPEC.md](../protocol/SPEC.md)；广播限制参考 [BROADCAST-V1.md](../protocol/BROADCAST-V1.md)、[V2](../protocol/BROADCAST-V2.md)、[V3](../protocol/BROADCAST-V3.md)。Tests/Fixtures 中的协议向量为明确标注的公开合成值，TLS 测试密钥也仅为测试 fixture，不是实际设备凭据。
