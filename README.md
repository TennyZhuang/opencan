# OpenCAN

An iOS client for the [Agent Client Protocol (ACP)](https://agentclientprotocol.com) that connects to `claude-agent-acp` over SSH. Chat with Claude through a native SwiftUI interface with streaming responses and tool call visualization.

## Features

- SSH connection with optional jump host support (RSA key auth via Citadel)
- Full ACP/JSON-RPC 2.0 protocol implementation over PTY stdio
- Streaming chat with real-time text chunks and tool call updates
- Expandable tool call cards showing name, input, output, and status
- Auto-permission approval for seamless agent interaction
- Markdown rendering via MarkdownUI

## Requirements

- iOS 17.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A running `claude-agent-acp` server accessible via SSH

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
SIM=<your-simulator-udid>  # e.g. xcrun simctl list devices | grep Booted
APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenCAN-*/Build/Products/Debug-iphonesimulator \
  -name "OpenCAN.app" -maxdepth 1 | head -1)

xcrun simctl install $SIM "$APP"
xcrun simctl launch $SIM com.tianyizhuang.OpenCAN
```

### Reading Logs

`print()` doesn't reliably show in simulator system logs. The app writes to a file instead:

```bash
CONTAINER=$(xcrun simctl get_app_container $SIM com.tianyizhuang.OpenCAN data)
cat "$CONTAINER/Documents/opencan.log"
```

Alternatively, open the project in Xcode (`open OpenCAN.xcodeproj`) and run from there.

## Architecture

Five-layer stack, bottom to top:

| Layer | Key Types | Role |
|-------|-----------|------|
| SSH | `SSHConnectionManager`, `SSHStdioTransport` | RSA key auth, optional jump host, PTY channel |
| JSON-RPC | `JSONRPCFramer`, `JSONRPCMessage`, `JSONValue` | Newline-delimited JSON-RPC 2.0 framing |
| ACP | `ACPClient`, `ACPService`, `SessionUpdateParser` | Request/response correlation, notification dispatch, echo filtering |
| AppState | `AppState`, `ChatMessage` | Observable state coordinator, streaming lifecycle |
| SwiftUI | `ContentView`, `ChatView`, `ToolCallView` | Connection setup, chat UI, tool call cards |

### Protocol Notes

- Client initiates `initialize` (not the server)
- Client request IDs start at 1000 to avoid collision with server-initiated IDs
- PTY echoes are filtered by tracking sent request IDs
- Permission requests auto-approve by selecting the first "allow" option

## Project Structure

```
Sources/
├── OpenCANApp.swift          # App entry point
├── AppState.swift            # Root state coordinator (@Observable)
├── ACP/                      # Agent Client Protocol layer
├── JSONRPC/                  # JSON-RPC 2.0 implementation
├── Transport/                # SSH PTY transport
├── Services/                 # SSH connection management
├── Models/                   # ChatMessage, ServerConfig, ACPTypes
├── Views/                    # SwiftUI interface
└── Utils/                    # Logging, theme
```

## Dependencies

- [Citadel](https://github.com/orlandos-nl/Citadel) — SSH client for Swift
- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) — Markdown rendering

## License

TBD
