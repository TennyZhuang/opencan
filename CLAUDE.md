# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is a symlink to this file, so keep this document current.

## Build & Run

```bash
# Generate Xcode project from project.yml (required after adding/removing files)
xcodegen generate

# Build for iOS Simulator
xcodebuild -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -quiet build

# Note: OpenCAN target has post-build scripts that cross-compile the
# daemon into the app bundle as opencan-daemon-linux-amd64 when daemon
# sources change, and stamp source repository + git revision metadata
# into the built app Info.plist for About/Licenses disclosure.
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

# Local SSH-backed UI integration smoke test (starts local sshd + seeds env)
OPENCAN_INTEGRATION_TEST_MODE=smoke ./Scripts/run-local-integration.sh

# Run full UI integration suite
OPENCAN_INTEGRATION_TEST_MODE=full ./Scripts/run-local-integration.sh
```

App logs are JSON lines (`LogEntry`). Daemon logs are also structured JSON and live on the remote host at `~/.opencan/daemon.log` (size-rotated at 10MB with `daemon.log.1` through `daemon.log.3`).

Local integration harness notes:
- `run-local-integration.sh` writes a temporary `.env.integration.*` file and exports `OPENCAN_TEST_DOTENV_PATH`; it does not overwrite your existing `.env`.
- Default smoke selector is `OpenCANUIIntegrationTests.testIntegrationSmoke`; override with `OPENCAN_INTEGRATION_SMOKE_TEST=<TestMethodName>`.
- `setup-local-ssh.sh` appends a reusable test key to `~/.ssh/authorized_keys` and prints a cleanup command.
- If you run `xcodebuild test` manually (without the script), start local sshd first (`/usr/sbin/sshd -f .local-ssh/sshd_config`) or integration UI tests may skip/fail before workspace selection.

No linter is configured. UI test targets (`OpenCANUITests`, `OpenCANUIIntegrationTests`) exist in `project.yml`.

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

3. **Daemon** - `opencan-daemon` is a Go process on the remote server that owns ACP process lifecycle independent of SSH. `attach` bridges stdio to `~/.opencan/daemon.sock`. `daemon/` methods are handled locally (`hello`, `agent.probe`, `conversation.create`, `conversation.open`, `conversation.detach`, `conversation.list`, `session.list`, `session.kill`, `logs`). Non-`daemon/` ACP requests are forwarded to the currently attached runtime, but the daemon rewrites upstream ACP `sessionId` parameters to the stable `conversationId` when a restored runtime has a different `runtimeId`.

4. **ACP** - `ACPClient` (actor) correlates request IDs, handles cancellation, dispatches notifications, filters PTY echoes via `sentRequestIds`, and auto-approves `session/request_permission`. `sendRequest()` injects `_meta.traceId` into object/nil params. `DaemonClient` provides typed daemon wrappers, including agent probe and daemon log fetch. `ACPService` wraps ACP passthrough for prompting with structured prompt blocks (`PromptBlock.text`, `PromptBlock.resourceLink`). `SessionUpdateParser` maps `session/update` notifications to `SessionEvent`.

5. **Persistence** - SwiftData models: `Node` (SSH host + optional jump server), `Workspace` (remote cwd), `Session` (local conversation record + agent metadata), `SSHKeyPair` (RSA key data). `Session` persists the stable conversation identity together with the most recent known runtime ID, `conversationCwd`, `agentID`, and `agentCommand`; daemon runtimes themselves remain ephemeral. Cascade delete: Node -> Workspaces -> Sessions.

6. **Conversation lifecycle** - `ConversationLifecycle`, `ConversationPersistence`, and `PromptLifecycle` own conversation open/recover flows, prompt terminal-state handling, and local session persistence updates. `openSession(conversationId:)` is the single reopen/recover path: it reuses an existing managed runtime via `daemon/conversation.open`, restores from daemon-owned history when needed, or marks the conversation unavailable when daemon reports it missing/unrecoverable. Before switching sessions, the lifecycle detaches the prior conversation via `daemon/conversation.detach`. `lastEventSeq` tracks replay cursors per runtime. `sendMessage()` supports image mentions (`@img_xxx`) by turning referenced uploads into ACP `resource_link` prompt blocks. If a conversation reopens in `starting` / `prompting` / `draining`, the app preserves the busy state and serializes new sends through a small active-conversation queue instead of overlapping ACP prompt turns. Prompt completion still settles from `prompt_complete`, prompt error, or prompt success fallback.

