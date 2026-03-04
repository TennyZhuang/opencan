# OpenCAN 可观测性系统设计

## Context

OpenCAN 是一个多层架构（iOS → SSH PTY → Go daemon → ACP 子进程），目前日志是非结构化的、分散的、无法跨层关联的。daemon 在 daemonize 后日志直接丢失（stderr 无人读取），iOS 端只能事后通过 `xcrun devicectl` 拉取文件来调试。当 streaming 出现问题时，无法判断瓶颈在哪一层。

本设计的目标：**给每个用户操作一个 traceId，让它贯穿 iOS → daemon → ACP 全链路；将日志结构化为 JSON lines；增加 daemon 日志持久化和远程获取；提供 iOS 端诊断面板。**

---

## Phase 1: Correlation ID (traceId)

**核心思想：** 在 iOS 每个用户操作（发消息/创建 session/恢复 session/连接）入口生成 UUID，通过 `_meta.traceId` 注入 JSON-RPC 请求 params，daemon 提取后加入 slog context。

### 1.1 iOS: ACPClient 统一注入

**修改文件：** `Sources/ACP/ACPClient.swift`

在 `sendRequest()` 增加可选 `traceId` 参数，当存在时将 `_meta.traceId` 注入 params：

```swift
func sendRequest(method: String, params: JSONValue?, traceId: String? = nil) async throws -> JSONValue {
    var finalParams = params
    if let traceId {
        if case .object(var dict) = finalParams {
            dict["_meta"] = .object(["traceId": .string(traceId)])
            finalParams = .object(dict)
        } else if finalParams == nil {
            finalParams = .object(["_meta": .object(["traceId": .string(traceId)])])
        }
    }
    // ... 其余逻辑不变，使用 finalParams 构造 message
}
```

### 1.2 iOS: DaemonClient / ACPService 透传

**修改文件：** `Sources/ACP/DaemonClient.swift`, `Sources/ACP/ACPService.swift`

所有方法增加 `traceId: String? = nil` 参数，透传给 `client.sendRequest()`。默认 nil 保持向后兼容。

### 1.3 iOS: AppState 生成 traceId

**修改文件：** `Sources/AppState.swift`

添加 `currentTraceId` 属性和 `newTraceId()` 方法。在五个用户操作入口调用：
- `connect(node:)` — SSH + daemon 握手
- `createNewSession()` — 创建 session
- `resumeSession()` — 恢复 session (包括 attach, load)
- `sendMessage()` — 发送 prompt

每处将 `traceId` 传入 daemon/service 调用，同时写入 `Log.log()` 以便 iOS 日志也携带。

### 1.4 Daemon: 提取 traceId

**修改文件：** `opencan-daemon/internal/protocol/jsonrpc.go`

新增 `ExtractTraceID(msg)` 函数，从 `params._meta.traceId` 提取，遵循 `ExtractSessionID` 的既有模式。

**修改文件：** `opencan-daemon/internal/daemon/client_handler.go`

在 `handleDaemonMethod()` 和 `handleACPRequest()` 入口提取 traceId，创建带 traceId context 的子 logger 传入后续处理。

**无需修改 `acp_proxy.go` 的 ForwardFromClient**：`msg.Clone()` 已经完整复制 params，`_meta.traceId` 自动保留在转发给 ACP 子进程的请求中。

---

## Phase 2: 结构化日志

### 2.1 iOS: LogEntry + LogRingBuffer

**新建文件：** `Sources/Utils/LogEntry.swift`

```swift
struct LogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String       // "debug" | "info" | "warning" | "error"
    let component: String   // "AppState" | "ACPClient" | "SSH" | ...
    let message: String
    let traceId: String?
    let sessionId: String?
    let extra: [String: String]?
}
```

**新建文件：** `Sources/Utils/LogRingBuffer.swift`

DispatchQueue 同步的环形缓冲区，max 2000 条。提供 `append()`, `allEntries()`, `entriesSince(Date)` 方法。

### 2.2 iOS: 升级 Log.swift

**修改文件：** `Sources/Utils/Log.swift`

- 新增 `static let buffer = LogRingBuffer(maxSize: 2000)`
- 新增 `Log.log(level:component:_:traceId:sessionId:extra:)` 方法，同时写入 buffer 和文件（JSON line 格式）
- 保留 `Log.toFile()` 向后兼容：自动解析 `[Component]` 前缀转为结构化 entry
- iOS 日志文件 `opencan.log` 改为 JSON lines 格式

