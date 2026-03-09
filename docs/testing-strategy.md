# OpenCAN Testing Strategy

This document describes what “good tests” mean for OpenCAN, what the current suite already protects, and which gaps are worth filling next.

Use this document together with `CLAUDE.md` and `docs/daemon-architecture.md`.

## What makes a good test here

OpenCAN is not a CRUD app with a thin API boundary. The hard parts are:

- unstable mobile SSH transport
- daemon-owned runtime lifecycle that survives SSH disconnects
- durable `conversationId` versus ephemeral `runtimeId`
- single-owner attach/reclaim semantics via `ownerId`
- buffered event replay and prompt terminal-state settlement
- a UI that must stay responsive while the transport is unreliable

Because of that, the highest-value tests are the ones that protect **contracts and state transitions**, not implementation branches.

### Prefer these

- **Lifecycle contract tests**: prompt start -> updates -> terminal signal -> settled state
- **Identity tests**: `conversationId`, `runtimeId`, and `ownerId` each keep their role
- **Recovery tests**: disconnect, reconnect, reclaim, replay, restore, missing-session handling
- **Ordering/replay tests**: `__seq`, overflow, cursor reuse, runtime replacement
- **Focused smoke tests**: one short end-to-end path that proves the whole stack still works
- **Observability tests**: trace/log surfaces that make production debugging fast

### Avoid these

- tests that only lock in temporary migration branches
- tests that assert on incidental internal implementation details
- broad UI click-through tests that duplicate lower-layer coverage
- mocks that emulate removed APIs “just in case”

## Current coverage map

### iOS unit tests

`Tests/AppStateTests.swift` is the main product-contract suite. It currently protects:

- mock connection and workspace directory behavior
- agent probing and fallback selection
- conversation creation and prompt sending
- image mention prompt block generation
- prompt termination when `prompt_complete` is missing
- timeout/watchdog behavior and retry safety
- busy-session reopen and queued follow-up sends
- cross-session notification filtering
- conversation open/reopen for ready, running, draining, completed, missing, and restorable conversations
- detached-session recovery after unexpected transport interruption
- interrupted prompt recovery with buffered tail replay
- reconnect restore onto a replacement runtime and post-restore prompt continuity
- daemon session snapshot refresh and picker merge behavior

`Tests/ACPClientTests.swift` protects the JSON-RPC client boundary:

- `result: null` handling
- cancellation cleanup and request pipeline health
- notification stream termination when the transport ends
- `_meta.traceId` injection rules
- ACP error classification helpers

`Tests/SessionPickerPathMatchingTests.swift` protects workspace matching and conversation/runtime merging:

- trailing slash normalization
- tilde/home normalization
- collapse of recovered runtime rows onto a single stable conversation row
- preserving known local conversations even when daemon cwd metadata drifts

Additional smaller suites protect parsing and local persistence helpers:

- `Tests/SessionUpdateParserTests.swift`
- `Tests/JSONRPCMessageTests.swift`
- `Tests/TimeoutHelperTests.swift`
- `Tests/SSHKeyPairSecurityTests.swift`

### Daemon unit and integration tests

The Go daemon suite protects the runtime-side contract:

- JSON-RPC parsing and param rewriting
- attach/reclaim state machine semantics
- prompt terminal-state cleanup
- event buffer ordering, overflow, and snapshot safety
- log ring buffer and trace filtering
- `conversation.create`, `conversation.open`, `conversation.list`
- external conversation discovery and restore
- same-owner reclaim versus different-owner rejection
- stale owner pruning and idle-timeout behavior
- tail-only replay after disconnect using `lastEventSeq`
- buffered tool-call replay after disconnect
- same-owner reclaim while a prompt is still streaming
- lost `conversation.create` response still leaves a recoverable managed conversation
- lost `conversation.open` restore response can be retried onto the same restored runtime

The most important daemon tests are the ones that assert:

- prompting never stays stuck after a terminal signal
- reattach/reclaim preserves the single-owner rule
- restored conversations continue to use the stable conversation identity upstream
- buffered replay stays ordered and monotonic under overflow

### UI and integration tests

`UITests/OpenCANUITests.swift` covers the minimum mock-backed product flows:

- node/workspace navigation
- creating a conversation
- sending a message
- reopening a conversation
- long streaming scroll behavior

`UIIntegrationTests/OpenCANUIIntegrationTests.swift` covers the SSH-backed smoke path:

- connect to a real target
- reach session picker
- create a conversation
- send a message
- reopen from the session picker

These tests are intentionally few. Their job is to prove the stack still hangs together, not to exhaustively cover every lifecycle branch.

