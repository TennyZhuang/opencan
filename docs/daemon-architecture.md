# OpenCAN Daemon Architecture

## 问题

当前架构中，`claude-agent-acp` 作为 SSH PTY 的子进程运行。SSH 断开 → PTY 关闭 → ACP 进程收到 SIGHUP 退出 → 正在执行的 tool call 中断，工作丢失。

核心问题：
1. **ACP 进程生命周期绑定 SSH 连接** — 网络波动直接杀死正在执行的任务
2. **同一 node 多 workspace 需要重复建立 SSH** — 每次切换都要完整的握手 + 认证
3. **用户必须保持 app 活跃** — 否则后台 SSH 被系统杀死，任务中断

## 设计目标

- ACP 进程的生命周期与 SSH 连接解耦
- 客户端断线后，正在执行的 prompt 继续运行至完成
- 客户端重连后，自动回放断线期间的事件
- 同一 node 的多个 workspace/session 复用一个 daemon
- Daemon 可独立于 iOS 客户端测试和开发

## 参考: VS Code Remote SSH 模型

```
VS Code (本地)                              远端服务器
    │                                          │
    ├── SSH 连接 ──────────────────────────►  vscode-server (常驻 daemon)
    │   ├── Channel: JSON-RPC 通信                ├── Extension Host
    │   ├── Channel: Terminal 1                   ├── File System
    │   └── Channel: Port Forward                 └── Debug Adapter
    │
    └── 断线后 vscode-server 继续运行
        重连后自动 reattach
```

OpenCAN Daemon 采用相同模式：daemon 是常驻进程，管理 ACP server 子进程的生命周期。

## 整体架构

```
iOS 客户端                          远端服务器
    │                                  │
    ├── SSH 连接 ─────────────────►  opencan-daemon (常驻进程)
    │   │                              │
    │   └── exec channel:              ├── ACPProxy: session-A → claude-agent-acp (独立进程)
    │       "opencan-daemon attach"    ├── ACPProxy: session-B → claude-agent-acp (独立进程)
    │       stdin/stdout ↔ JSON-RPC    └── ACPProxy: session-C → claude-agent-acp (独立进程)
    │
    └── SSH 断开时:
        daemon 继续运行
        ACP 进程跑完当前 prompt
        事件缓存在 event buffer 中
        iOS 重连后回放
```

## 层级设计

### Layer 0: Daemon 进程管理

```
opencan-daemon (单进程, Go binary)
    │
    ├── Unix Socket Listener (~/.opencan/daemon.sock)
    │
    ├── SessionManager
    │     ├── session_id_1 → ACPProxy { process, state, event_buffer, client }
    │     ├── session_id_2 → ACPProxy { ... }
    │     └── session_id_3 → ACPProxy { ... }
    │
    └── ClientHandler (per attach connection)
          └── 桥接客户端 stdio ↔ daemon socket
          └── 路由 JSON-RPC 到对应的 ACPProxy
```

### Layer 1: Daemon CLI (入口)

`opencan-daemon` 是一个 Go binary，提供以下子命令：

```bash
# 启动 daemon (如果没运行)，后台化
opencan-daemon start

# 连接到 daemon，桥接 stdin/stdout ↔ Unix socket
# 如果 daemon 没运行，自动启动
opencan-daemon attach

# 查看 daemon 状态
opencan-daemon status

# 停止 daemon 和所有 ACP 进程
opencan-daemon stop
```

**`attach` 是 iOS 端唯一需要调用的命令。** 它的作用：
1. 检查 daemon 是否在运行（读 `~/.opencan/daemon.pid`，连接 `~/.opencan/daemon.sock`）
2. 如果没运行，fork 一个后台 daemon 进程
3. 连接到 daemon 的 Unix socket
4. 将 stdin/stdout 桥接到 socket（双向透传 JSON-RPC）
5. 自身退出时，daemon 不受影响

