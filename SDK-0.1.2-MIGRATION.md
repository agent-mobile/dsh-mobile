# Dart SDK 0.1.1 → 0.1.2 协议迁移基线

0.1.2 把 `/api` unary 协议从 0.1.1 的点分命名空间改成 Typert 反射驱动的两段 endpoint。本表是 Dart 侧重写的权威依据，逐方法对照 host 源码（`packages/api/session-controller/src/types.ts` 等）核验过。

> **2026-09-04 实测修正（对活宿主逐端点验证，优先级高于下文初版表格）**：
> Typert 严格描述符要求 wire args 的键 = 实现方法的**参数名**，缺字段/多字段都会被
> `gateway/arguments-invalid` 拒绝。与初版表格不同处：
> - `session/list` → args `{_request: {}}`（保留参数名 `_request`，裸 `{}` 会被拒）。
> - 除 `list`/`modelCatalog` 外的 session 方法一律 `{request: {...}}` 包裹
>   （create/prompt/page/rename/fork/cancel/attachment/updateQueue/selectModel/search）。
> - `session/page` 的 `throughSeq` 是窗口**含上界**，取自 follow 开场帧的 `cursor`；
>   `-1` 合法但表示空窗。首屏历史来自 follow snapshot（含 records/hasMore/projections）。
> - `session/follow` 开流 payload → `{args: {request: {address, maxMessages?}}}`；
>   **没有 `throughSeq`**。开场帧 `{type:'snapshot', cursor, records, hasMore, projections}`。
> - `goals/*` → `{agentId, request}` / `{agentId, ref}` / `{agentId, ref, request}`；
>   `agentId` 即会话 id（agent 依会话解析）。返回值为 `{ref: {id, revision}}`。
> - `commands/list|execute` → 参数名 `agentId`（同样是会话 id），不是 `agent`。
> - `skills/list` → `{request: {sessionId}}`；`subagents/prompt` → `{request: {...}}`；
>   `subagents/list`、`subagents/interruptByParent` 保持扁平字段。
> - `workspace/*` 变更类（create/rename/delete/archiveSession）→ `{request: {...}}`；
>   列表无 unary，走 `workspace/follow` 流，首帧 `{type:'baseline', value:{items, archivedSessionIds}}`。
> - `llm/listProviders` 返回**裸数组**（无 wrapper）。
> - `$events/result` 回报体也是标准 client-request 信封：
>   `{type:'client-request', rpcId, method:'$events/result', payload:{args:{clientId, eventId, outcome}}}`。

## 通用 wire 变化（transport + wire）

| 维度 | 0.1.1 | 0.1.2 |
|---|---|---|
| URL | `POST /m/api/<ns>.<method>`（点分） | `POST /m/api/<ns>/<method>`（斜杠两段） |
| body `method` 字段 | `session.list`（点分，必须等于 URL 段） | `session/list`（斜杠，必须等于 URL 段） |
| body `payload` | `{...named-args}` | `{args: {...named-args}}`（恰好一个 `args` 字段） |
| 成功响应 | `{type, rpcId, result:{ok:true, value}}` | 不变 |
| 失败响应 | `{type, rpcId, result:{ok:false, error}}` | 不变 |
| respond | `POST /m/api/respond` | `POST /m/api/$events/result`（endpoint `$events/result`） |
| 事件流 | `ws /m/api/events.mux` + `/m/api/events.host`（两条 WS） | 单条 `ws /m/api/remote.mux`，事件下行走逻辑流 `$events`（payload `{args:{}}`），结果回报走 `$events/result` |

**respond 与事件流细节**见 transport 重写说明。0.1.2 的 host 侧 `REMOTE_STREAM_MUX_PATH = '/api/remote.mux'`，`REMOTE_EVENT_STREAM_ENDPOINT = '$events'`，`REMOTE_EVENT_RESULT_ENDPOINT = '$events/result'`。

## 方法映射（0.1.1 点分 → 0.1.2 endpoint）

### session 命名空间（不变，`namespace: 'session'`）

