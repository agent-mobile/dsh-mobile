# 语音对话 · 实时转写 · 远程组网 完整指南

> 本指南在三个仓库**同步维护、内容一致**，在哪一个仓库看到都可以：
> [dsh-mobile](https://github.com/elskly-cmyk/dsh-mobile) ·
> [dsh-mobile-gateway](https://github.com/elskly-cmyk/dsh-mobile-gateway) ·
> [dsh-speech](https://github.com/elskly-cmyk/dsh-speech)

整体关系一句话：**手机 App（dsh-mobile）** 通过 **网关插件（dsh-mobile-gateway）** 连上电脑里的 dsh；语音能力（听写、播报、实时转写）由 **语音插件（dsh-speech）** 提供。文字模式、语音对话、实时转写是 App 里的三种交互形态，服务端配好一次，三种形态共用。

---

## 1. 前置条件（服务端一次配好）

```sh
npm install -g @deepseek-ai/dsh
dsh plugin --profile web add github:elskly-cmyk/dsh-mobile-gateway   # 局域网/远程访问（必需）
dsh plugin --profile web add github:elskly-cmyk/dsh-speech           # 语音能力（语音功能需要）
```

在 `~/.dsh/profiles/web/cordis.patch.yml` 里给**两个插件配同一个 token**：

```yaml
- id: mobile-gateway
  config:
    token: 换成一个长随机串
- id: speech
  config:
    token: 同上
```

然后 `dsh web` 启动。首次启动 Windows 会弹防火墙授权，勾选**专用网络**放行。

想用语音功能，还需要给 dsh-speech 配置**语音链路**（识别/合成/实时转录的提供商），见 [第 4 节](#4-dsh-speech配置语音链路)。不配语音也能用文字聊天。

---

## 2. App：从文字模式切换到语音模式

- 开关位置：App 首页标题栏的**左上角按钮**——
  - 图标为 💬 时表示当前是**文字模式**，点它切换到语音；
  - 图标为 🎤 时表示当前是**语音模式**，点它切回文字。
- 这是**全局开关**：切换后所有会话的输入栏都会变成对应形态，偏好会持久化（重启 App 保留）。

**语音模式（吉祥物界面）怎么用：**

1. 切到语音模式后进入任意会话，界面出现鲸鱼吉祥物，底部是声波条，显示「**正在聆听…（点击结束）**」
2. 直接说话——说完停顿，App 自动断句提交（底部变为「识别中…」→「等待回复…」）
3. AI 的回复**逐字出现在对话里，同时用语音播报**（底部显示「正在播报…」）；读完自动回到聆听状态，可以继续追问
4. 想中途打断：点击底部声波条即可结束当前听写/播报

> 语音模式 = 实时识别（你说的话）+ 流式回复（文字）+ 语音合成（读给你听）。说话前请授予麦克风权限（首次使用系统会弹窗）。

---

## 3. App：启用实时文字转录

- 入口：进入任意会话，点**右上角的 🎤 图标**（提示文字「实时转录」），打开全屏「实时转录」页。
- 适合场景：会议/访谈/长段落口述——持续聆听、**逐句出稿**，不用一句一句说。
- 页面顶部显示状态（聆听中 · 计时 · 逐字 · 提供商），右上角可**暂停 / 停止**。
- 结束后有两个按钮：
  - **保存到本地**：转录稿存到手机；
  - **发送到对话**：把整段稿子发给 AI 继续处理（润色、总结、提问都行）。
- 文字模式下「发送到对话」会先把稿子放进输入框供你编辑再发；语音模式下直接发出。

> 想要**说话人分离**（谁说的哪句，界面里显示「说话人 1」等标签），需要语音提供商支持，见下一节。

---

## 4. dsh-speech：配置语音链路

语音链路分三个能力位，在 `~/.dsh/profiles/web/cordis.patch.yml` 的 `speech` 插件行配置（也可在 Web GUI「设置 → 语音服务」页直接改）：

| 能力位 | 配置项 | 语音功能里的用途 |
| --- | --- | --- |
| 批量识别 | `transcriptionProvider` | 一次性上传音频转文字（语音模式不依赖它） |
| 语音合成 | `synthesisProvider` | 把 AI 回复读给你听（语音模式的「播报」） |
| 实时转录 | `sessionTranscriptionProvider` | 语音模式的听写 + 实时转写页（App 主用） |

三个都**留空 = 恰好一个可用时自动选中**；配多个提供商时建议显式指定。

**最小可用配置（阿里云百炼一家通吃，识别 + 合成 + 实时）**：

```yaml
- id: speech
  config:
    token: 与 gateway 相同的 token
    providers:
      dashscope:
        type: dashscope
        apiKeyEnv: DASHSCOPE_API_KEY
        asrModel: qwen-audio-3.0-asr-flash      # 识别
        ttsModel: qwen3-tts-flash               # 合成
        ttsVoice: Cherry                         # 合成音色（必填）
```

密钥值写在 `~/.dsh/.env`：`DASHSCOPE_API_KEY=sk-xxxx`（重启 dsh web 生效）；也可以在「语音服务」页面直接填（内联保存，界面只回显掩码）。

**其他链路**（详见 [dsh-speech README](https://github.com/elskly-cmyk/dsh-speech)）：

- `openai-compatible`：OpenAI / Groq / 硅基流动等任何兼容端点；
- `local-relay`：自建 SenseVoice + CosyVoice2，支持**声纹说话人分离**（`diarization: true`）；
- `streaming-ws`：Deepgram / FunASR / 讯飞（iat 单人听写、rtasr 多人转写带角色分离、tts 在线合成）。

**说话人分离支持情况**：`local-relay`（声纹聚类）、Deepgram（diarize）、讯飞 rtasr（roleType=2）支持；百炼实时转录**没有**说话人字段。

**配好怎么验证**：电脑浏览器打开 `http://127.0.0.1:3080/s/`（本机免 token）→「语音服务」页能看到当前使用三个能力位的提供商，点「实测 6 秒」可整链路试录试播。

---

## 5. 网络打通：从局域网到远程

App 连接的是 `http://<电脑IP>:3080` + token。电脑在哪张网上，决定你用哪个方案：

### 方案 A：同一局域网（最简单，推荐先用它验证全链路）

1. 电脑和手机连**同一个 Wi-Fi / 路由器**；
2. 查电脑局域网 IP：Windows `ipconfig` 看「IPv4 地址」（如 `192.168.1.5`）；启动 `dsh web` 时日志也会直接打印 `(LAN: http://<IP>:3080)`；
3. 手机 App 填 `http://<电脑IP>:3080` + token（或在电脑浏览器打开 `http://127.0.0.1:3080/m/` 扫码配对）；
4. 连不上时依次检查：Windows 防火墙是否放行 Node.js → 路由器是否开了「AP 隔离」（会挡设备互访）→ IP 是否填错。

### 方案 B：贝锐蒲公英组网（不在同一网络 / 异地，门槛最低）

原理：蒲公英给电脑和手机各发一张虚拟网卡，组成一个虚拟局域网，流量在之间透传。

1. 电脑安装[蒲公英客户端](https://pgy.oray.com/)并登录，加入你的网络；手机安装「蒲公英管理」App 登录**同一账号网络**；
2. 记下电脑的蒲公英虚拟 IP（客户端可见，一般是 `172.x.x.x`）；
3. 手机 App 里服务器地址填 `http://<电脑的蒲公英虚拟IP>:3080`，token 不变。

> 蒲公英是 IP 层组网，HTTP 和 WebSocket（会话事件流、语音通道）**天然可用，无需任何额外配置**。注意免费版有成员数与带宽限制；连接质量取决于蒲公英中转线路。

### 方案 C：WireGuard 自组网（有 VPS / 公网宽带的进阶玩法）

拓扑：VPS（或有公网 IP 的路由器）做 WireGuard 服务端，电脑与手机各为一个 peer。

1. 服务端生成接口与两个 peer（电脑、手机），手机装官方 WireGuard App 导入隧道配置；
2. 手机侧要点：`Endpoint` 指向服务端公网地址，`PersistentKeepalive = 25`（保活，方便随时连回），`AllowedIPs` 按需（只走家里网段可写 `192.168.1.0/24, 10.0.0.0/24` 这类，全局代理就 `0.0.0.0/0`）；
3. App 连 `http://<电脑在组网里的地址>:3080`（电脑 peer 的 WG 地址或其局域网 IP，取决于 AllowedIPs 写法）。

> WireGuard 同样是 IP 层透传，WebSocket 无需额外配置。**常见坑**：握手成功、能 ping 通但 HTTP 频繁超时——多半是 MTU，把两端 `MTU = 1380`（仍超时再试 1280）即可。

### 方案 D：其他

- **Tailscale**：思路同蒲公英（虚拟局域网），国际网络环境更顺手，装上登录两端即可；
- **frp / Cloudflare Tunnel** 等端口映射类方案也可用，但必须确保通道**支持 WebSocket**（Cloudflare 需在配置里开启 WS），且务必保持 token 门控。

### 安全须知（组网前必读）

- **token 是唯一门禁**：持有 token 就等于拿到白名单内的全部 agent 能力（含在你电脑上执行命令）。用 `openssl rand -hex 32` 生成，组网暴露面变大后更要保证它足够长、定期轮换（管理页一键轮换，旧 token 立即失效）；
- 不要为了连 App 给 dsh 加 `--trusted-host`——那会绕过网关的白名单体系；
- 管理 `/m/`、语音 `/s/` 页面在**本机浏览器**免 token 属正常设计（方便自己操作），远程一律要 token。

---

## 6. 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 点麦克风/进语音模式提示无可用语音服务 | dsh-speech 未配语音链路或密钥无效 → 看第 4 节，到 `/s/` 页确认「当前使用」三项 |
| 语音模式能识别但 AI 不出声 | `synthesisProvider` 未配好（合成模型/音色），到「语音服务」页检查语音合成一项 |
| 实时转写没有说话人标签 | 当前实时提供商不支持说话人分离 → 换 local-relay / Deepgram / 讯飞 rtasr |
| 局域网连不上服务器 | 防火墙未放行、路由器开了 AP 隔离、IP 填错（看 `dsh web` 启动行打印的 LAN 地址） |
| 蒲公英/WireGuard 能连但频繁超时 | 虚拟链路 MTU 问题，WireGuard 两端调 `MTU = 1380`；蒲公英换优质线路或自建 |
| 手机上一切正常但换网络就不行 | 只在方案 A 里换了 Wi-Fi 而已 → 跨网请用方案 B/C |
| 想换端口 | `dsh web --port 3081`，App 服务器地址跟着改 |
