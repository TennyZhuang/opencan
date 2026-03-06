# 第一性原理架构审视

## 为什么写这个文档

我们陷入了一个循环：修 bug → 加测试 → 新 bug → 更多测试。测试数量在增长，但系统并没有变得更稳定。这通常说明**不是实现有 bug，而是设计本身引入了不必要的复杂度**。

本文从第一性原理出发，重新审视：什么是我们真正需要的？什么是可以去掉的？

## 核心目标（不可简化）

1. 手机通过 SSH 操控远端 coding agent（Claude Code、Codex 等）
2. SSH 连接可以断，但 agent 任务不能断
3. 重连后能恢复到断线前的状态
4. 在电脑上启动的 agent 也能在手机上接管

这四条是产品的根本价值主张。其中第 4 条（外部 session 接管）是复杂度的最大来源。

## 当前架构的数据

| 组件 | 行数 | 功能 |
|------|------|------|
| AppState.swift | 2,649 | iOS 状态协调 |
| acp_proxy.go | 833 | ACP 进程管理 |
| client_handler.go | 600 | 请求路由 |
| session_manager.go | 546 | Session 生命周期 |
| daemon.go | 240 | Daemon 生命周期 |
| **Daemon 合计** | **2,219** | |
| AppStateTests.swift | 2,264 | iOS 测试 |
| daemon_test.go | 1,588 | Daemon 测试 |
| **测试合计** | **~5,800** | |

测试代码量接近产品代码量。这不是好现象——它说明产品代码的分支路径太多，需要大量测试来覆盖。

## 复杂度的三个根源

### 根源 1：三处数据源，无单一真相

系统存在三个状态存储，必须持续对账：

```
SwiftData (iOS)          SessionManager (Daemon)      ACP Process
┌──────────────┐        ┌──────────────────┐         ┌─────────────┐
│ Session       │        │ ACPProxy          │         │ session/list │
│  .sessionId   │ ←?→   │  .SessionID       │  ←?→   │  返回的 ID    │
│  .canonicalId │        │  .State           │         │  进程内状态    │
│  .agentID     │        │  .client          │         │              │
│  .sessionCwd  │        │  .eventBuffer     │         │              │
└──────────────┘        └──────────────────┘         └─────────────┘
```

**理想状态：Daemon 是唯一真相源。** 客户端只持有 session ID 的引用，不缓存状态。
ACP 进程的状态由 Daemon 管理，客户端不需要直接感知。

**现状的偏离：**
- SwiftData 的 `Session` 模型存了 `sessionCwd`、`agentID`、`agentCommand`、`canonicalSessionId`——这些是 daemon 应该知道的事
- AppState 维护了 `lastEventSeq` 字典、`daemonSessions` 快照、`promptLastActivityAt` 字典——都是 daemon 状态的客户端镜像
- 每次 `resumeSession` 都需要在三个数据源之间做复杂的对账

### 根源 2：External Session Takeover 引入了巨量复杂度

外部 session 接管（在电脑上创建的 agent，在手机上恢复）是一个合理的需求，但当前实现是系统中最复杂的单一功能。

**它独自引入的复杂度（精确计数）：**

| 概念/代码 | 行数 |
|-----------|------|
| `takeOverExternalSession()` | 266 行 |
| `loadSessionFromCandidates()` + CWD 重试 | 90 行 |
| `restorePreviousAttachmentIfNeeded()` | 38 行 |
| `loadCwdCandidates()` | 22 行 |
| resumeSession 中外部 session 分支 | ~100 行 |
| `canonicalSessionId` 映射 + `temporaryNotificationSessionIDs` | ~30 行 |
| Daemon `loadableSessions()` (外部发现) | 80 行 |
| Daemon `discoverExternalSessionsWithCommands()` | 76 行 |
| Daemon `selectSoleRoutableProxyForSessionLoad()` | 34 行 |
| Daemon probe scoring + helper 函数 | 34 行 |
| **iOS 相关测试** | **530 行 (9 个测试)** |
| **Daemon 相关测试** | **~200 行 (3 个测试)** |

实际统计：**外部 session 接管贡献了 ~1,500 行代码**（约占产品+测试代码的 18%），以及大部分难以调试的 edge case。

