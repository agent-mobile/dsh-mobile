# dsh_mobile_app

[dsh-mobile 仓库总览](../README.md) | Flutter 手机 App

DeepSeek Harness（dsh）web 主机的移动客户端。通过
[dsh-mobile-gateway](https://github.com/elskly-cmyk/dsh-mobile-gateway)
插件的 `/m/api` 面连接官方 dsh，无需任何 fork 或源码修改。

## 功能

- **会话聊天**：流式回复、Markdown 渲染、回合状态栏（排队/运行/审批中）
- **审批与提问**：工具调用审批卡片、agent 提问应答（question sheet）
- **工具可视化**：工具调用卡片、todo 面板、goal 停靠、任务队列、workspace 浏览、上下文水位表
- **语音模式**：按住说话实时转写（配合 dsh-speech 的 `/s/ws`）、TTS 合成播报（流式播放）
- **扫码配对**：扫描电脑管理页 `http://<电脑IP>:3080/m/` 的二维码，自动填入服务器与 token
- **安全存储**：token 存于系统安全存储（flutter_secure_storage），可按设备在管理页屏蔽

## 系统要求

- Android 8.0+（Release APK 直接安装）
- 与运行 `dsh web` 的电脑在同一局域网
- 服务端：dsh + dsh-mobile-gateway 插件（必需）、dsh-speech 插件（语音功能）

安装与连接步骤见[仓库总览](../README.md#快速上手)。

## 开发

```sh
flutter pub get
flutter run                 # 真机/模拟器运行（连接配置在首屏填写）
flutter test                # 单元与组件测试
flutter analyze
flutter build apk --release # 标准发布构建
```

- 依赖本仓库的 [`../dsh_dart_sdk`](../dsh_dart_sdk)（path 依赖），克隆整个仓库后无需额外配置
- `record` 插件家族被 `dependency_overrides` 钉在 5.x 兼容矩阵（见 `pubspec.yaml` 注释，Linux 5.x 损坏）
- 品牌素材在 `assets/mascots/`

### 维护者备注（外部贡献者可忽略）

`../build_apk.ps1` 是维护者本机构建脚本（网络受限环境，硬编码本地 Gradle 9.5.1 与
Android Studio JBR 路径，并把版本号写入 `android/local.properties` 后直呼
`gradle assembleRelease`）。常规环境下直接用上面的 `flutter build apk --release`。
Release 签名走 `android/key.properties`（不入库），无该文件时自动回退 debug 签名。

## 许可证

[MIT](../LICENSE)
