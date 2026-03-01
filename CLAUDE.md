# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is a symlink to this file, so keep this document current.

## Build & Run

```bash
# Generate Xcode project from project.yml (required after adding/removing files)
xcodegen generate

# Build for iOS Simulator
xcodebuild -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -quiet build

# Note: OpenCAN target has a post-build script that cross-compiles the
# daemon into the app bundle as opencan-daemon-linux-amd64 when daemon
# sources change; otherwise it reuses the existing bundled binary.
# Set SKIP_DAEMON_BUNDLE_BUILD=1 to skip this in local builds.

# Install and launch on simulator (replace UDID as needed)
SIM=363362BD-4565-4127-AD34-255975041E1E
APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenCAN-*/Build/Products/Debug-iphonesimulator -name "OpenCAN.app" -maxdepth 1 | head -1)
xcrun simctl install $SIM "$APP"
xcrun simctl terminate $SIM com.tianyizhuang.OpenCAN 2>/dev/null
xcrun simctl launch $SIM com.tianyizhuang.OpenCAN

# Read app logs (print() does not show in system log; app writes to Documents/opencan.log)
CONTAINER=$(xcrun simctl get_app_container $SIM com.tianyizhuang.OpenCAN data)
cat "$CONTAINER/Documents/opencan.log"

# Copy logs from a real device (replace UDID from `xcrun devicectl list devices`)
DEVICE=8E97C747-7121-5A99-910D-1F87D867F44C
xcrun devicectl device copy from --device $DEVICE \
  --source Documents/opencan.log --destination /tmp/opencan.log \
  --domain-type appDataContainer --domain-identifier com.tianyizhuang.OpenCAN
```

App logs are JSON lines (`LogEntry`). Daemon logs are also structured JSON and live on the remote host at `~/.opencan/daemon.log` (rotates to `daemon.log.prev` at 10MB).

No linter is configured. A UI test target (`OpenCANUITests`) exists in `project.yml`.

## Daemon Build & Test

```bash
cd opencan-daemon

# Build daemon binary + mock ACP server
make build mock-acp

# Run unit tests
make test

# Run integration tests (requires mock-acp-server binary)
go test -v -race -timeout 60s ./test/

# Cross-compile daemon and copy to iOS app bundle (required before deploying to a new server)
cd opencan-daemon && make install-ios

# Manual testing: start daemon in foreground, connect via socat
bin/opencan-daemon start --foreground --verbose
# In another terminal:
socat - UNIX-CONNECT:~/.opencan/daemon.sock
```

## Architecture

OpenCAN is an iOS ACP (Agent Client Protocol) client that connects to configured ACP launch commands (defaults: `claude-agent-acp`, `codex-acp`) through a persistent remote daemon over SSH. The wire protocol is JSON-RPC 2.0 over newline-delimited stdio (agentclientprotocol.com).

**Layer stack (bottom -> top):**

1. **SSH** - `SSHConnectionManager` uses Citadel for RSA key auth, optional jump host, then opens a PTY on the target running `~/.opencan/bin/opencan-daemon attach`. `SSHStdioTransport` (actor) wraps the PTY as an `ACPTransport` (`send()` + `messages` stream). The PTY read loop uses `defer { messageContinuation.finish() }` so streams always terminate. On PTY death, transport closes to cancel pending RPC requests. `SSHConnectionManager` also auto-deploys daemon binaries (`ensureDaemonInstalled`) and uploads/cleans chat image resources (`uploadChatImage`, `cleanupExpiredChatUploads`).

2. **JSON-RPC** - `JSONRPCFramer` (actor) buffers PTY bytes, skips non-JSON noise, and extracts newline-delimited JSON messages. `JSONRPCMessage` preserves explicit `result: null` as `.null`. `JSONValue` is the generic JSON helper with subscript access.

3. **Daemon** - `opencan-daemon` is a Go process on the remote server that owns ACP process lifecycle independent of SSH. `attach` bridges stdio to `~/.opencan/daemon.sock`. `daemon/` methods are handled locally (`hello`, `agent.probe`, `session.create`, `session.attach`, `session.detach`, `session.list`, `session.kill`, `logs`). Non-`daemon/` requests are forwarded by session routing. `__routeToSession` overrides are supported for `session/load` and `session/prompt`.

4. **ACP** - `ACPClient` (actor) correlates request IDs, handles cancellation, dispatches notifications, filters PTY echoes via `sentRequestIds`, and auto-approves `session/request_permission`. `sendRequest()` injects `_meta.traceId` into object/nil params. `DaemonClient` provides typed daemon wrappers, including agent probe and daemon log fetch. `ACPService` wraps ACP passthrough (`sendPrompt`, `loadSession`) with structured prompt blocks (`PromptBlock.text`, `PromptBlock.resourceLink`). `SessionUpdateParser` maps `session/update` notifications to `SessionEvent`.