**根本问题：** 接管外部 session 需要创建一个新的 ACP 进程，然后用 `session/load` 把旧对话加载进来。但这个新进程没有旧进程的内存状态（工具状态、环境变量等），加载的只是文字记录。这个操作本质上是**有损恢复**，但代码试图让它看起来无缝——这需要大量的 fallback、retry 和 mapping 来维持这个幻觉。

### 根源 3：resumeSession 是一个 350 行的 God Function

`resumeSession` 混合了 5 个不同的关注点：

1. **Session 分类**（是外部的？已映射的？daemon 知道的？）
2. **Attach 操作**（带 retry、ownership conflict 处理、rollback）
3. **Event replay**（buffer 回放 + 可选的 session/load 回填）
4. **SwiftData 持久化**（find or create、更新字段）
5. **UI 状态管理**（isPrompting、isLoadingHistory、messages、system messages）

这不是一个函数应该承担的责任。当一个函数有 13 个 error path 和 3 种 recovery strategy 时，任何修改都可能引入回归——这就是为什么我们需要越来越多的测试。

## 从第一性原理出发的理想设计

### 原则 1：Daemon 是唯一真相源

```
iOS                        Daemon                     ACP
┌─────────────┐           ┌──────────────────┐       ┌───────┐
│ UI           │           │ Session Registry  │       │ Agent │
│ session refs │──attach──▶│  owns state       │──────▶│       │
│ (ID only)    │◀─events──│  owns buffer      │◀──────│       │
│              │           │  owns lifecycle   │       │       │
└─────────────┘           └──────────────────┘       └───────┘
```

**客户端只存：**
- Session ID（引用）
- 哪个 workspace 创建的（UI 分组用）
- `lastEventSeq`（replay cursor）
- UI 偏好（agent 图标、别名等）

**客户端不存：**
- Session 的 CWD（问 daemon 要）
- Agent command（问 daemon 要）
- Session 是否存活（问 daemon 要）
- `canonicalSessionId`（不需要映射关系）

### 原则 2：只有两种 session 操作

1. **Create**: `daemon/session.create` → 得到 sessionId → attach
2. **Resume**: `daemon/session.attach(sessionId)` → 成功（replay events）或失败（session 不存在）

不应该有第三种操作（takeover）混在 resume 里。如果外部 session 需要接管，它应该是一个独立的、显式的用户动作。

### 原则 3：状态转换必须显式

当前的隐式转换：
- Detach during Prompting → 自动变 Draining
- Attach to Completed → 自动变 Idle

这些隐式转换让状态机难以推理。更好的方式：
- Detach 时 daemon 返回新状态，客户端不需要猜
- Attach 返回当前状态，客户端根据状态决定行为，而不是 daemon 偷偷改状态

（注：daemon 内部 Prompting→Draining 的转换是合理的，因为确实需要标记"没有客户端但还在跑"。但 Completed→Idle 的自动提升是不必要的——从客户端角度来说，attach 一个 completed session 和 attach 一个 idle session 的行为应该一样。）

### 原则 4：减少恢复路径的数量

当前 resumeSession 的路径：

```
resumeSession(sessionId)
├── 外部 session → 已有映射？ → 重定向到 managed session
│                  └── 无映射？ → takeOverExternalSession（270 行）
├── daemon 已知 session → attach
│   ├── attach 成功 → replay
│   │   ├── running → replay + 可选 load
│   │   └── idle/completed → replay + 可选 load
│   ├── attach 被另一个 client 持有 → rollback + error
│   └── attach session 不存在 → takeover recovery → 可能 mark dead
└── 同一 session 重入 → 复用内存状态
```

**理想的路径应该只有：**

```
resumeSession(sessionId)
├── 同一 session 重入 → 复用内存状态
├── attach 成功 → replay buffer → 可选 load 回填
└── attach 失败 → mark dead + 报错
```

三条路径。清晰、可预测、可测试。

## 具体简化建议

### 建议 1：代码路径分离，UX 统一

用户体验不变——在 SessionPickerView 里看到所有 session（managed + external），点击任意一个都能恢复。但代码层面把两种 session 的恢复拆成完全独立的函数：