7. **AppState** - `@MainActor @Observable` coordinator. `connect(node:)` establishes SSH + daemon with 30s timeout (`daemon/hello`). `refreshAvailableAgents()` probes launcher availability and marks reliability (`hasReliableAgentAvailability`). AppState persists a stable per-install `daemonAttachClientID` in `UserDefaults` and sends it as `ownerId` on `daemon/conversation.open` / `daemon/conversation.create` so reconnects can reclaim ownership from stale transports. Unexpected transport exits call `markTransportInterrupted(...)` to preserve active node/workspace/session context while clearing runtime transport state; `recoverInterruptedSessionIfNeeded(...)` provides the reconnect primitive used by `ChatView`'s active overlay retry loop and re-entry recovery hooks.

8. **SwiftUI/UIKit hybrid UI** - `ContentView` hosts `NavigationStack`: `NodeListView -> WorkspaceListView -> SessionPickerView -> ChatView`. Connection scope is node-level at `WorkspaceListView`. `NodeListView` gear menu includes **About & Licenses**, **Agent Settings**, and **Diagnostics**. `SessionPickerView` merges daemon + local sessions into `UnifiedSession`, applies workspace path normalization (tilde/home aliases), and shows conversation-oriented state badges (`attached/ready/running/restorable/unavailable`), while still mapping legacy runtime snapshots when needed. `ChatMessageListView` uses ListViewKit (FlowDown-style timeline) for stable streaming updates; `InputBarView` supports PhotosPicker uploads and `@mention` autocomplete. `ChatView` shows a reconnecting overlay and keeps retrying interrupted-session recovery while the app stays active, in addition to recovery on `onAppear` and when scene phase returns to active. `--uitesting-integration` implies UI testing mode, but `WorkspaceListView` still takes the real SSH path for integration runs (`isUITesting && !isUIIntegrationTesting` gate).

**Key protocol details:**
- iOS connects through `opencan-daemon attach`, not directly to ACP binaries.
- Client request IDs start at 1000; daemon rewrites server-initiated request IDs per client handler to avoid collisions across proxies.
- PTY echoes stdin writes on stdout; `ACPClient` ignores echoed requests by request ID.
- Trace correlation uses `_meta.traceId` on requests; daemon extracts it into slog context.
- `session/request_permission` is auto-approved when no client is attached (draining mode).
- Daemon forwards `session/update` notifications with `__seq`; iOS persists replay cursors against the active conversation/runtime pair.
- `daemon/conversation.open` is single-owner with `ownerId` reclaim semantics: one attached client per managed runtime, but a reconnect with the same `ownerId` can atomically transfer ownership from a stale connection.
- `daemon/session.list` is a runtime-oriented diagnostic endpoint and supports optional `cwd` scoping for external history discovery.
- `daemon/agent.probe` checks configured launcher commands on the remote host.
- `daemon/logs` returns recent in-memory structured daemon logs (optional `traceId` filter).

**State flow for prompting/streaming:**
- `sendMessage()` creates user + streaming assistant rows and sends `session/prompt`.
- If the active conversation is still busy, `sendMessage()` queues the follow-up on the current conversation instead of issuing a second overlapping ACP prompt turn.
- Prompt payload can include text plus `resource_link` blocks for referenced uploaded images.
- `session/update` includes `agent_message_chunk`, `agent_message`, `tool_call`, `tool_call_update`, `thought`, `agent_thought_chunk`, `user_message_chunk`, `prompt_complete`.
- When tool calls start, current assistant text bubble stops streaming; later text continues in a new assistant bubble.
- `prompt_complete` clears assistant spinners, ends prompting state, and refreshes daemon session snapshot.
- Fallback: prompt response success/error also clears prompting state if `prompt_complete` is missing.
- Reopen/reconnect into `starting` / `prompting` / `draining` restores local busy state unless replay already includes `prompt_complete`.
- Thought updates are intentionally not rendered in chat to avoid Markdown re-layout flicker under heavy streaming.

## Message Delivery Contract (Normative)