5. **Persistence** - SwiftData models: `Node` (SSH host + optional jump server), `Workspace` (remote cwd), `Session` (daemon session binding + history source metadata + agent metadata), `SSHKeyPair` (RSA key data). `Session` stores `sessionCwd`, `historySessionId`, `historySessionCwd`, `agentID`, `agentCommand`. Cascade delete: Node -> Workspaces -> Sessions.

6. **AppState** - `@MainActor @Observable` coordinator. `connect(node:)` establishes SSH + daemon with 30s timeout (`daemon/hello`). `refreshAvailableAgents()` probes launcher availability and marks reliability (`hasReliableAgentAvailability`). `createNewSession()` picks preferred/fallback agent command. `resumeSession()` chooses among: buffered replay for running sessions, attach + optional load backfill for idle/completed sessions, history recovery via new session + routed load when daemon forgot a session, and direct recovery for `external` sessions. Before switching sessions, AppState detaches prior attachments via `daemon/session.detach`. `lastEventSeq` tracks replay cursors. History replay is session-scoped and supports demoting first bootstrap user prompt (for external `agent-*` sessions) into a system message. `sendMessage()` supports image mentions (`@img_xxx`) by turning referenced uploads into ACP `resource_link` prompt blocks.

7. **SwiftUI/UIKit hybrid UI** - `ContentView` hosts `NavigationStack`: `NodeListView -> WorkspaceListView -> SessionPickerView -> ChatView`. Connection scope is node-level at `WorkspaceListView`. `NodeListView` gear menu includes **Agent Settings** and **Diagnostics**. `SessionPickerView` merges daemon + local sessions into `UnifiedSession`, applies workspace path normalization (tilde/home aliases), and shows state badges (`idle/prompting/draining/completed/history/dead/external`). `ChatMessageListView` uses ListViewKit (FlowDown-style timeline) for stable streaming updates; `InputBarView` supports PhotosPicker uploads and `@mention` autocomplete.

**Key protocol details:**
- iOS connects through `opencan-daemon attach`, not directly to ACP binaries.
- Client request IDs start at 1000; daemon rewrites server-initiated request IDs per client handler to avoid collisions across proxies.
- PTY echoes stdin writes on stdout; `ACPClient` ignores echoed requests by request ID.
- Trace correlation uses `_meta.traceId` on requests; daemon extracts it into slog context.
- `session/request_permission` is auto-approved when no client is attached (draining mode).
- Daemon forwards `session/update` notifications with `__seq`; iOS persists per-session cursors for replay.
- `__routeToSession` is used for both `session/load` and `session/prompt` when recovered sessions need logical-vs-attached routing.
- `daemon/session.attach` is single-owner: one attached client per daemon session.
- `daemon/session.list` supports optional `cwd` to scope external session discovery.
- `daemon/agent.probe` checks configured launcher commands on the remote host.
- `daemon/logs` returns recent in-memory structured daemon logs (optional `traceId` filter).

**State flow for prompting/streaming:**
- `sendMessage()` creates user + streaming assistant rows and sends `session/prompt`.
- Prompt payload can include text plus `resource_link` blocks for referenced uploaded images.
- `session/update` includes `agent_message_chunk`, `agent_message`, `tool_call`, `tool_call_update`, `thought`, `agent_thought_chunk`, `user_message_chunk`, `prompt_complete`.
- When tool calls start, current assistant text bubble stops streaming; later text continues in a new assistant bubble.
- `prompt_complete` clears assistant spinners, ends prompting state, and refreshes daemon session snapshot.
- Fallback: prompt response success/error also clears prompting state if `prompt_complete` is missing.
- Thought updates are intentionally not rendered in chat to avoid Markdown re-layout flicker under heavy streaming.

## Message Delivery Contract (Normative)

This is the end-to-end contract for "agent output reaches UI" and is treated as a regression boundary.

1. **Prompt lifecycle must terminate:** every `session/prompt` must drive daemon/UI out of running state via at least one terminal signal:
   - `session/update` with `sessionUpdate: "prompt_complete"`, or
   - JSON-RPC error response for `session/prompt`, or
   - JSON-RPC success response for `session/prompt` (fallback when `prompt_complete` is missing).
2. **No stale daemon running state:** after a terminal prompt signal, daemon state must not remain `prompting`/`draining`; it transitions to `idle` (attached client) or `completed` (detached/draining).
3. **Delivery + replay ordering:** forwarded `session/update` notifications carry `__seq`; `daemon/session.attach(lastEventSeq)` replays buffered events with `seq > lastEventSeq` in order.
4. **Scoped UI application:** AppState applies updates only for the active chat session IDs (plus explicit history-replay source IDs).
5. **Renderable output guarantee:** assistant/user/tool updates must mutate `AppState.messages` so visible transcript content survives live streaming and replay.