```
iOS SSH exec "opencan-daemon attach"
    │
    attach 进程 (前台, 生命周期 = SSH channel)
    │   stdin ←→ Unix socket ←→ daemon
    │   stdout                    │
    │                             ├── session-A
    │                             └── session-B
    │
    SSH 断了 → attach 进程退出 → daemon 继续运行
```

### Layer 2: Daemon 协议

Daemon 在 ACP 之上增加一层管理协议。原则：**ACP 消息透传，管理消息用 `daemon/` 前缀**。

所有消息走 JSON-RPC 2.0，共享同一个 stdio 通道。

#### 管理方法 (Daemon 自己处理)

```jsonc
// 初始化 daemon 连接，获取 daemon 信息
→ { "jsonrpc": "2.0", "id": 1, "method": "daemon/hello", "params": { "clientVersion": "0.1.0" } }
← { "jsonrpc": "2.0", "id": 1, "result": { "daemonVersion": "0.1.0", "sessions": [...] } }

// 创建新 session (daemon 内部: spawn claude-agent-acp, initialize ACP, session/new)
→ { "jsonrpc": "2.0", "id": 2, "method": "daemon/session.create",
    "params": { "cwd": "/home/user/project", "command": "claude-agent-acp" } }
← { "jsonrpc": "2.0", "id": 2, "result": { "sessionId": "sess-abc123" } }

// Attach 到已有 session，返回断线期间缓存的事件
→ { "jsonrpc": "2.0", "id": 3, "method": "daemon/session.attach",
    "params": { "sessionId": "sess-abc123", "lastEventSeq": 0 } }
← { "jsonrpc": "2.0", "id": 3, "result": {
      "state": "idle",
      "bufferedEvents": [ { "seq": 1, "event": {...} }, ... ]
   }}

// Detach (不杀 session，只断开事件转发)
→ { "jsonrpc": "2.0", "id": 4, "method": "daemon/session.detach",
    "params": { "sessionId": "sess-abc123" } }
← { "jsonrpc": "2.0", "id": 4, "result": {} }

// 列出所有 session
→ { "jsonrpc": "2.0", "id": 5, "method": "daemon/session.list" }
← { "jsonrpc": "2.0", "id": 5, "result": { "sessions": [
      { "sessionId": "sess-abc123", "cwd": "/home/user/project",
        "state": "idle", "lastEventSeq": 42 },
      { "sessionId": "sess-def456", "cwd": "/home/user/other",
        "state": "prompting", "lastEventSeq": 100 }
   ]}}

// 终止 session
→ { "jsonrpc": "2.0", "id": 6, "method": "daemon/session.kill",
    "params": { "sessionId": "sess-abc123" } }
← { "jsonrpc": "2.0", "id": 6, "result": {} }
```

#### ACP 透传 (Daemon 转发到 ACP 子进程)

所有非 `daemon/` 前缀的方法，daemon 根据 `params.sessionId` 路由到对应的 ACP 进程：

```jsonc
// 客户端发 prompt — daemon 找到 sess-abc123 对应的 ACP 进程，转发
→ { "jsonrpc": "2.0", "id": 1001, "method": "session/prompt",
    "params": { "sessionId": "sess-abc123", "prompt": [...] } }

// ACP 进程的 session/update 通知 — daemon 转发给 attached 的客户端
← { "jsonrpc": "2.0", "method": "session/update",
    "params": { "sessionId": "sess-abc123", "update": {...} } }

// ACP 进程的 response — daemon 转发回客户端
← { "jsonrpc": "2.0", "id": 1001, "result": { "stopReason": "end_turn" } }
```

**Daemon 默认不做 ACP 业务语义，只做路由。** 当前有两个必要例外：
1. `session/request_permission`：客户端不在线时 auto-approve（并写入缓冲用于回放）。
2. `session/prompt` 生命周期收敛：若 ACP 返回了 prompt 的终态 response（success/error）但缺失 `prompt_complete`，daemon 仍必须把会话从 `prompting/draining` 收敛到 `idle/completed`，避免卡死。

### Layer 3: ACPProxy (每个 Session 一个)