```
SessionPickerView: 用户点击 session
    │
    ├── session.state != "external"
    │   └── resumeSession(sessionId)        // 只做 attach + replay
    │
    └── session.state == "external"
        └── adoptExternalSession(sessionId)  // 只做 create + attach + load
```

**关键原则：`resumeSession` 永远不 fallback 到 takeover。`adoptExternalSession` 永远不调用 resumeSession。两条路径完全隔离。**

调用点在 SessionPickerView 或 AppState 的入口处做分发，而不是在 resumeSession 的内部做条件判断。

**效果：**
- `resumeSession` 从 350 行缩减到 ~50 行（只处理 managed session）
- `adoptExternalSession` 是独立函数（~100 行），可独立测试
- 不再需要 `temporaryNotificationSessionIDs`
- 不再需要 `mappedManagedSessionForExternal()` 重定向
- 不再需要 attach 失败时的 takeover fallback
- 外部 session 失败不影响正常 session resume
- 两条路径各自的错误处理简单明确

### 建议 2：简化 Session SwiftData 模型

```swift
// 现在
@Model final class Session {
    var sessionId: String
    var canonicalSessionId: String?  // 外部 session 映射
    var sessionCwd: String?          // 冗余，daemon 知道
    var agentID: String?             // 冗余，daemon 知道
    var agentCommand: String?        // 冗余，daemon 知道
    var lastUsedAt: Date
    // ...
}

// 建议
@Model final class Session {
    var sessionId: String            // daemon session ID（唯一标识）
    var lastUsedAt: Date             // 排序用
    // workspace 关系保留（UI 分组用）
}
```

Agent 信息、CWD 等从 daemon 的 `session.list` 响应中获取，不在客户端持久化。这消除了对账的需要。

**权衡：** 如果 daemon 重启了（session 全丢），客户端会丢失这些信息。但这种情况下 session 本身就不存在了，这些信息也没用了。

**更保守的选择：** 保留 `sessionCwd` 和 `agentID` 作为缓存，但明确它们只是 cache，daemon 的值优先。去掉 `canonicalSessionId`。

### 建议 3：统一 replay 路径——消除 running/idle 分支

现在 `resumeSession` 里 running 和 idle/completed 的处理几乎一样：

```swift
// running 分支
isPrompting = true
for buffered in result.bufferedEvents { replay... }
if !hasVisibleReplay { loadSession... }
isPrompting = false

// idle/completed 分支（几乎相同！）
for buffered in result.bufferedEvents { replay... }
if !hasVisibleReplay { loadSession... }
```

唯一区别是 `isPrompting` flag。统一为：

```swift
let isRunning = result.state == "prompting" || result.state == "draining"
if isRunning { isPrompting = true }

for buffered in result.bufferedEvents { replay... }
if !hasRenderableConversation() { await loadHistory... }

// Running session: clear prompting after resume to not lock input.
// If ACP is still busy, prompt_complete will arrive via notification listener.
if isRunning { isPrompting = false }
for msg in messages where msg.isStreaming { msg.isStreaming = false }
```

这不是大改动，但消除了代码重复和认知负担。

### 建议 4：Prompt Watchdog 提取为独立组件

`sendPromptAwaitingTerminalResponse` 和相关的 `promptLastActivityAt` 跟踪、inactivity timeout 逻辑散布在 AppState 里，增加了约 200 行。

提取为：
```swift
actor PromptWatchdog {
    func watchPrompt(sessionId: String, daemon: DaemonClient) async throws -> PromptResult
    func markActivity(sessionId: String)
}
```

这把 AppState 的 prompt 生命周期管理从 inline 代码变成了可独立测试、独立推理的组件。

### 建议 5：减少 CWD 候选重试

`loadCwdCandidates` 构建 4-5 个候选 CWD，然后逐个尝试 `session/load`。这是因为 ACP 的 `session/load` 需要 CWD 来定位会话。

**问题：** 这个重试链是很大的复杂度来源（约 120 行 + 30 行工具函数）。

**建议：**
- 首选 daemon 报告的 CWD（`daemonKnownSession.cwd`）
- 退而求其次用 workspace 的 path
- **最多两个候选**，不做更多猜测
- 如果两个都不行，就是 load 失败——老老实实告诉用户

