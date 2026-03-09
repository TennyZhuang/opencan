# OpenCAN

An iOS client for the [Agent Client Protocol (ACP)](https://agentclientprotocol.com) that drives remote coding agents through a persistent daemon over SSH. It is designed for unstable mobile networks: the SSH connection may drop, but the remote conversation/runtime can survive and later be reopened from the phone.

## Features

- Persistent remote `opencan-daemon` that decouples agent/runtime lifetime from mobile SSH lifetime
- Conversation-oriented reopen/restore flow for agents started on phone or adopted later from another machine
- Full ACP / JSON-RPC 2.0 transport over SSH PTY stdio
- Streaming chat, tool call rendering, image mention uploads, and Markdown rendering
- Structured diagnostics in both the iOS app (`opencan.log`) and remote daemon (`~/.opencan/daemon.log`)
- Local SSH-backed integration harness for deterministic end-to-end testing on macOS

## Requirements

- iOS 17.0+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A reachable remote host with an ACP launcher command (for example `claude-agent-acp` or `codex-acp`)

## Build & Run

```bash
# Generate the Xcode project from project.yml
xcodegen generate

# Build for iOS Simulator
xcodebuild -scheme OpenCAN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build
```

### Install on Simulator

```bash
SIM=<your-simulator-udid>
APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenCAN-*/Build/Products/Debug-iphonesimulator \
  -name "OpenCAN.app" -maxdepth 1 | head -1)

xcrun simctl install "$SIM" "$APP"
xcrun simctl terminate "$SIM" com.tianyizhuang.OpenCAN 2>/dev/null
xcrun simctl launch "$SIM" com.tianyizhuang.OpenCAN
```

### Logs & Diagnostics

App logs are written to the sandbox rather than the simulator system log:

```bash
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.tianyizhuang.OpenCAN data)
cat "$CONTAINER/Documents/opencan.log"
```

Copy logs from a real device:

```bash
DEVICE=<device-udid>
xcrun devicectl device copy from --device "$DEVICE" \
  --source Documents/opencan.log --destination /tmp/opencan.log \
  --domain-type appDataContainer --domain-identifier com.tianyizhuang.OpenCAN
```

Remote daemon logs live at `~/.opencan/daemon.log` and rotate to `daemon.log.prev`.

### Local Integration Harness

Run the end-to-end SSH + daemon + mock ACP smoke suite locally:

```bash
OPENCAN_INTEGRATION_TEST_MODE=smoke ./Scripts/run-local-integration.sh
```

Run the full integration target:

```bash
OPENCAN_INTEGRATION_TEST_MODE=full ./Scripts/run-local-integration.sh
```

See `docs/local-integration-testing.md` for setup details.

## Architecture

OpenCAN now uses a daemon-owned conversation/runtime model.

| Layer | Key Types | Role |
|-------|-----------|------|
| SSH | `SSHConnectionManager`, `SSHStdioTransport` | RSA key auth, optional jump host, PTY channel, daemon auto-deploy |
| JSON-RPC | `JSONRPCFramer`, `JSONRPCMessage`, `JSONValue` | Newline-delimited JSON-RPC 2.0 framing |
| Daemon | `opencan-daemon`, `ClientHandler`, `SessionManager`, `ACPProxy` | Conversation registry, runtime lifecycle, replay, restore, diagnostics |
| ACP | `ACPClient`, `DaemonClient`, `ACPService`, `SessionUpdateParser` | Request correlation, daemon RPCs, ACP passthrough, notification parsing |
| Conversation | `ConversationLifecycle`, `ConversationPersistence`, `PromptLifecycle` | Conversation open/recover flows, local session sync, prompt terminal-state handling |
| AppState | `AppState`, `ChatMessage` | UI-facing coordinator, connection state, transcript state, and navigation context |
| SwiftUI | `ContentView`, `SessionPickerView`, `ChatView`, `DiagnosticView` | Navigation, picker, chat UX, diagnostics UI |

### Core identities

- `conversationId`: stable identity persisted by the app and used to reopen chat history
- `runtimeId`: ephemeral daemon-managed live runtime identity used for attachment and replay
- `ownerId`: stable per-install client identity used for same-owner reclaim after reconnect

### Protocol notes

- iOS connects to `opencan-daemon attach`, not directly to ACP launchers
- `daemon/conversation.create|open|detach|list` are the product-facing lifecycle APIs
- `daemon/session.list|kill` remain low-level diagnostic/operational APIs
- Forwarded `session/update` notifications include `__seq`, `conversationId`, and `runtimeId`
- On restored conversations, daemon routes by `runtimeId` internally but forwards upstream ACP requests with the stable wire `sessionId = conversationId`; using `runtimeId` on the ACP wire loses history context
- Prompt termination must be observable via `prompt_complete`, prompt error, or prompt success fallback
- App-side follow-up sends stay serial with ACP turns: if a conversation is reopened in `starting` / `prompting` / `draining`, the app keeps the session busy and queues new user sends on the active conversation until the turn settles

For the current implemented contract, see `docs/daemon-architecture.md` and `CLAUDE.md`. `docs/conversation-runtime-refactor.md` remains useful as design background, not the canonical source for current behavior.

## Project Structure

```text
Sources/
├── AppState.swift            # Main app coordinator and transcript state
├── ACP/                      # ACP client, daemon client, prompt helpers
├── JSONRPC/                  # JSON-RPC framing and generic JSON values
├── Models/                   # SwiftData models and daemon DTOs
├── Services/                 # SSH connection management and deployment
├── Transport/                # SSH PTY transport
├── Views/                    # SwiftUI/UIKit hybrid UI
└── Utils/                    # Structured logging and utilities

opencan-daemon/
├── cmd/                      # Daemon entrypoint
├── internal/                 # Conversation registry, protocol router, ACP proxy
└── test/                     # Daemon integration / contract tests

Scripts/
├── run-local-integration.sh  # Local SSH-backed integration harness
└── setup-local-ssh.sh        # Local sshd setup for integration tests
```

## Dependencies

- [Citadel](https://github.com/orlandos-nl/Citadel) — SSH client for Swift
- [MarkdownView](https://github.com/Lakr233/MarkdownView) — Markdown rendering
- [ListViewKit](https://github.com/Lakr233/ListViewKit) — stable streaming chat timeline rendering

## Acknowledgements

- OpenCAN's chat timeline UI direction was informed by [FlowDown](https://github.com/Lakr233/FlowDown) by Lakr233.
- OpenCAN uses [ListViewKit](https://github.com/Lakr233/ListViewKit) and [MarkdownView](https://github.com/Lakr233/MarkdownView), which are maintained by Lakr233 and are used directly in the app.
- FlowDown's repository currently states that its source code is AGPL-3.0, while the FlowDown name, icon, and artwork remain proprietary. OpenCAN does not claim rights to those brand assets.
- See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for dependency license texts and attribution notes.

## License

Copyright (C) 2026 TennyZhuang.

OpenCAN is released under the GNU Affero General Public License v3.0 or later. See [LICENSE](./LICENSE).

If you distribute binaries of OpenCAN or make a modified networked deployment of `opencan-daemon` available to users, you are responsible for providing the corresponding source and keeping the required legal notices visible.

See [docs/open-source-release.md](./docs/open-source-release.md) for the current provenance audit, source-availability policy, and release checklist.