```go
type SessionState int

const (
    StateStarting   SessionState = iota // ACP 进程启动中
    StateIdle                           // 等待 prompt
    StatePrompting                      // 正在执行 prompt
    StateDraining                       // 客户端断了, 等当前 prompt 完成
    StateCompleted                      // drain 完成
    StateDead                           // ACP 进程已退出
)

type ACPProxy struct {
    SessionID   string
    CWD         string
    State       SessionState

    cmd         *exec.Cmd          // claude-agent-acp 子进程
    stdin       io.WriteCloser     // 写入 ACP 进程
    stdout      io.ReadCloser      // 读取 ACP 进程

    eventBuffer *EventBuffer       // 缓存所有 session/update 事件
    client      *ClientConn        // 当前 attached 的客户端 (可以为 nil)

    requestCh   chan ForwardedRequest  // 客户端发来的 ACP 请求
    stopCh      chan struct{}          // 停止信号
}
```

#### ACPProxy 生命周期

```
daemon/session.create
    │
    ▼
[Starting] ── spawn claude-agent-acp, pipe stdio
    │          send initialize, receive response
    │          send session/new, receive sessionId
    ▼
[Idle] ◄──────────── prompt_complete
    │
    │  session/prompt 请求到达
    ▼
[Prompting] ── 转发请求给 ACP 进程
    │           读 ACP stdout, 缓存事件, 转发给客户端
    │
    │  ┌── prompt_complete → [Idle]
    │  │
    │  └── 客户端断开 → [Draining]
    │                       │
    │                       │  继续读 ACP stdout, 缓存事件
    │                       │  prompt_complete 到达
    │                       ▼
    │                   [Completed] → 客户端重连 → [Idle]
    │
[Dead] ── ACP 进程退出 (crash 或正常退出)
```

#### ACPProxy 核心 goroutine

```go
func (p *ACPProxy) run() {
    // Goroutine 1: 读 ACP 进程的 stdout
    go func() {
        scanner := bufio.NewScanner(p.stdout)
        for scanner.Scan() {
            msg := parseJSONRPC(scanner.Bytes())

            // 始终缓存事件
            if isNotification(msg) {
                p.eventBuffer.Append(msg)
            }

            // 检查是否是 prompt_complete
            if isPromptComplete(msg) {
                p.handlePromptComplete()
            }

            // 如果有客户端 attached，实时转发
            if client := p.getClient(); client != nil {
                client.Send(msg)
            }
        }
        // stdout 关闭 = ACP 进程退出
        p.setState(StateDead)
    }()

    // Goroutine 2: 处理客户端请求
    go func() {
        for req := range p.requestCh {
            // 序列化并写入 ACP 进程的 stdin
            data, _ := json.Marshal(req.Message)
            p.stdin.Write(append(data, '\n'))
        }
    }()
}
```

### Layer 4: EventBuffer (事件缓存)

```go
type BufferedEvent struct {
    Seq   uint64          `json:"seq"`
    Event json.RawMessage `json:"event"` // 原始 JSON-RPC notification
}

type EventBuffer struct {
    mu     sync.RWMutex
    events []BufferedEvent
    nextSeq uint64
    maxSize int // 最大事件数，默认 10000
}

func (b *EventBuffer) Append(msg json.RawMessage) uint64 {
    b.mu.Lock()
    defer b.mu.Unlock()

    seq := b.nextSeq
    b.nextSeq++
    b.events = append(b.events, BufferedEvent{Seq: seq, Event: msg})

    // 淘汰旧事件
    if len(b.events) > b.maxSize {
        b.events = b.events[len(b.events)-b.maxSize:]
    }
    return seq
}

// 返回 seq > afterSeq 的所有事件
func (b *EventBuffer) Since(afterSeq uint64) []BufferedEvent {
    b.mu.RLock()
    defer b.mu.RUnlock()

    for i, e := range b.events {
        if e.Seq > afterSeq {
            result := make([]BufferedEvent, len(b.events)-i)
            copy(result, b.events[i:])
            return result
        }
    }
    return nil
}
```

