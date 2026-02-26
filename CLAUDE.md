# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Generate Xcode project from project.yml (required after adding/removing files)
xcodegen generate

# Build for iOS Simulator
xcodebuild -scheme OpenCAN -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build

# Install and launch on simulator (replace UDID as needed)
SIM=363362BD-4565-4127-AD34-255975041E1E
APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenCAN-*/Build/Products/Debug-iphonesimulator -name "OpenCAN.app" -maxdepth 1 | head -1)
xcrun simctl install $SIM "$APP"
xcrun simctl terminate $SIM com.tianyizhuang.OpenCAN 2>/dev/null
xcrun simctl launch $SIM com.tianyizhuang.OpenCAN

# Read app logs (print() doesn't show in system log; app writes to Documents/opencan.log)
CONTAINER=$(xcrun simctl get_app_container $SIM com.tianyizhuang.OpenCAN data)
cat "$CONTAINER/Documents/opencan.log"

# Copy logs from a real device (replace UDID from `xcrun devicectl list devices`)
DEVICE=8E97C747-7121-5A99-910D-1F87D867F44C
xcrun devicectl device copy from --device $DEVICE \
  --source Documents/opencan.log --destination /tmp/opencan.log \
  --domain-type appDataContainer --domain-identifier com.tianyizhuang.OpenCAN