| 0.1.1 | 0.1.2 endpoint | args（named） | 响应 value 形状 |
|---|---|---|---|
| `session.list` | `session/list` | `{}`（可带 `cursor?`） | `{items: SessionSummary[]}` |
| `session.search` | `session/search` | `{query}` | `{items: SessionSearchItem[], hasMore}` |
| `session.create` | `session/create` | `{workspaceId?, cwd?, sessionId?, agentPreset?}` | `{sessionId, agentPreset?}` |
| `session.selectModel` | `session/selectModel` | `{sessionId, provider, model, reasoningEffort?}` | `{selected: ModelSelection}` |
| `session.models` | `session/modelCatalog` | `{}` | `ModelCatalog`（见下） |
| `session.rename` | `session/rename` | `{sessionId, title}` | `{title, seq}` |
| `session.fork` | `session/fork` | `{sessionId, atSeq?}` | `{sessionId}` |
| `session.prompt` | `session/prompt` | `{requestId, sessionId, mode, content, clientTimeZone?}` | `{accepted: true}` |
| `session.attachment` | `session/attachment` | `{sessionId, attachmentId}` | `{attachment: ImageAttachmentRef, data: string(b64)}` |
| `session.updateQueue` | `session/updateQueue` | `{sessionId, itemId, action}` | `{accepted: true}` |
| `session.cancel` | `session/cancel` | `{sessionId}` | `{accepted: true}` |
| `session.history` | `session/page` | `{address: SessionAddress, throughSeq, beforeSeq?, maxMessages?}` | `SessionPage`（见下） |

### 重命名/消失的方法

| 0.1.1 | 0.1.2 | 备注 |
|---|---|---|
| `host.describe` | **无对应** | 0.1.2 删了 `host` 命名空间。App 连接探测改用 `session/list`（成功即连通）。 |
| `host.listDirectory` | `directoryPicker/list` | 命名空间 `directoryPicker`，args `{path?}` |
| `host.createDirectory` | `directoryPicker/createDirectory` | args `{path, name}` |
| `subagent.list` | `subagents/list` | 命名空间 `subagents`，args `{parentSessionId}` |
| `subagent.prompt` | `subagents/prompt` | args `{requestId, parentSessionId, childSessionId, mode, content, clientTimeZone?}` |
| `subagent.interrupt` | `subagents/interruptByParent` | args `{childSessionId, parentSessionId, mode}` |
| `goal.*` | `goals/*` | 命名空间 `goals`，每个方法额外带 `agent` 身份字段；见下 |
| `skill.list` | `skills/list` | 命名空间 `skills`，args `{sessionId}` |
| `llm.models` | `llm/discoverModels` | args `{settingsNs, request}`（`llm.models` 不存在） |
| `llm.providers` | `llm/listProviders` | args `{}` |
| `workspace.list` | **无 unary** → `workspace/follow`（stream） | 流式基线，args `{}` |
| `session.export` | **非 unary** → `GET /api/session.export` | query `sessionId?`, `includeDescendants?`；静态 fetch 路由 |
| `settings.*` | `settings/*` | 不变名：`describe`/`update`/`replace`/`mutate` |
| `credentials.*` | `credentials/*` | 不变名：`describe`/`set`/`unset` |
| `commands/list` | `commands/list` | args `{agent}` |
| `commands/execute` | `commands/execute` | args `{agent, line, images}` |

### goal 命名空间（`goals`，每个方法带 `agent` 身份字段）

| 0.1.1 | 0.1.2 endpoint | args（named，含 `agent`） |
|---|---|---|
| `goal.create` | `goals/create` | `{agent, objective, maxGoalRounds?}` |
| `goal.edit` | `goals/edit` | `{agent, id, revision, objective?, maxGoalRounds?}` |
| `goal.complete` | `goals/complete` | `{agent, id, revision}` |
| `goal.clear` | `goals/clear` | `{agent, id, revision}` |
| `goal.pause` | `goals/pause` | `{agent, id, revision}` |
| `goal.resume` | `goals/resume` | `{agent, id, revision}` |