### Layer 5: ClientHandler (客户端连接处理)

每个 `opencan-daemon attach` 进程连接到 daemon socket 后，daemon 创建一个 ClientHandler：

```go
type ClientHandler struct {
    conn     net.Conn                    // Unix socket 连接
    sessions map[string]*ACPProxy        // 已 attach 的 sessions
    daemon   *Daemon                     // 引用 daemon 主体
}

func (h *ClientHandler) serve() {
    scanner := bufio.NewScanner(h.conn)
    for scanner.Scan() {
        msg := parseJSONRPC(scanner.Bytes())

        if isDaemonMethod(msg) {
            // daemon/ 前缀的管理方法，本地处理
            h.handleDaemonMethod(msg)
        } else {
            // ACP 方法，根据 sessionId 路由到对应的 ACPProxy
            sessionId := extractSessionId(msg)
            if proxy, ok := h.sessions[sessionId]; ok {
                proxy.Forward(msg)
            }
        }
    }

    // 连接断开: detach 所有 session，但不杀 ACP 进程
    for _, proxy := range h.sessions {
        proxy.Detach()
    }
}
```

## 关键场景

### 场景 1: 首次连接 Node

```
1. iOS SSH 到 node
2. exec "opencan-daemon attach"
3. attach 进程检查 ~/.opencan/daemon.pid
   → 没有 daemon 在运行
   → fork 后台 daemon 进程
   → daemon 创建 ~/.opencan/daemon.sock, 写 PID 到 daemon.pid
4. attach 进程连接 daemon.sock, 桥接 stdin/stdout
5. iOS 发 daemon/hello → 得到 daemon 信息
6. iOS 发 daemon/session.create { cwd: "/project" }
   → daemon spawn claude-agent-acp, 完成 ACP initialize + session/new
   → 返回 sessionId
7. iOS 发 session/prompt → daemon 透传给 ACP 进程
8. ACP 进程的 session/update 事件 → daemon 实时转发给 iOS
```

### 场景 2: 断线恢复 (核心场景)

```
1. iOS 发了 session/prompt, ACP 进程正在执行 tool calls
2. SSH 连接断开 (网络切换 / app 进后台)
   → attach 进程退出
   → daemon 检测到 ClientHandler 连接断开
   → ACPProxy.state = Draining (如果在 Prompting)
   → ACPProxy.client = nil
3. ACP 进程继续执行，daemon 继续读取 stdout 并缓存到 EventBuffer
4. prompt_complete 到达 → ACPProxy.state = Completed
5. 一段时间后，iOS 重连:
   → SSH → exec "opencan-daemon attach"
   → daemon 已经在运行，直接连接
   → iOS 发 daemon/hello → 看到 session 列表和状态
   → iOS 发 daemon/session.attach { sessionId, lastEventSeq: 42 }
   → daemon 返回 seq > 42 的所有缓存事件
   → iOS 回放事件，UI 恢复到最新状态
6. 用户继续发送 prompt，正常工作
```

### 场景 3: 同一 Node 多 Workspace

```
1. iOS 已连接 daemon (一条 SSH 连接)
2. daemon/session.create { cwd: "/project-A" } → session-1
3. daemon/session.create { cwd: "/project-B" } → session-2
4. 两个 ACP 进程独立运行
5. 切换 workspace:
   → daemon/session.detach { sessionId: "session-1" }
   → daemon/session.attach { sessionId: "session-2" }
   → 无需新的 SSH 连接
```

### 场景 4: Daemon 自动退出

```
所有 session 都 Dead 或 Completed
  且无客户端连接
  → 启动空闲计时器 (默认 30 分钟)
  → 计时器到期 → daemon 清理并退出
  → 删除 daemon.sock 和 daemon.pid
```

### 场景 5: session/request_permission 处理

