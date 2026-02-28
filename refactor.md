# Refactor Plan (Daemon-First)

Last updated: 2026-02-28

## Goal
Refactor daemon-side internals using third-party libraries **only when** they reduce maintenance burden without adding hacks or verbosity.

Preferred trial order:
1. `jrpc2`
2. `go-daemon`
3. `lockfile`
4. `deque`

## Required Per-Refactor Workflow
For every replacement attempt, follow this exact sequence:

1. Improve test coverage for related logic; pass tests; commit.
2. Create a dedicated branch.
3. Implement with the new dependency.
4. Pass tests (only minor test changes allowed in this phase).
5. If tests pass, commit. If hard to implement cleanly, revert whole change.
6. Review the replacement quality. Reject if hacky or more verbose.
7. If accepted, merge branch, then move to next refactor.

## Global Guardrails (Must Preserve)
- JSON-RPC and session behavior contract in `CLAUDE.md`.
- `__routeToSession` routing behavior for `session/load`.
- Server-request ID rewrite/restore logic (multi-proxy safety).
- Event replay semantics (`__seq`, ordered replay after `lastEventSeq`).
- Prompt lifecycle completion fallback behavior when `prompt_complete` is missing.

## Existing Contract Tests (Must Stay Green)
Daemon:
- `TestRouteResponse_PromptSuccessClearsRunningState`
- `TestRouteResponse_PromptSuccessClearsDrainingStateWithoutClient`
- `TestDaemon_PromptResponseWithoutPromptCompleteStillEndsPrompting`

iOS:
- `testNewSessionSendMessage`
- `testSendMessageWithoutPromptCompleteStillClearsPrompting`
- `testIgnoresNotificationsFromOtherSessions`
- `testResumeDrainingPromptCompleteInBuffer`
- `testResumeHistorySession`

## Baseline Targets by Replacement

### 1) jrpc2 (highest risk/highest leverage)
**Candidate:** https://github.com/creachadair/jrpc2

**Current code likely affected:**
- `opencan-daemon/internal/protocol/jsonrpc.go`
- `opencan-daemon/internal/daemon/client_handler.go`
- `opencan-daemon/internal/proxy/acp_proxy.go`

**Pre-implementation test focus to add:**
- Non-JSON/PTY-noise line tolerance.
- `result: null` and error payload pass-through.
- Response routing under rewritten IDs with multiple attached proxies.
- `session/load` with and without `__routeToSession`.

**Accept if:** less custom JSON-RPC plumbing and cleaner routing.

**Reject if:** adapters become more complex than current custom layer.

---

### 2) go-daemon
**Candidate:** https://github.com/sevlyar/go-daemon

**Current code likely affected:**
- `opencan-daemon/internal/attach/attach.go`
- `opencan-daemon/internal/daemon/daemon.go`
- `opencan-daemon/cmd/opencan-daemon/main.go`

**Pre-implementation test focus to add:**
- Daemon start/stop/idempotency behavior.
- Socket/PID lifecycle safety around restarts.
- Attach flow still emits `daemon/attached` notification correctly.

**Accept if:** process management simplifies with fewer edge-case branches.

**Reject if:** signal handling, SSH attach behavior, or startup reliability regresses.

---

### 3) lockfile
**Candidate:** https://github.com/nightlyone/lockfile

**Current code likely affected:**
- PID handling around daemon startup/shutdown.

**Pre-implementation test focus to add:**
- Stale PID/lock handling.
- Concurrent start attempts (single-owner daemon process).

**Accept if:** safer singleton daemon startup with simpler code.

**Reject if:** portability or stale-lock recovery becomes brittle.

---

### 4) deque
**Candidate:** https://github.com/gammazero/deque

**Current code likely affected:**
- `opencan-daemon/internal/proxy/event_buffer.go`

**Pre-implementation test focus to add:**
- Overflow eviction correctness.
- Replay ordering and monotonic sequence after many appends.
- Concurrent append/read behavior.

**Accept if:** buffer internals simplify while preserving sequence semantics.

**Reject if:** no meaningful simplification or replay clarity decreases.

## Branch and Commit Convention
- Branch: `refactor/<dependency>-trial` (example: `refactor/jrpc2-trial`)
- Commits per trial:
  1. `test(daemon): expand coverage for <dependency> trial`
  2. `refactor(daemon): integrate <dependency> trial`
  3. optional: `revert: abandon <dependency> trial` (if rejected)

## Trial Log

### [Rejected] jrpc2
- Branch: `refactor/jrpc2-trial`
- Step-1 coverage commit (kept on `master`): `26f67bf`
- Trial integration commit (not merged): `51ed56c`
- Reason:
  - Integration only covered request/notification parsing path.
  - Required fallback to legacy parser for responses/errors, so complexity increased.
  - Net result was more adapter logic than simplification.
- Decision: reject and move to next trial (`go-daemon`).

### [Accepted] go-daemon
- Branch: `refactor/go-daemon-trial`
- Step-1 coverage commit (kept on `master`): `94acbe3`
- Trial integration commit (merged): `1075244`
- Validation:
  - `cd opencan-daemon && make test` ✅
  - `cd opencan-daemon && go test -v -race -timeout 60s ./test/` ✅
  - Smoke test with isolated `HOME`: `start -> status -> stop` lifecycle ✅