This is the end-to-end contract for "agent output reaches UI" and is treated as a regression boundary.

1. **Prompt lifecycle must terminate:** every `session/prompt` must drive daemon/UI out of running state via at least one terminal signal:
   - `session/update` with `sessionUpdate: "prompt_complete"`, or
   - JSON-RPC error response for `session/prompt`, or
   - JSON-RPC success response for `session/prompt` (fallback when `prompt_complete` is missing).
2. **No stale daemon running state:** after a terminal prompt signal, daemon state must not remain `prompting`/`draining`; it transitions to `idle` (attached client) or `completed` (detached/draining).
3. **Delivery + replay ordering:** forwarded `session/update` notifications carry `__seq`; `daemon/conversation.open(lastEventSeq, lastRuntimeId)` replays buffered events with `seq > lastEventSeq` in order, or resets replay when the runtime changes during restore.
4. **Scoped UI application:** AppState applies updates only for the active chat runtime, with `conversationId` used as a sanity check rather than a replacement for runtime scoping.
5. **Renderable output guarantee:** assistant/user/tool updates must mutate `AppState.messages` so visible transcript content survives live streaming and replay.

**Contract regression tests to keep green:**
- Daemon: `TestRouteResponse_PromptSuccessClearsRunningState`, `TestRouteResponse_PromptSuccessClearsDrainingStateWithoutClient`, `TestDaemon_PromptResponseWithoutPromptCompleteStillEndsPrompting`, `TestDaemon_LogsEndpointSupportsTraceFiltering`.
- iOS AppState: `testNewSessionSendMessage`, `testSendMessageWithoutPromptCompleteStillClearsPrompting`, `testIgnoresNotificationsFromOtherSessions`, `testOpenDrainingConversationPromptCompleteInBuffer`, `testOpenMissingSessionMarksDeadDirectly`, `testOpenSessionUsesConversationOpenForRestorableConversation`, `testSendMessageWithImageMentionAddsResourceLinkPromptBlock`.
- iOS ACP/Session helpers: `ACPClientTests` trace-id/cancellation coverage and `SessionPickerPathMatchingTests` path normalization coverage.

**Chat list/scroll behavior:**
- `AppState.contentDidChange()` uses throttle-with-trailing behavior (max cadence ~300ms, plus trailing 150ms debounce) before bumping `contentVersion`.
- `ChatMessageListView` follows content when prompting or when already near bottom (`nearBottomTolerance = 2`).
- `forceScrollToBottom` in AppState increments `forceScrollToken` in `ChatView` to force jumps after user send/prompt completion.
- ListViewKit timeline + explicit height caching avoids old SwiftUI `LazyVStack` overscroll drift and improves streaming stability.

## Refactor Learnings & Debugging Guardrails

- **Treat identities strictly:** `conversationId` is the durable product identity, `runtimeId` is only for live attachment/replay, and `ownerId` is the reconnect-reclaim identity. Do not persist `runtimeId` as authority or build UX logic on top of raw runtime IDs.
- **Use the right daemon surface:** product flows use `daemon/conversation.create|open|detach|list`; `daemon/session.list|kill` are diagnostic/runtime tools only. If a feature proposal needs `session.list` to work, double-check that it should not be conversation-based instead.
- **Restore bugs usually mean ID mismatch:** if history loads in UI but the next prompt has no context, first verify the `conversationId -> runtimeId` mapping at prompt dispatch and confirm the daemon forwards ACP `sessionId` using the stable conversation identity when talking to restored history.
- **Correlate with `traceId` first:** start with app `Documents/opencan.log`, then daemon `~/.opencan/daemon.log` or `daemon/logs`, and follow `traceId` across both sides before changing code. The fastest path is usually: `open/create` input log -> applied open result -> prompt dispatch mapping -> daemon trace-filtered logs.
- **Real-device issues need real-device logs:** simulator success is not enough for mobile transport bugs. Pull `Documents/opencan.log` with `xcrun devicectl` and compare it with daemon logs for the same `traceId`.
- **Log lifecycle boundaries, not branch trivia:** if you need more observability, log create/open/detach/recover/prompt boundaries with `conversationId`, `runtimeId`, `ownerId`, and restore/reuse flags together instead of sprinkling branch-local debug prints.
- **Prefer contract tests over branch snapshots:** protect prompt termination, replay ordering, reopen semantics, restore behavior, and cross-session filtering. Avoid adding tests that only preserve temporary migration branches or compatibility shims we do not intend to keep.
- **Keep mocks and docs tight:** remove unused compatibility behavior from mocks, and when conversation/runtime ownership or daemon APIs change, update `CLAUDE.md`, `README.md`, and `docs/daemon-architecture.md` in the same patch so future agents do not resurrect removed interfaces.