```
ACP 进程发 session/request_permission (server → client request):

Case A: 客户端在线
  → daemon 转发给客户端
  → 客户端回复 (approve/deny)
  → daemon 转发回 ACP 进程

Case B: 客户端不在线 (Draining 状态)
  → daemon auto-approve (与当前 iOS 端行为一致)
  → 将 permission request 和 auto-approve 决定缓存到 EventBuffer
  → 客户端重连后可以看到发生了什么
```

## 消息交付契约（Message Delivery Contract）

以下契约是端到端消息链路（ACP → daemon → iOS UI）的**硬约束**，任何改动都必须保持：

1. **Prompt 终态收敛（必达）**
   - 每个 `session/prompt` 都必须最终离开运行态（`Prompting/Draining`）。
   - 可触发收敛的终态信号：
     - `session/update.sessionUpdate == "prompt_complete"`；
     - `session/prompt` error response；
     - `session/prompt` success response（用于缺失 `prompt_complete` 的回退路径）。

2. **Daemon 状态正确性**
   - 收到终态信号后：
     - 有 attached client → `Idle`
     - 无 attached client（draining）→ `Completed`
   - 不允许会话长期停留在 `Prompting/Draining`（除非 prompt 仍在进行且未收到任何终态）。

3. **事件时序与重放**
   - 每条转发到客户端的 `session/update` 都带 `__seq`。
   - `daemon/session.attach(lastEventSeq)` 必须返回所有 `seq > lastEventSeq` 的缓存事件，且顺序保持与原始到达一致。

4. **UI 作用域一致性**
   - iOS 只应用当前活跃会话（及明确标记的 history-load 来源会话）事件。
   - 非活跃会话事件必须被忽略并记录日志原因，避免串话污染 UI。

5. **可视输出保证**
   - 可解析的 `agent_message[_chunk]` / `user_message_chunk` / `tool_call[_update]` 必须映射到可渲染的 `ChatMessage`/tool 卡片。
   - 即使断线重放，也必须恢复出用户可见的最终对话状态。

### 契约回归测试（最低集合）

- Proxy 单元测试：
  - `TestRouteResponse_PromptErrorClearsRunningState`
  - `TestRouteResponse_PromptSuccessClearsRunningState`
  - `TestRouteResponse_PromptSuccessClearsDrainingStateWithoutClient`
- Daemon 集成测试：
  - `TestDaemon_PromptResponseWithoutPromptCompleteStillEndsPrompting`
  - `TestDaemon_DisconnectAndReattach`
- iOS AppState 单元测试：
  - `testNewSessionSendMessage`
  - `testIgnoresNotificationsFromOtherSessions`
  - `testResumeDrainingPromptCompleteInBuffer`
  - `testResumeHistorySession`

## iOS 端改动

### 改动最小化原则

利用现有的 `ACPTransport` 协议抽象，daemon 集成只需要：
1. 新增一个 transport 实现
2. 新增一个 daemon client
3. 修改 AppState 的连接和 session 管理流程

**不需要改动的层：** `ACPClient`, `ACPService`, `JSONRPCFramer`, `SessionUpdateParser`, 所有 Views, 所有 SwiftData Models

### 新增: DaemonTransport

```swift
/// Transport 层不变 — 仍然通过 SSH exec channel 交互
/// 唯一区别是 command 变了
///
/// 之前: SSHStdioTransport + command = "claude-agent-acp"
/// 之后: SSHStdioTransport + command = "opencan-daemon attach"
///
/// SSHStdioTransport 完全复用，无需新增 transport 类
```

实际上，因为 `opencan-daemon attach` 将 stdin/stdout 桥接到 daemon socket，对 iOS 端来说它就是一个普通的 stdio JSON-RPC 通道——与直接连 `claude-agent-acp` 的区别只在于消息内容多了 `daemon/` 前缀的方法。

**所以不需要新的 transport 类。** `SSHStdioTransport` 原封不动复用。

### 新增: DaemonClient