### 建议 6：Attach 失败时优雅降级，不做 inline takeover

现在 attach 失败（session not found）会在 `resumeSession` 内部触发 takeover recovery——这让 resumeSession 的复杂度翻倍。

**建议：** `resumeSession` 中 attach 失败 = 返回明确错误。调用者（SessionPickerView / ChatView）拿到错误后，可以选择：
- 显示 "Session lost. Restart from history?" 按钮
- 用户确认后调用 `adoptExternalSession(canonicalSessionId)` 走独立恢复路径

这样 resumeSession 本身保持简单（3 条路径），而恢复能力不丢失——只是从"自动 inline fallback"变成"错误后用户确认 → 独立恢复"。对用户来说几乎无感——就是多一次点击确认。

## 简化后的伪代码

### 入口分发（SessionPickerView 或 AppState 顶层）

```swift
/// 用户在 SessionPickerView 点击 session 时调用。
/// 对用户透明——managed 和 external 的 UX 相同（都是点击即恢复）。
func openSession(sessionId: String, modelContext: ModelContext) async throws {
    let daemonSession = daemonSessions.first { $0.sessionId == sessionId }

    if daemonSession?.state == "external" {
        try await adoptExternalSession(
            externalSessionId: sessionId,
            cwd: daemonSession?.cwd ?? activeWorkspace?.path ?? "",
            modelContext: modelContext
        )
    } else {
        try await resumeSession(sessionId: sessionId, modelContext: modelContext)
    }
}
```

### resumeSession（只处理 managed session）

```swift
func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
    guard let daemon = daemonClient, let workspace = activeWorkspace else {
        throw AppStateError.notConnected
    }

    // Fast path: re-entering the same live session
    if currentSessionId == sessionId, !messages.isEmpty { return }

    // Detach previous session
    await detachCurrentSessionIfNeeded(daemon: daemon)

    // Attach
    let result: DaemonAttachResult
    do {
        result = try await daemon.attachSession(
            sessionId: sessionId,
            lastEventSeq: lastEventSeq[sessionId] ?? 0,
            clientId: daemonAttachClientID
        )
    } catch {
        if isOwnershipConflict(error) {
            throw AppStateError.sessionAttachedByAnotherClient(sessionId)
        }
        markSessionDead(sessionId: sessionId, modelContext: modelContext)
        throw AppStateError.sessionNotRecoverable(sessionId)
    }

    // Replay
    currentSessionId = sessionId
    messages = []
    let isRunning = result.state == "prompting" || result.state == "draining"
    if isRunning { isPrompting = true }

    for event in result.bufferedEvents {
        handleSessionEvent(event, sessionId: sessionId)
        lastEventSeq[sessionId] = event.seq
    }

    if !hasRenderableConversation() {
        await loadSessionHistory(sessionId: sessionId, cwd: result.cwd ?? workspace.path)
    }

    if isRunning { isPrompting = false }
    for msg in messages where msg.isStreaming { msg.isStreaming = false }

    updateOrCreateLocalSession(sessionId: sessionId, workspace: workspace, modelContext: modelContext)
}
```

### adoptExternalSession（只处理外部 session）

```swift
func adoptExternalSession(
    externalSessionId: String,
    cwd: String,
    modelContext: ModelContext
) async throws {
    guard let daemon = daemonClient, let workspace = activeWorkspace else {
        throw AppStateError.notConnected
    }

    await detachCurrentSessionIfNeeded(daemon: daemon)

    // Step 1: Create managed proxy
    let command = resolveAgentCommand()
    let managedId = try await daemon.createSession(cwd: cwd, command: command)

    // Step 2: Attach to it
    let result: DaemonAttachResult
    do {
        result = try await daemon.attachSession(
            sessionId: managedId, lastEventSeq: 0, clientId: daemonAttachClientID
        )
    } catch {
        try? await daemon.killSession(sessionId: managedId)
        throw error
    }

    // Step 3: Load external history into the new proxy
    currentSessionId = managedId
    messages = []
    isLoadingHistory = true
    defer { isLoadingHistory = false }

    let loadOk = await loadSessionHistory(sessionId: externalSessionId, cwd: cwd)

    if !loadOk {
        // Load failed — kill the proxy, report error
        try? await daemon.killSession(sessionId: managedId)
        currentSessionId = nil
        throw AppStateError.sessionNotRecoverable(externalSessionId)
    }

    for msg in messages where msg.isStreaming { msg.isStreaming = false }

    // Step 4: Persist — the session now lives under managedId
    let session = Session(sessionId: managedId, sessionCwd: cwd, workspace: workspace)
    modelContext.insert(session)
    activeSession = session
    try? modelContext.save()
}
```