## Conventions

- **Testing strategy:** `docs/testing-strategy.md` records what to test at each layer, what the current suite covers, and which regressions are worth adding next.
- **Open source release notes:** `docs/open-source-release.md` records the repository license choice, provenance audit findings, source-availability policy, and release checklist.

- **SwiftData** for persistent host/workspace/session/key configuration.
- **Actors** for protocol and transport state (`ACPClient`, `JSONRPCFramer`, `SSHStdioTransport`, `SSHConnectionManager`).
- **`@MainActor @Observable`** for UI state (`AppState`, `ChatMessage`).
- **`AsyncStream`** for notifications and transport message pipelines.
- **Structured logging:** prefer `Log.log(...)` and `Log.timed(...)` (JSON lines + in-memory ring buffer). `Log.toFile(...)` remains for legacy call sites.
- **Diagnostics:** `DiagnosticView` can inspect iOS log ring buffer, fetch daemon logs (`daemon/logs`), inspect state snapshot, and generate a shareable JSON diagnostics bundle containing app/daemon log files, ring-buffer snapshots, and log storage metadata.
- **XcodeGen** (`project.yml`) generates `.xcodeproj`; run `xcodegen generate` after file list changes.
- **Unit tests:** `AppStateTests` cover agent probing/fallback, image mention prompts, single-owner conversation reopen behavior, interrupted-session auto reconnect paths, detach-before-switch, cross-session filtering, dead-conversation handling, and empty-runtime pruning.
- **Other tests:** `ACPClientTests`, `SessionPickerPathMatchingTests`, `SessionUpdateParserTests`, `JSONRPCMessageTests`.
- **UI tests** (`OpenCANUITests`) cover mock-backed navigation, conversation creation, sending, reopening, and loading state. SSH/daemon end-to-end coverage lives in `OpenCANUIIntegrationTests` (connect/create/send/reopen flows). `testIntegrationSmoke` is the stable smoke entrypoint used by `run-local-integration.sh`.

**Daemon architecture:**
- `opencan-daemon/` contains the Go daemon source. See `docs/daemon-architecture.md` for protocol/lifecycle details.
- **Auto-deploy:** `SSHConnectionManager.ensureDaemonInstalled()` uploads bundled `opencan-daemon-linux-amd64` when remote hash mismatches.
- Daemon startup uses `slog.NewJSONHandler` and writes to `~/.opencan/daemon.log` (plus stderr in true foreground mode), with runtime size rotation at 10MB and retention of `daemon.log.1` through `daemon.log.3`.
- Daemon logs are mirrored into an in-memory `LogRingBuffer` (default 2000 entries) via `BufferingHandler`, exposed by `daemon/logs`.
- ACPProxy state machine: `Starting -> Idle -> Prompting -> Draining -> Completed -> Dead`, plus `External` for sessions discovered from ACP but unmanaged by daemon.
- `daemon/session.list` remains the runtime-oriented diagnostic view: it returns managed runtimes and external ACP history rows (up to 50), optionally scoped by cwd. External discovery falls back to probing ACP directly (commands from `OPENCAN_DISCOVERY_COMMANDS`, default `claude-agent-acp,codex-acp`) when no managed proxy is available.
- Event replay uses per-runtime `EventBuffer` instances (max 100000 in `ACPProxy`) with monotonic sequence numbers and copy-on-evict to avoid retaining old backing arrays.
- `daemon/conversation.open` returns buffered events since `lastEventSeq`; a second concurrent open is rejected unless it presents the same `ownerId` (same-owner reclaim).
- Idle timeout re-arms while sessions remain busy/draining so daemon exits only after no clients and all sessions settle.
- Agent launch commands are configured in Agent Settings (Claude/Codex defaults), validated through `daemon/agent.probe`, and used for new session creation.