```swift
/// 管理 daemon/ 前缀的方法调用
/// 薄封装，类似 ACPService 对 ACPClient 的关系
actor DaemonClient {
    private let client: ACPClient  // 复用 ACPClient 做 JSON-RPC 请求

    func hello() async throws -> DaemonInfo { ... }
    func createSession(cwd: String, command: String) async throws -> String { ... }
    func attachSession(sessionId: String, lastEventSeq: UInt64) async throws -> AttachResult { ... }
    func detachSession(sessionId: String) async throws { ... }
    func listSessions() async throws -> [DaemonSessionInfo] { ... }
    func killSession(sessionId: String) async throws { ... }
}

struct DaemonInfo {
    let daemonVersion: String
    let sessions: [DaemonSessionInfo]
}

struct DaemonSessionInfo {
    let sessionId: String
    let cwd: String
    let state: String      // "idle", "prompting", "draining", "completed", "dead"
    let lastEventSeq: UInt64
}

struct AttachResult {
    let state: String
    let bufferedEvents: [BufferedEvent]
}
```

### 修改: AppState

```swift
// 新增属性
private var daemonClient: DaemonClient?
private var lastEventSeq: [String: UInt64] = [:]  // 每个 session 的已消费序列号

// connect() 改动
func connect(workspace: Workspace) {
    // ... SSH 连接建立 (不变) ...

    // 改动: command 从 node.command 变为 "opencan-daemon attach"
    // 如果 node.command 保持原来的 "claude-agent-acp"，
    // 则 daemon 创建 session 时使用它作为 ACP 命令

    ptyTask = Task.detached {
        try await sshManager.startPTY(
            transport: t,
            command: "opencan-daemon attach"  // ← 唯一改动
        )
    }

    await t.waitUntilReady()

    let client = ACPClient(transport: t)
    await client.start()
    self.acpClient = client

    // 新增: 初始化 daemon
    let daemon = DaemonClient(client: client)
    let info = try await daemon.hello()
    self.daemonClient = daemon
    self.remoteSessions = info.sessions.map { ... }

    // 不再需要 ACPService.initialize() — daemon 在 create session 时做
    self.connectionStatus = .connected
}

// createNewSession() 改动
func createNewSession(modelContext: ModelContext) async throws {
    guard let daemon = daemonClient else { throw ... }

    // 通过 daemon 创建 (daemon 内部完成 ACP init + session/new)
    let sessionId = try await daemon.createSession(
        cwd: workspace.path,
        command: activeNode.command  // "claude-agent-acp"
    )

    self.currentSessionId = sessionId
    self.lastEventSeq[sessionId] = 0
    // ... SwiftData 持久化 (不变) ...

    // Attach 到新 session
    let _ = try await daemon.attachSession(sessionId: sessionId, lastEventSeq: 0)
    startNotificationListener()
}

// resumeSession() 改动
func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
    guard let daemon = daemonClient else { throw ... }

    let lastSeq = lastEventSeq[sessionId] ?? 0
    let result = try await daemon.attachSession(
        sessionId: sessionId,
        lastEventSeq: lastSeq
    )

    // 回放缓存的事件
    for buffered in result.bufferedEvents {
        if let event = SessionUpdateParser.parse(buffered.event) {
            handleSessionEvent(event)
        }
        lastEventSeq[sessionId] = buffered.seq
    }

    self.currentSessionId = sessionId
    startNotificationListener()
}
```

### 新增: ReconnectionManager (可选，后续迭代)

```swift
/// 检测 SSH 断线，自动重连并回放事件
/// 第一版可以不做，手动重连即可
class ReconnectionManager {
    func startMonitoring()     // 监听 transport 断开
    func attemptReconnect()    // SSH 重连 + daemon attach + 事件回放
}
```

## Daemon Go 项目结构