### 2.3 iOS: 逐步迁移调用点

现有 `Log.toFile("[AppState] ...")` 调用可逐步迁移到 `Log.log(component: "AppState", "...", traceId: ...)` 以携带更多 context。由于向后兼容，不需要一次性全改。**本次先迁移 Phase 1 涉及的 5 个 action 入口点。**

---

## Phase 3: Daemon 日志持久化 + JSON 格式

### 3.1 日志文件输出

**修改文件：** `opencan-daemon/cmd/opencan-daemon/main.go`

- 将 `slog.NewTextHandler(os.Stderr, ...)` 替换为 `slog.NewJSONHandler(writer, ...)`
- 打开 `~/.opencan/daemon.log` 文件用于写入
- foreground 模式：`io.MultiWriter(os.Stderr, logFile)`
- daemonized 模式：仅写 `logFile`（stderr 无人读取）
- daemon 启动时检查文件大小，超过 10MB 则 rename 为 `.prev` 做简单轮转

### 3.2 Daemon Log Ring Buffer

**新建文件：** `opencan-daemon/internal/daemon/log_buffer.go`

```go
type LogBufferEntry struct {
    Timestamp string            `json:"timestamp"`
    Level     string            `json:"level"`
    Message   string            `json:"message"`
    Attrs     map[string]string `json:"attrs,omitempty"`
}
```

Ring buffer，max 2000 条，`Append()` / `Recent(n)` / `Filter(traceId)` 方法。与 EventBuffer 相同的 copy-on-evict 模式。

### 3.3 BufferingHandler（slog.Handler 适配）

**新建文件：** `opencan-daemon/internal/daemon/log_handler.go`

实现 `slog.Handler` 接口的 `BufferingHandler`，将每条日志同时写入 inner JSONHandler 和 LogRingBuffer。正确实现 `WithAttrs()` 和 `WithGroup()` 以保留 component/traceId 等 context。

### 3.4 接入 daemon

**修改文件：** `opencan-daemon/internal/daemon/daemon.go`

Config 新增 `LogBuffer *LogRingBuffer` 字段。Daemon struct 新增 `logBuffer` 字段和 `LogBuffer()` accessor。

---

## Phase 4: `daemon/logs` 远程获取

### 4.1 Protocol 常量

**修改文件：** `opencan-daemon/internal/protocol/router.go`

```go
MethodDaemonLogs = "daemon/logs"
```

### 4.2 Daemon handler

**修改文件：** `opencan-daemon/internal/daemon/client_handler.go`

在 `handleDaemonMethod()` switch 中添加 `case protocol.MethodDaemonLogs:`。

实现 `handleLogs(msg)`：
- 参数：`count` (默认 200), `traceId` (可选过滤)
- 从 `daemon.LogBuffer().Recent(count)` 获取
- 若有 `traceId` 则过滤 `attrs["traceId"]` 匹配的条目
- 返回 `{"entries": [...]}`

### 4.3 iOS DaemonClient

**修改文件：** `Sources/ACP/DaemonClient.swift`

新增 `DaemonLogEntry` 类型和 `fetchLogs(count:traceId:)` 方法。

---

## Phase 5: 关键路径计时

### 5.1 iOS: Log.timed() 辅助

**修改文件：** `Sources/Utils/Log.swift`

```swift
static func timed<T>(_ operation: String, component: String, traceId: String?, sessionId: String?,
                     block: () async throws -> T) async rethrows -> T
```

使用 `ContinuousClock` 测量，完成后写入一条结构化日志含 `durationMs`。

### 5.2 插桩点

**修改文件：** `Sources/AppState.swift`

用 `Log.timed()` 包裹以下调用（仅包裹 RPC 等待，不插桩每条 notification）：
- SSH connect（在 `SSHConnectionManager.connect()` 内部）
- `daemon/hello`
- `daemon/session.create`
- `daemon/session.attach`
- `session/prompt` 往返
- `session/load` 历史加载

**修改文件：** `opencan-daemon/internal/daemon/session_manager.go`

在 `CreateSession()` 中记录 ACP 进程启动 + 初始化的耗时。

### 5.3 不计时的路径