## Normative regression boundaries

The following behaviors should stay protected whenever the architecture changes:

1. **Prompt lifecycle terminates**
   - every prompt ends via `prompt_complete`, prompt success response, or prompt error response
2. **No stale running state**
   - daemon/UI do not remain stuck in `prompting` or `draining`
3. **Scoped delivery**
   - updates from other runtimes do not mutate the active chat
4. **Replay continuity**
   - replay uses monotonic sequence ordering and reopens from the correct cursor when the runtime is unchanged
5. **Identity discipline**
   - `conversationId` is durable, `runtimeId` is operational, `ownerId` is reclaim identity
6. **Recoverability**
   - transport interruption preserves enough context to reconnect and reopen the intended conversation
7. **Renderable transcript guarantee**
   - live streaming and replay both produce durable `AppState.messages`

## High-value gaps to fill next

These are the next tests worth adding before broadening the suite further.

### Tier 1: closest to real mobile failures

- reconnect after daemon must settle duplicate or overlapping reconnect attempts

### Tier 2: ownership and multi-device behavior

- phone attempts to open a conversation already attached by another owner
- same `ownerId` reclaim after stale transport eviction
- desktop-started conversation later opened on phone, with follow-up prompt preserving context
- old transport can no longer mutate the conversation after reclaim

### Tier 3: persistence and scale

- app relaunch after OS kill with recoverable conversation in SwiftData
- migration fixtures for old `Session` rows to current conversation-first model
- large transcript replay performance and correctness
- image resource mention behavior across reconnects and expired uploads

### Tier 4: observability

- key open/recover/prompt boundaries emit enough structured context for log correlation
- `traceId` is easy to follow across app and daemon logs for a single lifecycle

## TODO: ACP protocol realism follow-ups (2026-03-09)

This round of comparison against upstream `codex-acp` and `claude-agent-acp` found one confirmed protocol bug and a few high-value follow-ups. Keep these tracked as TODO items until the relevant coverage exists.

- TODO: add an end-to-end permission-interrupt flow where `session/request_permission` arrives mid-prompt, the client replies, and streaming continues with subsequent `tool_call` / `tool_call_update` / text updates.
- TODO: add a daemon or `AppState` regression that proves newer ACP tool statuses (`pending`, `in_progress`, `completed`, `failed`) are tolerated everywhere we consume tool events, not just in the parser and mocks.
- TODO: decide whether product surfaces should consume `current_mode_update`, `config_options_update`, `usage_update`, and `available_commands_update`; today we safely ignore them, but the UI has no visibility into these upstream state changes.
- TODO: keep local mocks aligned with upstream structured tool outputs (`rawOutput` as content blocks/JSON), because this mismatch previously hid a real bug where tool output text could be dropped from the visible transcript.

Note: the confirmed bug from this review was the structured `rawOutput` parsing gap. That parser issue is now fixed; the TODOs above are the remaining realism and coverage follow-ups.

## What to test at each layer

When adding a new regression test, prefer the cheapest layer that can prove the contract.

- **daemon unit test**: daemon state machine, replay, rewrite, owner semantics
- **iOS unit test**: `AppState` orchestration, transcript mutation, reconnect policy, UI-facing behavior
- **UI test**: view wiring, navigation, scroll, and visible user affordances
- **integration test**: one true-path proof that SSH + daemon + ACP still work together

A good rule: if a bug can be reproduced without rendering SwiftUI, it probably belongs in daemon or `AppState` tests, not UI tests.

## Practical heuristics for future changes

Before adding a test, ask:

- Is this protecting a user-visible contract?
- Is this one of the identities or lifecycle boundaries that routinely breaks?
- Will this still be valuable after the next refactor?
- Could a smaller lower-layer test prove the same thing faster and more deterministically?

If the answer is “no”, do not add the test.

## Recommended routine

For day-to-day development:

1. add or update the smallest lifecycle/contract test that proves the bug
2. run the focused suite for the touched layer
3. keep one SSH-backed smoke run green before merging large runtime changes
4. update `CLAUDE.md` / docs when the contract changes

Useful commands:

```bash
SKIP_DAEMON_BUNDLE_BUILD=1 xcodebuild test -scheme OpenCAN \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:OpenCANTests/AppStateTests \
  -only-testing:OpenCANTests/ACPClientTests \
  -only-testing:OpenCANTests/SessionPickerPathMatchingTests

cd opencan-daemon && go test ./...

OPENCAN_INTEGRATION_TEST_MODE=smoke ./Scripts/run-local-integration.sh
```