```
opencan-daemon/
├── cmd/
│   └── opencan-daemon/
│       └── main.go              # CLI 入口, cobra 子命令
├── internal/
│   ├── daemon/
│   │   ├── daemon.go            # Daemon 主体: socket listener, 生命周期
│   │   ├── session_manager.go   # 管理所有 ACPProxy
│   │   └── client_handler.go    # 处理单个客户端连接
│   ├── proxy/
│   │   ├── acp_proxy.go         # 单个 ACP 进程管理 + stdio 读写
│   │   ├── event_buffer.go      # 事件缓存
│   │   └── state.go             # SessionState 枚举
│   ├── protocol/
│   │   ├── jsonrpc.go           # JSON-RPC 2.0 解析/序列化
│   │   ├── daemon_methods.go    # daemon/ 前缀方法的处理
│   │   └── router.go            # 消息路由 (daemon vs ACP 透传)
│   └── attach/
│       └── attach.go            # attach 子命令: stdio ↔ Unix socket 桥接
├── test/
│   ├── daemon_test.go           # Daemon 集成测试
│   ├── proxy_test.go            # ACPProxy 单元测试
│   ├── event_buffer_test.go     # EventBuffer 单元测试
│   ├── protocol_test.go         # JSON-RPC 解析测试
│   ├── mock_acp_server.go       # 模拟 claude-agent-acp 的测试 helper
│   └── e2e_test.go              # 端到端测试 (daemon + mock ACP)
├── go.mod
├── go.sum
├── Makefile                     # build, test, cross-compile
└── README.md
```

## 测试策略

### 独立测试 (不需要 SSH 或 iOS)

Daemon 的核心优势是 **可以完全独立于 iOS 客户端测试**。

#### 1. Mock ACP Server

创建一个简单的 Go 程序，模拟 `claude-agent-acp` 的行为：

```go
// test/mock_acp_server.go
// 读 stdin JSON-RPC, 写 stdout JSON-RPC
// 支持: initialize, session/new, session/prompt (返回固定 events), session/list, session/load
// 可配置延迟、错误、长时间 tool call
func main() {
    scanner := bufio.NewScanner(os.Stdin)
    for scanner.Scan() {
        msg := parseJSONRPC(scanner.Bytes())
        switch msg.Method {
        case "initialize":
            respond(msg.ID, initResult)
        case "session/new":
            respond(msg.ID, newSessionResult)
        case "session/prompt":
            // 模拟流式返回
            streamEvents(msg.Params)
            respond(msg.ID, promptResult)
        }
    }
}
```

#### 2. 单元测试

```go
// EventBuffer 测试
func TestEventBuffer_AppendAndSince(t *testing.T) { ... }
func TestEventBuffer_Overflow(t *testing.T) { ... }
func TestEventBuffer_ConcurrentAccess(t *testing.T) { ... }

// ACPProxy 测试 (使用 mock ACP server)
func TestACPProxy_CreateSession(t *testing.T) { ... }
func TestACPProxy_PromptAndStream(t *testing.T) { ... }
func TestACPProxy_ClientDisconnectDuringPrompt(t *testing.T) { ... }
func TestACPProxy_DrainToCompletion(t *testing.T) { ... }
func TestACPProxy_ACPProcessCrash(t *testing.T) { ... }

// JSON-RPC 路由测试
func TestRouter_DaemonMethods(t *testing.T) { ... }
func TestRouter_ACPPassthrough(t *testing.T) { ... }
```

#### 3. 集成测试

```go
// 启动真实 daemon + mock ACP server, 通过 Unix socket 交互
func TestDaemon_FullLifecycle(t *testing.T) {
    d := startTestDaemon(t)
    defer d.Stop()

    // 模拟客户端连接
    conn := connectToDaemon(t, d.SocketPath)

    // 创建 session
    sendJSON(conn, `{"jsonrpc":"2.0","id":1,"method":"daemon/session.create","params":{"cwd":"/tmp"}}`)
    resp := readJSON(conn)
    sessionId := resp.Result.SessionId

    // 发 prompt
    sendJSON(conn, `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"...","prompt":[...]}}`)

    // 读取流式事件
    events := readAllNotifications(conn)
    assert.Contains(t, events, "agent_message_chunk")
    assert.Contains(t, events, "prompt_complete")
}
```

#### 4. 断线恢复测试

