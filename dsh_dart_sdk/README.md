# dsh_dart_sdk

[dsh-mobile 仓库总览](../README.md) | 纯 Dart SDK

DeepSeek Harness（dsh）宿主 `/api` 线协议的 Dart 客户端。**不 import 任何 TS
源码**——按宿主 `dsh-client-connection` / `dsh-host-apiproxy` 的公开契约手工镜像，
配套测试逐条对齐。默认面向
[dsh-mobile-gateway](https://github.com/agent-mobile/dsh-mobile-gateway)
插件的 `/m/api` 面，也可切回官方 `/api`。

## 引入

```yaml
dependencies:
  dsh_dart_sdk:
    git:
      url: https://github.com/agent-mobile/dsh-mobile.git
      path: dsh_dart_sdk
```

## 5 分钟上手

```dart
import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

final client = DshApiClient(
  baseUrl: Uri.parse('http://192.168.1.5:3080'),
  token: 'your-token',           // 与 mobile-gateway 配置的 token 一致
  deviceName: 'my-tool',         // 可选：管理页设备列表显示名
);
// apiPrefix 默认 '/m/api'（走 mobile-gateway）；传 '/api' 可连官方围栏面

// 1. 一元 RPC：HTTP POST + {args:...} 信封，返回 RpcResultOk / RpcResultErr
final sessions = DshSessionApi(client);
final list = await sessions.list();

// 2. 创建会话并发消息（审批/提问经 client.respond 应答）
final sessionId = await sessions.create();
await sessions.prompt(sessionId, '你好');

// 3. 事件下行：0.1.2 是单一 remote.mux WebSocket
final events = await client.openEvents();
events.frames.listen((frame) { /* ready / emit / waterfall / cancel … */ });

// 4. 语音（需要服务端 dsh-speech 插件）
final speech = DshSpeechClient(baseUrl: client.baseUrl, token: client.token);
final wav = await speech.synthesize('你好，世界');            // 批量 TTS
final session = await speech.openSession(sampleRateHz: 16000); // /s/ws 实时转录
session.events.listen((e) { /* partial / transcript … */ });
session.sendAudio(pcm16Bytes);

client.dispose();
```

## API 面

| 入口 | 覆盖域 |
| --- | --- |
| `DshApiClient` | 传输层：一元 RPC、`/api/respond` 客户端应答、`remote.mux` 事件下行、超时与设备标识头 |
| `DshSessionApi` + `SessionSurface` | 会话域：创建/列表/历史/prompt/跟随流，折叠转写面 |
| `DshSpeechClient` | dsh-speech 面转写/合成/流式合成/`/s/ws` 实时会话 |
| interaction / settings / domain / workspace / commands API | 审批与提问应答、settings 读写、模型目录、workspace 浏览、斜杠命令 |

`tool/` 下有一组可直连真实服务器的探针脚本（`dart run tool/smoke.dart
<url> <token>` 等），排查连接问题时可用。

## 协议对齐

SDK 版本对应宿主 dsh **0.1.2** 协议（两段式斜杠端点、单一 `remote.mux`
WebSocket、`{args:...}` 载荷信封）。0.1.1 → 0.1.2 的协议映射详见
[`../SDK-0.1.2-MIGRATION.md`](../SDK-0.1.2-MIGRATION.md)。

宿主升级若涉及 `packages/client/connection` 或 `packages/host/apiproxy` 的
线协议变化，需同步更新本 SDK 与 `test/` 下的对齐测试（7 个测试文件，
`dart test` 运行）。

## 许可证

[MIT](../LICENSE)