**Contract regression tests to keep green:**
- Daemon: `TestRouteResponse_PromptSuccessClearsRunningState`, `TestRouteResponse_PromptSuccessClearsDrainingStateWithoutClient`, `TestDaemon_PromptResponseWithoutPromptCompleteStillEndsPrompting`, `TestDaemon_LogsEndpointSupportsTraceFiltering`.
- iOS AppState: `testNewSessionSendMessage`, `testSendMessageWithoutPromptCompleteStillClearsPrompting`, `testIgnoresNotificationsFromOtherSessions`, `testResumeDrainingPromptCompleteInBuffer`, `testResumeHistorySession`, `testResumeRecoveredSessionUsesOriginalHistorySource`, `testResumeExternalAgentSessionDemotesBootstrapPromptToSystemMessage`, `testSendMessageWithImageMentionAddsResourceLinkPromptBlock`.
- iOS ACP/Session helpers: `ACPClientTests` trace-id/cancellation coverage and `SessionPickerPathMatchingTests` path normalization coverage.

**Chat list/scroll behavior:**
- `AppState.contentDidChange()` uses throttle-with-trailing behavior (max cadence ~300ms, plus trailing 150ms debounce) before bumping `contentVersion`.
- `ChatMessageListView` follows content when prompting or when already near bottom (`nearBottomTolerance = 2`).
- `forceScrollToBottom` in AppState increments `forceScrollToken` in `ChatView` to force jumps after user send/prompt completion.
- ListViewKit timeline + explicit height caching avoids old SwiftUI `LazyVStack` overscroll drift and improves streaming stability.

## Conventions

- **SwiftData** for persistent host/workspace/session/key configuration.
- **Actors** for protocol and transport state (`ACPClient`, `JSONRPCFramer`, `SSHStdioTransport`, `SSHConnectionManager`).
- **`@MainActor @Observable`** for UI state (`AppState`, `ChatMessage`).
- **`AsyncStream`** for notifications and transport message pipelines.
- **Structured logging:** prefer `Log.log(...)` and `Log.timed(...)` (JSON lines + in-memory ring buffer). `Log.toFile(...)` remains for legacy call sites.
- **Diagnostics:** `DiagnosticView` can inspect iOS log ring buffer, fetch daemon logs (`daemon/logs`), inspect state snapshot, and export JSON.
- **XcodeGen** (`project.yml`) generates `.xcodeproj`; run `xcodegen generate` after file list changes.
- **Unit tests:** `AppStateTests` cover agent probing/fallback, image mention prompts, resume/recovery routing, detach-before-switch, cross-session filtering, dead-session recovery, and empty-session pruning.
- **Other tests:** `ACPClientTests`, `SessionPickerPathMatchingTests`, `SessionUpdateParserTests`, `JSONRPCMessageTests`.
- **UI tests** (`OpenCANUITests`) cover navigation, session creation, sending, resume, and loading state. E2E tests require reachable cp32 server and use `XCTSkip` when unavailable.

**Daemon architecture:**
- `opencan-daemon/` contains the Go daemon source. See `docs/daemon-architecture.md` for protocol/lifecycle details.
- **Auto-deploy:** `SSHConnectionManager.ensureDaemonInstalled()` uploads bundled `opencan-daemon-linux-amd64` when remote hash mismatches.
- Daemon startup uses `slog.NewJSONHandler` and writes to `~/.opencan/daemon.log` (plus stderr in true foreground mode), with simple size rotation to `.prev` at 10MB.
- Daemon logs are mirrored into an in-memory `LogRingBuffer` (default 2000 entries) via `BufferingHandler`, exposed by `daemon/logs`.
- ACPProxy state machine: `Starting -> Idle -> Prompting -> Draining -> Completed -> Dead`, plus `External` for sessions discovered from ACP but unmanaged by daemon.
- `daemon/session.list` returns managed sessions and external sessions (up to 50), optionally scoped by cwd. External discovery falls back to probing ACP directly (commands from `OPENCAN_DISCOVERY_COMMANDS`, default `claude-agent-acp,codex-acp`) when no managed proxy is available.
- Event replay uses per-session `EventBuffer` (max 100000 in ACPProxy) with monotonic sequence numbers and copy-on-evict to avoid retaining old backing arrays.
- `daemon/session.attach` returns buffered events since `lastEventSeq` and rejects second concurrent attach.
- Idle timeout re-arms while sessions remain busy/draining so daemon exits only after no clients and all sessions settle.
- Agent launch commands are configured in Agent Settings (Claude/Codex defaults), validated through `daemon/agent.probe`, and used for new session creation.