```go
func TestDaemon_DisconnectAndReattach(t *testing.T) {
    d := startTestDaemon(t)

    // 客户端 1 连接，创建 session，发 prompt
    conn1 := connectToDaemon(t, d.SocketPath)
    sessionId := createSession(conn1)
    sendPrompt(conn1, sessionId, "do something slow")

    // 读取部分事件
    readNEvents(conn1, 3) // 读到 seq=3

    // 断开客户端 1 (模拟网络断开)
    conn1.Close()

    // 等待 mock ACP server 完成 prompt
    time.Sleep(2 * time.Second)

    // 客户端 2 连接，attach 同一个 session
    conn2 := connectToDaemon(t, d.SocketPath)
    sendJSON(conn2, `{"method":"daemon/session.attach","params":{"sessionId":"...","lastEventSeq":3}}`)
    resp := readJSON(conn2)

    // 验证: 返回了 seq > 3 的所有缓存事件
    assert.True(t, len(resp.Result.BufferedEvents) > 0)
    // 验证: 最后一个事件是 prompt_complete
    lastEvent := resp.Result.BufferedEvents[len(resp.Result.BufferedEvents)-1]
    assert.Equal(t, "prompt_complete", lastEvent.Type)
}
```

#### 5. CLI 手动测试

```bash
# 终端 1: 启动 daemon (前台模式方便调试)
opencan-daemon start --foreground --verbose

# 终端 2: 手动发 JSON-RPC
echo '{"jsonrpc":"2.0","id":1,"method":"daemon/hello"}' | opencan-daemon attach

# 或者用 socat 直接连 socket
socat - UNIX-CONNECT:~/.opencan/daemon.sock
# 然后手动输入 JSON-RPC 消息
```

## 分发策略

### iOS 端首次连接时自动部署 Daemon

参考 VS Code Remote SSH 的做法：

```
1. iOS SSH 到 node
2. exec "test -x ~/.opencan/bin/opencan-daemon && echo OK"
   → 如果没有安装:
3. 检测远端 OS/arch: exec "uname -sm" → "Linux x86_64"
4. 上传对应的 binary:
   a. SCP 方式: 从 iOS app bundle 或预下载的资源上传
   b. 或者让远端下载: exec "curl -L https://... -o ~/.opencan/bin/opencan-daemon && chmod +x ..."
5. exec "opencan-daemon attach"
```

### 预编译的 targets

```makefile
# Makefile
TARGETS = linux-amd64 linux-arm64 darwin-amd64 darwin-arm64

build-all:
	@for target in $(TARGETS); do \
		GOOS=$$(echo $$target | cut -d- -f1) \
		GOARCH=$$(echo $$target | cut -d- -f2) \
		go build -o dist/opencan-daemon-$$target ./cmd/opencan-daemon; \
	done
```

## 实现顺序

### Phase 1: Daemon 核心 (Go, 可独立测试)

1. JSON-RPC 解析/序列化
2. EventBuffer
3. ACPProxy (spawn 进程, pipe stdio, 状态机)
4. Daemon 主体 (Unix socket listener, session manager)
5. attach 子命令 (stdio ↔ socket 桥接)
6. 单元测试 + mock ACP server
7. 集成测试 (daemon + mock ACP)

### Phase 2: iOS 集成

8. `DaemonClient` actor
9. `AppState.connect()` 改为 `opencan-daemon attach`
10. `AppState.createNewSession()` / `resumeSession()` 改为走 daemon
11. 事件回放逻辑
12. Daemon binary 分发 (SCP 上传)

### Phase 3: 断线重连

13. 检测 SSH 断线
14. 自动重连 SSH
15. Re-attach session + 事件回放
16. UI 状态恢复 (loading indicator, 恢复 scroll 位置)

### Phase 4: 优化

17. Daemon 空闲自动退出
18. EventBuffer 压缩 (合并 tool_call_update 中间态)
19. 多客户端支持 (同一 session 多设备查看)
20. Daemon 日志和调试工具