- Reason:
  - Removes ad-hoc detach logic (`setsid` + stdio null wiring) from `attach`.
  - Implements real background mode in `start` with a focused daemonization library.
  - Net code is cleaner and behavior is easier to test and reason about.
- Decision: accepted and merged; proceed to next trial (`lockfile`).

### [Accepted] lockfile
- Branch: `refactor/lockfile-trial`
- Step-1 coverage commit (kept on `master`): `91473f8`
- Trial integration commit (merged): `f75aabb`
- Validation:
  - `cd opencan-daemon && make test` ✅
  - `cd opencan-daemon && go test -v -race -timeout 60s ./test/` ✅
  - Smoke test with isolated `HOME`:
    - stale PID file recovery on startup ✅
    - repeated `start` keeps a single running daemon PID ✅
    - `stop` terminates owner and clears running status ✅
- Reason:
  - Replaces hand-rolled PID-file parsing/ownership checks with lockfile ownership API.
  - Enforces singleton daemon startup in `daemon.Run()` before socket bind.
  - Handles stale/invalid lock owners through library behavior, reducing custom edge-case logic.
- Decision: accepted and merged; proceed to next trial (`deque`).

### [Rejected] deque
- Branch: `refactor/deque-trial`
- Step-1 coverage commit (kept on `master`): `448f45f`
- Trial integration commit (not merged): `d51f5df`
- Validation:
  - `cd opencan-daemon && make test` ✅
  - `cd opencan-daemon && go test -v -race -timeout 60s ./test/` ✅
  - Replay smoke test (`session/prompt` + detach/reattach with `lastEventSeq`) ✅
- Reason:
  - The original ring-buffer implementation was already compact and clear.
  - Replacing with `gammazero/deque` did not materially reduce code or complexity.
  - Added dependency cost outweighed the small internal data-structure swap.
- Decision: reject and keep the existing custom event buffer implementation.

## Web-Searched Backlog (Not Yet Implemented)

### [Accepted] UI trial: `ListViewKit` chat timeline (FlowDown-style rows)
- Date: 2026-02-28
- Scope:
  - Replaced the previous hosted-SwiftUI row approach with UIKit-native `ListRowView` subclasses, aligned with FlowDown's MessageListView usage pattern.
  - Introduced dedicated row types:
    - user message gradient bubble row
    - assistant markdown row via `MarkdownTextView`
    - system hint row
    - tool status hint row
    - streaming activity row
  - Kept OpenCAN interaction semantics and data flow; changed timeline rendering internals only.
- Files:
  - `Sources/Views/ChatMessageListView.swift`
  - `Sources/Views/SessionPickerView.swift`
  - `Sources/OpenCANApp.swift`
  - `Sources/Mock/MockScenario.swift`
  - `UITests/OpenCANUITests.swift`
- Validation:
  - `xcodebuild -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -quiet build` ✅
  - `xcodebuild test -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:OpenCANUITests/OpenCANUITests/testSendMessageAndReceiveResponse -only-testing:OpenCANUITests/OpenCANUITests/testLongStreamingKeepsTailVisible` ✅
- Notes:
  - Added `MockScenario.longStream` and `--uitesting-long-stream` launch arg for repeatable long-stream scroll-follow regression checks.
  - Kept `SessionPickerView` in button mode for UI tests (no menu interaction) to preserve deterministic automation.
  - Trial judged acceptable: less hacky than hosted rows, better measurement predictability, and testable tail-follow behavior.

### UI candidate: `ListViewKit` (high priority for scroll stability)
- Repo: https://github.com/Lakr233/ListViewKit
- Why it matches this codebase:
  - Current `ChatView` explicitly documents SwiftUI `ScrollView + LazyVStack + scrollTo` overshoot risk.
  - `ListViewKit` positions itself as a glitch-free list replacement with smooth updates during content-size change.
- Potential scope:
  - Replace the message list container in `Sources/Views/ChatView.swift` only.
  - Keep current bubble/tool-call cells and theme to preserve UI consistency.
- Risk:
  - UIKit bridge integration cost; should be run as an isolated trial branch.

### UI candidate: `MarkdownUI` (medium priority, parser/rendering swap)
- Repo: https://github.com/gonzalezreal/swift-markdown-ui
- Why it may help:
  - Native SwiftUI markdown rendering and theming can reduce UIKit layout drift from current markdown view.
- Risk note from upstream:
  - Repository is in maintenance mode and points to `Textual` as the actively developed engine.
  - Should only be trialed if current markdown rendering remains a practical pain point.

### UI candidate: `Exyte/Chat` (low priority, likely too opinionated)
- Repo: https://github.com/exyte/Chat
- Why considered:
  - Rich, customizable chat primitives could reduce custom message-list/input scaffolding.
- Likely rejection reason:
  - High probability of style/interaction drift from current OpenCAN UX and more migration churn than benefit.

## Useful Commands

```bash
# daemon tests
cd opencan-daemon && make test
cd opencan-daemon && go test -v -race -timeout 60s ./test/

# iOS tests/build (if needed for cross-check)
xcodegen generate
xcodebuild -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -quiet build
```
