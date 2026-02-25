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
```

No test target exists yet. No linter is configured.

## Architecture

OpenCAN is an iOS ACP (Agent Client Protocol) client that connects to `claude-agent-acp` over SSH. The protocol is JSON-RPC 2.0 over newline-delimited stdio, per the spec at agentclientprotocol.com.

**Layer stack (bottom → top):**

1. **SSH** — `SSHConnectionManager` uses Citadel for RSA key auth, optional jump host, then opens a PTY on the target. `SSHStdioTransport` (actor) wraps the PTY as an `ACPTransport` (protocol with `send()` and `messages` stream).

2. **JSON-RPC** — `JSONRPCFramer` (actor) buffers PTY bytes, skips non-JSON noise, extracts newline-delimited messages. `JSONRPCMessage` is the envelope enum (request/response/notification/error). `JSONValue` is a generic JSON type with subscript access.

3. **ACP** — `ACPClient` (actor) correlates request IDs to continuations, dispatches notifications, filters PTY echoes via `sentRequestIds`, and auto-approves `session/request_permission`. `ACPService` provides typed methods: `initialize`, `createSession`, `sendPrompt`. `SessionUpdateParser` maps `session/update` notifications to `SessionEvent` cases.

4. **AppState** — `@MainActor @Observable` coordinator. Owns the connection lifecycle, chat messages, and notification listener. `handleSessionEvent()` routes events to the message model. Creates new `ChatMessage` bubbles when text arrives after tool calls.

5. **SwiftUI** — `ContentView` switches between `ConnectionView` and `ChatView`. Messages render with MarkdownUI. Tool calls are expandable cards with truncated output.

**Key protocol details:**
- Client initiates `initialize` (not the server). Client IDs start at 1000 to avoid collision with server-initiated request IDs (0, 1, 2...).
- PTY echoes every stdin write back on stdout. The framer parses these as messages; `ACPClient` filters them by checking `sentRequestIds`.
- `session/request_permission` must respond with `{ outcome: { outcome: "selected", optionId: "..." } }`, not `{ approved: true }`.
- `session/new` requires an existing directory as `cwd` on the remote server.

**State flow for streaming:**
- `sendMessage()` creates a `ChatMessage(isStreaming: true)` and calls `session/prompt`.
- `session/update` notifications arrive as `agent_message_chunk`, `agent_message`, `tool_call`, `tool_call_update`, `thought`, `prompt_complete`.
- When a `tool_call` starts, the current message's `isStreaming` is set to false.
- When text arrives after tool calls, a new `ChatMessage` is created so text renders below tool cards.
- `promptComplete` sets all streaming messages to `isStreaming = false`.

## Conventions

- **Actors** for thread-safe protocol state (`ACPClient`, `JSONRPCFramer`, `SSHStdioTransport`).
- **`@MainActor @Observable`** for UI state (`AppState`, `ChatMessage`).
- **`AsyncStream`** for message/notification pipelines.
- **`Log.toFile()`** for debugging on simulator (os_log doesn't reliably surface `print()` output).
- **XcodeGen** (`project.yml`) generates the `.xcodeproj`. Run `xcodegen generate` after adding files.
- Auto-connect is enabled in `ConnectionView.onAppear` for faster iteration.