- `handleNotification()` / `handleSessionEvent()`（streaming 热路径）
- `EventBuffer.Append()`
- 每条 `session/update` 的解析

---

## Phase 6: 诊断面板

### 6.1 DiagnosticView

**新建文件：** `Sources/Views/DiagnosticView.swift`

三个 tab（Segmented Picker）：
- **iOS Logs**: 从 `Log.buffer.allEntries()` 读取，支持 pull-to-refresh
- **Daemon Logs**: 调用 `daemon.fetchLogs()` 获取，支持 traceId 过滤
- **State**: 显示 connectionStatus, activeNode, activeWorkspace, currentSessionId, isPrompting, isLoadingHistory, messages.count, daemonSessions 列表

Toolbar 提供 ShareLink 导出所有数据为 JSON。

### 6.2 入口

**修改文件：** `Sources/Views/NodeListView.swift`

将现有齿轮 Button 改为 Menu，包含 "Agent Settings" 和 "Diagnostics" 两项。

---

## 新增文件汇总

| 文件 | 说明 |
|------|------|
| `Sources/Utils/LogEntry.swift` | 结构化日志条目类型 |
| `Sources/Utils/LogRingBuffer.swift` | iOS 内存日志环形缓冲区 |
| `Sources/Views/DiagnosticView.swift` | 诊断面板 SwiftUI 视图 |
| `opencan-daemon/internal/daemon/log_buffer.go` | Daemon 日志环形缓冲区 |
| `opencan-daemon/internal/daemon/log_handler.go` | slog.Handler 适配器 (tee to buffer) |

## 修改文件汇总

| 文件 | 改动 |
|------|------|
| `Sources/Utils/Log.swift` | 新增 buffer, log(), timed(); 保留 toFile() 兼容 |
| `Sources/ACP/ACPClient.swift` | sendRequest() 加 traceId 参数 |
| `Sources/ACP/DaemonClient.swift` | 所有方法加 traceId 透传; 新增 fetchLogs() |
| `Sources/ACP/ACPService.swift` | sendPrompt/loadSession 加 traceId 透传 |
| `Sources/AppState.swift` | 生成 traceId, 传入调用, Log.timed() 包裹关键路径 |
| `Sources/Views/NodeListView.swift` | 齿轮 Button → Menu (加 Diagnostics 入口) |
| `opencan-daemon/cmd/opencan-daemon/main.go` | JSONHandler + 文件输出 + BufferingHandler 接入 |
| `opencan-daemon/internal/daemon/daemon.go` | Config 加 LogBuffer, Daemon 加 accessor |
| `opencan-daemon/internal/daemon/client_handler.go` | traceId 提取 + daemon/logs handler |
| `opencan-daemon/internal/protocol/jsonrpc.go` | ExtractTraceID() |
| `opencan-daemon/internal/protocol/router.go` | MethodDaemonLogs 常量 |
| `opencan-daemon/internal/daemon/session_manager.go` | CreateSession 计时 |
| `project.yml` | 新增 Swift 文件需要 xcodegen generate |

## 实施顺序

1. **Phase 2** (结构化日志) — 基础设施，其他都依赖它
2. **Phase 1** (traceId) — 可与 Phase 2 并行开发
3. **Phase 3** (daemon 日志持久化 + ring buffer) — 依赖 Phase 2 的 JSON handler
4. **Phase 4** (`daemon/logs` 远程获取) — 依赖 Phase 3
5. **Phase 5** (计时) — 依赖 Phase 2 的 log() 方法
6. **Phase 6** (诊断面板) — 依赖 Phase 2 + Phase 4

## 验证方式

1. `cd opencan-daemon && make test` — 确保 daemon 现有测试通过
2. 新增 daemon 测试：LogRingBuffer 容量/并发、BufferingHandler tee、ExtractTraceID 解析、daemon/logs handler 过滤
3. Xcode build — `xcodegen generate && xcodebuild -scheme OpenCAN -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build`
4. 现有 AppStateTests 仍通过（MockACPTransport 需适配 traceId 参数）
5. 手动验证：连接 daemon → 发送消息 → 打开诊断面板 → 确认 iOS 和 daemon 日志中出现相同 traceId
6. 检查 `~/.opencan/daemon.log` 有 JSON lines 输出且 daemon 重启后不丢失
