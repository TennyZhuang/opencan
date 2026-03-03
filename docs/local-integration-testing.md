# Local Integration Testing via macOS SSH Server

## Motivation

`OpenCANUIIntegrationTests.testIntegrationSendMessage` currently depends on an external SSH host. That makes failures hard to reproduce and blocks CI/local debugging when infra is unavailable.

This workflow runs the full stack against `localhost`:

- iOS app in simulator
- real SSH + PTY transport
- real `opencan-daemon`
- local `mock-acp-server`

## Implemented Design

### 1) Platform-aware daemon bundle selection (no Node schema change)

Instead of storing a `Node.platform`, the app detects remote platform at connect time (`uname -s`, `uname -m`) and selects a bundled daemon binary named:

- `opencan-daemon-linux-amd64`
- `opencan-daemon-linux-arm64`
- `opencan-daemon-darwin-amd64`
- `opencan-daemon-darwin-arm64`

If remote detection is unavailable, it falls back to `opencan-daemon-linux-amd64`.

### 2) Build script supports multiple bundled daemon targets

`Scripts/build-daemon-bundle.sh` now reads:

- `OPENCAN_DAEMON_BUNDLE_TARGETS` (comma/space/semicolon separated `os-arch` list)

Default:

- `linux-amd64`

Example for local integration on Apple Silicon:

- `linux-amd64,darwin-arm64`

The script builds `opencan-daemon-<target>` directly into the app bundle resources.

### 3) Integration seeding supports deterministic local agent command

`OpenCANApp` now reads optional:

- `OPENCAN_TEST_AGENT_COMMAND`

When present (and app launched with `--uitesting-integration`), seed logic sets:

- `agent.command.claude = OPENCAN_TEST_AGENT_COMMAND`
- `agent.default = claude`

This makes session creation and `daemon/agent.probe` use the local mock command consistently.

## Local Setup

Run once:

```bash
./Scripts/setup-local-ssh.sh
```

What it does:

- creates `.local-ssh/test_key` (RSA private key used by UITest seed)
- creates `.local-ssh/host_key` (isolated sshd host key)
- appends `test_key.pub` to `~/.ssh/authorized_keys`
- writes `.local-ssh/sshd_config` with key-only auth on `127.0.0.1:22222`
- configures `Subsystem sftp /usr/libexec/sftp-server` (required for daemon upload)

`.local-ssh/` is gitignored.

## .env for Local Integration

```bash
OPENCAN_TEST_NODE_NAME=local
OPENCAN_TEST_NODE_HOST=127.0.0.1
OPENCAN_TEST_NODE_PORT=22222
OPENCAN_TEST_NODE_USERNAME=<your-username>
OPENCAN_TEST_WORKSPACE_NAME=home
OPENCAN_TEST_WORKSPACE_PATH=/Users/<your-username>
OPENCAN_TEST_SSH_KEY_PATH=/absolute/path/to/repo/.local-ssh/test_key
OPENCAN_TEST_AGENT_COMMAND=$HOME/.opencan/bin/mock-acp-server
```

Notes:

- Prefer an absolute `OPENCAN_TEST_SSH_KEY_PATH`.
- Use an absolute `OPENCAN_TEST_WORKSPACE_PATH`; `~` is not shell-expanded by daemon session launch.

## One-command Local Integration Run

```bash
./Scripts/run-local-integration.sh
```

What it does:

1. Ensures local sshd config exists (`setup-local-ssh.sh` if missing)
2. Starts isolated sshd if not already running
3. Builds host-arch darwin binaries and installs:
   - `~/.opencan/bin/opencan-daemon`
   - `~/.opencan/bin/mock-acp-server`
4. Exports:
   - `OPENCAN_DAEMON_BUNDLE_TARGETS=linux-amd64,darwin-<local-arch>`
   - `OPENCAN_TEST_AGENT_COMMAND=~/.opencan/bin/mock-acp-server`
5. Runs:
   - `xcodebuild test -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:OpenCANUIIntegrationTests/OpenCANUIIntegrationTests/testIntegrationSendMessage`

If the script started sshd, it stops it on exit.

## Debugging

```bash
# daemon log on localhost
tail -f ~/.opencan/daemon.log

# app log from simulator container
SIM=<sim-udid>
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.tianyizhuang.OpenCAN data)
tail -f "$CONTAINER/Documents/opencan.log"
```

## Caveats

- macOS may require enabling **Remote Login** (System Settings > General > Sharing).
- Port `22222` is configurable via `OPENCAN_LOCAL_SSH_PORT` when running scripts.
- This validates local macOS-hosted SSH flows; it is not a substitute for Linux remote compatibility tests.