两个函数各自 ~50 行，独立、清晰、可测试。

## 简化后的 Daemon 端变化

### 拆分 `session.list` 和 `session.discover`

当前 `session_manager.go` 的 `ListSessionsForCWD` 有 200+ 行，混合了 managed session 列表和外部 session 发现（probe managed proxy → fallback 直接 probe discovery commands → 合并去重限制数量）。

**拆分为两个 API：**
- `daemon/session.list` — 只返回 daemon 管理的 session（~20 行）
- `daemon/session.discover` — 专门做外部 session 发现（~80 行，逻辑独立）

iOS 端：
- SessionPickerView 打开时先调 `session.list`（快，必须成功）
- 然后异步调 `session.discover`（慢，可失败，结果追加到列表）

这样 `session.list` 从不失败（只查本地 map），外部发现的复杂度被隔离。

### 保留但简化 `selectSoleRoutableProxyForSessionLoad`

外部 session takeover 时，`session/load` 的 sessionId 不匹配任何 attached proxy——这是 daemon 需要兜底的。但现在 `adoptExternalSession` 是一个清晰的调用序列（create → attach → load），daemon 知道这个 client handler 刚 attach 了哪个 proxy，所以 "route to the sole attached proxy" 的逻辑变得trivial。

## 风险评估

| 简化 | 风险 | 缓解 |
|------|------|------|
| 外部 session 从 resume 移出 | 用户体验变化：不再自动接管 | 用显式 UI 替代，更透明 |
| Attach 失败不 takeover | Daemon 重启后旧 session 无法自动恢复 | 显式恢复 UI + 告知用户 |
| 简化 Session 模型 | Daemon 不可用时丢失 agent 信息 | 保留为 cache，daemon 优先 |
| 减少 CWD 候选 | 某些边缘情况 load 失败 | 失败时明确提示 |

## 执行优先级

1. **代码路径分离：resumeSession vs adoptExternalSession**——影响最大的单一改动。resumeSession 从 350 行缩至 ~50 行，adoptExternalSession 独立为 ~100 行的纯函数。预计净减 ~200 行产品代码、~300 行测试代码。
2. **统一 running/idle replay 路径**——简单重构，消除 resumeSession 内部代码重复。
3. **去掉 canonicalSessionId + mappedManagedSession 映射**——adoptExternalSession 成功后直接替换 Session.sessionId 为 managed ID，不需要双 ID 映射。
4. **Daemon 端拆分 list/discover**——`session.list` 只返回 managed session；新增 `session.discover` 用于外部发现。两个 API 各自简单。
5. **简化 CWD 候选逻辑**——最多两个候选（daemon 报告的 + workspace path），不做更多猜测。
6. **提取 PromptWatchdog**——降低 AppState 行数和认知负担。

## 总结

我们不是 bug 多，是**状态空间太大**。

当前系统的状态空间约为：
- Daemon session 状态 7 种 × 客户端连接状态 3 种 × session 类型 3 种（managed/external/mapped） × attach 结果 4 种 = **252 种组合**

简化后（路径分离 + 去掉映射）：
- resumeSession 路径：session 状态 6 种 × 连接状态 2 种 × attach 结果 2 种 = **24 种组合**
- adoptExternalSession 路径：create 结果 2 种 × attach 结果 2 种 × load 结果 2 种 = **8 种组合**
- **合计 32 种组合**，比原来的 252 种缩小了 8 倍

状态空间缩小一个数量级，bug 的藏身之处也缩小一个数量级。功能完全保留——用户照样点任何 session 都能恢复。