```

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

OpenCAN is an iOS ACP (Agent Client Protocol) client that connects to `claude-agent-acp` via a persistent daemon over SSH. The protocol is JSON-RPC 2.0 over newline-delimited stdio, per the spec at agentclientprotocol.com.

**Layer stack (bottom → top):**

1. **SSH** — `SSHConnectionManager` uses Citadel for RSA key auth, optional jump host, then opens a PTY on the target running `opencan-daemon attach`. `SSHStdioTransport` (actor) wraps the PTY as an `ACPTransport` (protocol with `send()` and `messages` stream). The PTY read loop uses `defer { messageContinuation.finish() }` to ensure the message stream ends even if the loop throws. When the PTY dies, `transport.close()` is called so pending ACP requests are cancelled rather than hanging forever.

2. **JSON-RPC** — `JSONRPCFramer` (actor) buffers PTY bytes, skips non-JSON noise, extracts newline-delimited messages. `JSONRPCMessage` is the envelope enum (request/response/notification/error). `JSONValue` is a generic JSON type with subscript access.

3. **Daemon** — `opencan-daemon` is a Go binary running on the remote server. It manages ACP process lifecycles independently of SSH connections. The `attach` subcommand bridges stdin/stdout to a Unix socket (`~/.opencan/daemon.sock`). `daemon/` prefixed methods are handled by the daemon; all other methods are transparently forwarded to the appropriate ACP process based on `params.sessionId`. See `docs/daemon-architecture.md` for full protocol specification.

4. **ACP** — `ACPClient` (actor) correlates request IDs to continuations, dispatches notifications, filters PTY echoes via `sentRequestIds`, and auto-approves `session/request_permission`. `DaemonClient` (actor) wraps `ACPClient` for `daemon/` prefixed methods: `hello`, `session.create`, `session.attach`, `session.detach`, `session.list`, `session.kill`. `ACPService` provides typed methods for ACP passthrough: `sendPrompt`. `SessionUpdateParser` maps `session/update` notifications to `SessionEvent` cases.

5. **Persistence** — SwiftData models: `Node` (SSH host config + optional jump server), `Workspace` (remote cwd on a node), `Session` (ACP session tied to a workspace), `SSHKeyPair` (RSA key data). Cascade delete: Node → Workspaces → Sessions. Demo data seeded on first launch via `seedDemoDataIfNeeded()`.

6. **AppState** — `@MainActor @Observable` coordinator. `connect(workspace:)` establishes SSH + daemon with 30s timeout via `daemon/hello`. `createNewSession()` uses `daemon/session.create` (daemon spawns ACP process internally). `resumeSession()` uses `daemon/session.attach` with event replay from buffered events. `handleSessionEvent()` routes notifications to the message model. Creates new `ChatMessage` bubbles when text arrives after tool calls. `sendMessage()` provides user feedback on failure. `lastEventSeq` tracks per-session event sequence numbers for daemon replay.

7. **SwiftUI** — `ContentView` hosts a `NavigationStack` rooted at `NodeListView`. Drill-down: `NodeListView → WorkspaceListView → SessionPickerView → ChatView`. `SessionPickerView` shows daemon session states with colored badges (idle/prompting/draining/completed/dead). Messages render with MarkdownView. Tool calls are expandable cards with truncated output.

**Key protocol details:**
- iOS connects via `opencan-daemon attach` (not directly to `claude-agent-acp`). The daemon handles `initialize` + `session/new` internally during `daemon/session.create`.
- Client IDs start at 1000 to avoid collision with server-initiated request IDs. The daemon rewrites IDs when forwarding to ACP processes.
- PTY echoes every stdin write back on stdout. The framer parses these as messages; `ACPClient` filters them by checking `sentRequestIds`.
- `session/request_permission` is auto-approved by the daemon when no client is attached (draining state).
- Daemon forwards `session/update` notifications with `__seq` metadata for event sequence tracking.

**State flow for streaming:**
- `sendMessage()` creates a `ChatMessage(isStreaming: true)` and calls `session/prompt`.
- `session/update` notifications arrive as `agent_message_chunk`, `agent_message`, `tool_call`, `tool_call_update`, `thought`, `agent_thought_chunk`, `prompt_complete`.
- When a `tool_call` starts, the current message's `isStreaming` is set to false.
- When text arrives after tool calls, a new `ChatMessage` is created so text renders below tool cards.
- `promptComplete` sets all streaming messages to `isStreaming = false`.
- `lastAssistantMessage()` sets `isStreaming` to `isPrompting` (not hardcoded `true`) so notifications arriving outside a prompt (e.g., after `session/load`) don't leave stale spinners.
- `agent_thought_chunk` events are streamed as `thoughtDelta` with a `\n> ` prefix on the first chunk (matching the blockquote style of full `thought` events). An `isStreamingThought` flag tracks this across chunks.

**Scroll behavior:**
- `contentVersion` (debounced via 150ms `Task.sleep`) drives auto-scroll. The delay lets MarkdownView (UIKit-backed) finish async layout before `scrollTo` fires, avoiding scroll-past-content into blank space.
- `forceScrollToBottom` is set when the user sends a message — always scrolls to bottom regardless of current position.
- `isNearBottom` (tracked via `onAppear`/`onDisappear` of a bottom anchor view) controls idle-mode scroll: only auto-scroll if user is already near the bottom.
- During active prompting (`isPrompting`), always follow new content.
- All `scrollTo` calls use `anchor: .bottom` to prevent the target view from being placed at the top of the viewport.
- **Known limitation:** SwiftUI's `ScrollView` + `LazyVStack` + `scrollTo` can still occasionally overshoot because lazy views have estimated heights. A full fix would require a custom UIKit-based list view (like FlowDown's `ListViewKit.ListView`).

## Conventions

- **SwiftData** for persistent config (`Node`, `Workspace`, `Session`, `SSHKeyPair`).
- **Actors** for thread-safe protocol state (`ACPClient`, `JSONRPCFramer`, `SSHStdioTransport`).
- **`@MainActor @Observable`** for UI state (`AppState`, `ChatMessage`).
- **`AsyncStream`** for message/notification pipelines.
- **`Log.toFile()`** for debugging on simulator (os_log doesn't reliably surface `print()` output). Use `xcrun devicectl device copy from` to pull logs from real devices.
- **XcodeGen** (`project.yml`) generates the `.xcodeproj`. Run `xcodegen generate` after adding files.
- **UI Tests** (`OpenCANUITests`) verify navigation, session creation (system message appears), message sending (user message + assistant response), session resume, and loading state. E2E tests require the real cp32 server and use `XCTSkip` when unreachable.

**Daemon architecture:**
- `opencan-daemon/` contains the Go daemon source. See `docs/daemon-architecture.md` for full design.
- **Auto-deploy:** On first connect, `SSHConnectionManager.ensureDaemonInstalled()` checks for `~/.opencan/bin/opencan-daemon` on the server. If missing, uploads the linux-amd64 binary from the iOS app bundle via SFTP. Rebuild with `cd opencan-daemon && make install-ios` after daemon changes.
- ACPProxy state machine: Starting → Idle → Prompting → Draining → Completed → Dead.
- EventBuffer: ring buffer (max 10000) with sequence numbers for reconnect replay.
- `daemon/session.attach` returns buffered events since `lastEventSeq`; iOS replays them through `SessionUpdateParser`.
- `Node.command` field stores the ACP binary name (default: "claude-agent-acp"); SSH command is always `opencan-daemon attach`.