> `agent` 是 gateway Context 注入的身份字段；0.1.2 的 goal 方法签名把它列为命名参数。Dart 侧需传当前 agent 标识（通常就是发起会话的 agent 名，连接时已持有）。

## 关键响应形状

### SessionSummary（`session/list` 的 item）
`{sessionId, updatedAt, running, blank, parentSessionId?, origin?('subagent'), cwd?, projections?{asOfSeq, values{...}}}`
- 显示标题在 `projections.values.title`（0.1.1 的 `projections.values.title` 路径不变）。

### SessionPage（`session/page` 响应）
```
{
  records: SessionHistoryRecord[],   // 注意：字段名是 records（0.1.1 是 events/entries）
  hasMore: bool
}
SessionHistoryRecord =
  | {type:'event', event: SessionWireEvent}
  | {type:'chunks', event: ChunkRowEvent}
SessionWireEvent = {type: string, seq: int, time: int(ms), data: any, ignorable?, sourceEventSeqs?, surfaceOp?}
ChunkRowEvent = {type:'chunkrow/text-chunks'|'chunkrow/reasoning-chunks'|'chunkrow/tool-call-chunks', seq, time, data{turn,step,index,dt[],texts[]/args[]}}
```
- 0.1.1 的 `headSeq`/`tailSeq`/`includeViews`/`includeChunks` 在 0.1.2 **不存在**；`throughSeq` 取代 `beforeSeq` 作为必填游标（来自 follow 开场帧）。
- App 侧若只读 `type:'event'` 记录即可折叠历史；`type:'chunks'` 是打包的流式增量行（0.1.1 的 `assistant/chunk` 等价物），Dart 折叠器要新增对 chunk-row 的处理或跳过。

### ModelCatalog（`session/modelCatalog` 响应）
```
{
  default: ModelSelection {provider, model, reasoningEffort?},
  routableProviders: string[],
  groups: ModelProviderGroup[] {id, name, models: ModelCatalogModel[] {id, name, description?, reasoning?{efforts[], defaultEffort?}}},
  failures: [] {id, name, message}
}
```
- 0.1.1 的 `SessionModels`（`current`/`routable`/`groups`/`failures`）字段名变了：`current`→`default`，`routable`（bool）→`routableProviders`（string[]）。Dart 解码器要改。

### PromptContentPart（`content` 数组元素）
`{type:'text', text}` | `{type:'image', mediaType, data(b64), name?}`

### QueueAction（`updateQueue` 的 `action`）
`{kind:'edit', content: ContentBlock[]}` | `{kind:'remove'}` | `{kind:'steer'}`

### SessionAddress（`page` 的 `address`）
`{kind:'session', sessionId}` | `{kind:'subagent', parentSessionId, childSessionId, mode:'one-shot'|'continuable'}`

## 事件流合并（transport 重写要点）

0.1.2 只有**一条** WS：`/m/api/remote.mux`。
- 连上后先发一个"打开逻辑流"的帧，endpoint 为 `$events`，payload `{args:{}}`，开始接收事件下行帧。
- 事件下行帧（ServerRequest 形态）继续按 `{rpcId, method, payload}` 解析；`method` 是事件类型（如 `session/event`、`approval/requested`）。
- 回报可应答交互：`POST /m/api/$events/result`，body 是 `RemoteEventResult`（含 `clientId` + 结果）。0.1.1 的 `respond` 走 `/m/api/respond`，0.1.2 改走 `$events/result`。
- 0.1.1 的"两条流"（mux=全会话、host=主机级）合并为一条 `$events` 流；Dart 侧 `openMux()`/`openHost()` 都收敛到同一条 `remote.mux` + `$events`，App 的 `connection_controller` 双路订阅改为单路 + 按帧 `method` 路由。

> 实现注意：`$events` 是"通过 mux 的逻辑流"，其 open 帧和 host 的 `RemoteStreamMuxServer` 协商。具体 open 帧格式（endpoint 字段名、是否带 rpcId）要在实现时对照 `packages/api/gateway/src/stream-protocol.ts` 与 `RemoteStreamMuxServer` 的握手帧结构再定，先按 `endpoint:'$events'` 占位。
