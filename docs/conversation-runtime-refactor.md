# Plan: Daemon-Owned Conversation/Runtime Refactor

## Status

This document supersedes the narrower app-only split plan in `docs/refactor-resume-adopt-split.md`.
That split is still a valid stopgap, but it does not remove the main source of complexity:
**authority is still split across iOS, daemon, and ACP history state**.

## Why a bigger refactor

The current code has improved relative to the old dual-ID design, but it still carries the same core problem:

- iOS stores daemon-owned metadata and invents synthetic state
- daemon exposes runtime-level details but not a stable conversation-level abstraction
- ACP history IDs and daemon-managed runtime IDs are still mixed together in client code
- external-session adoption is implemented as app-side orchestration instead of a daemon capability

This keeps `AppState` large, keeps recovery paths branch-heavy, and forces the test suite to protect too many incidental flows.

The goal of this refactor is not to make `resumeSession()` cleaner.
The goal is to make **the daemon the only source of truth for conversation lifecycle**.

## Product invariants

These are the user-facing guarantees the architecture must preserve:

1. The phone controls a remote coding agent over SSH.
2. SSH can die without killing the remote task.
3. Reconnect restores the same active chat when possible.
4. A conversation started elsewhere can be opened on the phone.
5. A runtime has at most one attached client owner.
6. A client owner has at most one attached runtime at a time.

## Core model

The current design overloads `sessionId` with two different meanings:

- **history identity** — the ACP conversation that can be loaded later
- **runtime identity** — the currently running daemon-managed ACP proxy

These identities are sometimes equal, sometimes not, and the entire complexity explosion comes from pretending they are the same thing.

### New terminology

#### `conversationId`

Stable identity for a chat history.

- For a freshly created session, `conversationId` initially equals the ACP `session/new` ID.
- If that runtime later dies and the daemon recreates a new runtime from history, the `conversationId` stays the same.
- This is the only durable identity the iOS app should persist.

#### `runtimeId`

Ephemeral identity for a live daemon-managed ACP proxy.

- Changes whenever the daemon creates a replacement runtime.
- Only matters while a client is attached or while replaying buffered events.
- Must not be the primary identity in SwiftData.

#### `ownerId`

Stable per-install client identity, already present as `daemonAttachClientID`.

- Used for reconnect reclaim.
- Used by daemon to ensure a single active attachment per owner.

## Single source of truth

### iOS owns

- UI state
- navigation state
- draft input
- ephemeral message rendering state
- cached display metadata for offline sorting only

### Daemon owns

- conversation registry
- runtime registry
- owner-to-runtime attachment mapping
- replay buffers
- history discovery
- history restore/adopt logic
- runtime state transitions

### ACP owns

- actual model process execution
- durable history store exposed by `session/list` and `session/load`

The iOS app should not re-implement daemon policy.
If the daemon must guess CWDs, retry commands, or decide whether a dead runtime is restorable, that logic belongs in the daemon.

## New daemon abstraction

The daemon should expose **conversations**, not raw runtime sessions, to the client.

## Proposed daemon API v2

A rename from `daemon/session.*` to `daemon/conversation.*` is recommended to make the semantic break explicit.
Keeping the old method names is possible, but strongly discouraged because it preserves conceptual ambiguity.

### `daemon/conversation.list`

Returns the set of conversations visible to this node/workspace.

Response item shape:

```jsonc
{
  "conversationId": "conv-123",
  "runtimeId": "run-456",           // optional: nil when no live runtime
  "state": "attached" | "ready" | "running" | "restorable" | "unavailable",
  "cwd": "/home/user/project",
  "command": "claude-agent-acp",
  "title": "Fix flaky tests",
  "updatedAt": "2026-03-06T10:00:00Z",
  "ownerId": "ios-install-uuid",    // optional, only if attached
  "origin": "managed" | "discovered"
}
```

Rules:

- A conversation appears only once.
- If a live runtime exists for the same `conversationId`, do not also emit a separate external row.
- A dead-but-restorable conversation appears as `restorable`, not `dead` plus a duplicate external row.
- `unavailable` is a local cache/rendering concept in iOS; daemon should generally omit unavailable conversations from live listing unless explicitly asked.

### `daemon/conversation.create`

Creates a brand new conversation and attaches the calling owner in one RPC.

Request:

```jsonc
{
  "cwd": "/home/user/project",
  "command": "claude-agent-acp",
  "ownerId": "ios-install-uuid"
}
```

Response:

```jsonc
{
  "conversation": { ...descriptor... },
  "attachment": {
    "runtimeId": "run-123",
    "bufferedEvents": []
  }
}
```

Rules:

- New conversations start with `conversationId == runtimeId`.
- Owner handoff from any previously attached runtime owned by the same `ownerId` happens atomically inside daemon.
- iOS does not call `create` then `attach`; one call is enough.

### `daemon/conversation.open`

Opens an existing conversation for an owner.

Request:

```jsonc
{
  "conversationId": "conv-123",
  "ownerId": "ios-install-uuid",
  "lastRuntimeId": "run-456",       // optional reconnect hint
  "lastEventSeq": 42,                 // optional replay cursor for lastRuntimeId
  "preferredCommand": "claude-agent-acp", // optional for restorable/discovered conversations
  "cwdHint": "/home/user/project"   // optional, daemon may ignore
}
```

Response:

```jsonc
{
  "conversation": { ...descriptor... },
  "attachment": {
    "runtimeId": "run-789",
    "reusedRuntime": false,
    "restoredFromHistory": true,
    "bufferedEvents": [ { "seq": 43, "event": {...} } ]
  }
}
```

Behavior:

1. If a live runtime for `conversationId` exists, attach/reclaim it.
2. Else if daemon can restore the conversation from ACP history, create a new runtime, load history, attach it, and return the new `runtimeId`.
3. Else return `conversation_not_found`.
4. If the same `ownerId` already owns another runtime, daemon detaches that previous runtime atomically as part of this open.

This single method replaces all of the following app-side branching:

- managed resume
- external adopt
- attach-fails-then-takeover fallback
- detach-then-rollback-on-open-failure

### `daemon/conversation.detach`

Detaches the owner from its current runtime for a conversation.

Request:

```jsonc
{ "conversationId": "conv-123", "ownerId": "ios-install-uuid" }
```

Rules:

- Safe to call redundantly.
- If runtime is busy, daemon keeps it running and marks it detached/busy internally.
- If runtime is idle and daemon policy allows eager cleanup, daemon may stop the runtime after detach.

### `daemon/conversation.close_runtime`

Optional but recommended explicit daemon operation for killing a live runtime without deleting history.

Request:

```jsonc
{ "conversationId": "conv-123" }
```

Effects:

- Kills the live runtime if present.
- Keeps the conversation restorable if ACP history still exists.
- Lets the UI expose “stop remote process” separately from “forget local row”.

## Internal daemon design

## New registry shape

Replace the current flat session/runtime registry with a conversation-owned registry.

```text
ConversationRegistry
├── byConversationId: conversationId -> ConversationRecord
├── byRuntimeId: runtimeId -> RuntimeHandle
└── byOwnerId: ownerId -> runtimeId
```

### `ConversationRecord`

Suggested fields:

- `conversationId`
- `currentRuntimeId?`
- `lastKnownCWD`
- `lastKnownCommand`
- `lastKnownTitle`
- `lastKnownUpdatedAt`
- `loadability`: `unknown | loadable | unavailable`
- `discoveredFrom`: command/source metadata

### `RuntimeHandle`

Suggested fields:

- `runtimeId`
- `conversationId`
- `proxy`
- `runState`
- `attachedOwnerId?`
- `eventBuffer`
- `createdAt`
- `lastActivityAt`

This makes the daemon capable of answering “what conversation is this?” without asking iOS.

## Runtime state model

The current enum mixes execution state and attachment state.
The daemon should separate them.

### Internal execution state

```text
starting | idle | running | dead
```

### Internal attachment state

```text
attached(ownerId) | detached
```

### Derived UI state

The daemon derives a client-facing state from those two axes:

- `attached` = idle + attached
- `ready` = idle + detached but runtime still live
- `running` = running + attached
- `restorable` = no runtime, history loadable
- `unavailable` = no runtime, history unavailable

This removes the need for attach-time hidden transitions like:

- `completed -> idle`
- `draining -> prompting`

The only automatic state changes should be true runtime facts, not client-convenience rewrites.

## History restore policy

History restore is a daemon concern.
The client should not guess.

### Restore algorithm

When `conversation.open` targets a non-live conversation:

1. Resolve a launcher command:
   - previous daemon-known command
   - caller `preferredCommand`
   - configured default per node
2. Resolve CWD candidates:
   - daemon-known `lastKnownCWD`
   - discovery-reported CWD
   - caller `cwdHint`
3. Create a fresh runtime.
4. Attach runtime to ACP.
5. Issue `session/load(sourceConversationId)` inside daemon.
6. On success, bind `conversationId -> runtimeId`.
7. On failure, clean up the new runtime and either retry with another command or return a terminal error.

The current app-side `loadCwdCandidates`, alternate command retry, and takeover cleanup logic should all move here.

## iOS app model after refactor

## SwiftData model

The current `Session` model should be replaced or migrated to a lighter conversation reference.

Suggested replacement:

```swift
@Model
final class ConversationRef {
    var conversationId: String
    var lastUsedAt: Date
    var titleCache: String?
    var agentIDCache: String?
    var workspace: Workspace?
}
```

Optional cache fields are acceptable, but they must be explicitly treated as cache.
They are never authority.

### Data that should not be persisted as authority in iOS

- `runtimeId`
- `sessionCwd`
- `agentCommand`
- `canonicalSessionId`
- daemon liveness state

### In-memory only app state

- `currentConversationId`
- `currentRuntimeId`
- `lastEventSeqByRuntimeId`
- rendered message list
- input/prompt spinners

The replay cursor belongs to `runtimeId`, not `conversationId`, because a recreated runtime starts a fresh replay stream.

## AppState simplification target

After this refactor, `AppState` should no longer contain:

- app-side external takeover orchestration
- app-side CWD candidate retry loops
- app-side command retry loops for session restore
- `canonicalSessionId` mapping lookups
- `temporaryNotificationSessionIDs`
- synthetic daemon-state invention for dead sessions
- detach-then-rollback switching logic

### New high-level flow

#### Open from picker

```text
tap row
-> daemon/conversation.open(conversationId, ownerId, hints)
-> daemon returns runtimeId + buffered events
-> AppState binds currentConversationId/currentRuntimeId
-> replay buffered events
-> render chat
```

#### Reconnect interrupted chat

```text
app foregrounds
-> reconnect SSH transport
-> daemon/conversation.open(
     conversationId,
     ownerId,
     lastRuntimeId,
     lastEventSeq
   )
-> daemon either reuses live runtime or restores a new one
-> AppState does not care which path happened
```

This turns reconnect into a daemon capability instead of an AppState recovery tree.

## Notification contract

All chat notifications should carry `runtimeId` and `conversationId`.

```jsonc
{
  "method": "session/update",
  "params": {
    "runtimeId": "run-789",
    "conversationId": "conv-123",
    "__seq": 44,
    ...
  }
}
```

Client filtering rule becomes simple:

- accept only notifications for `currentRuntimeId`
- optionally sanity-check `conversationId == currentConversationId`

This removes the current need for temporary multi-ID notification scopes.

## SwiftData migration plan

Migration is acceptable and recommended.

### Source model

Current model in `Sources/Models/Session.swift` stores:

- `sessionId`
- `canonicalSessionId?`
- `sessionCwd?`
- `agentID?`
- `agentCommand?`
- `lastUsedAt`

### Target migration rule

For each old row:

- `conversationId = canonicalSessionId ?? sessionId`
- `titleCache = title`
- `agentIDCache = agentID`
- preserve `workspace`
- preserve `lastUsedAt`

### Duplicate collapse rule

Group by:

- `workspace`
- `conversationId`

Keep the most recently used row.
Merge caches conservatively:

- latest non-empty `title`
- latest non-empty `agentID`

### Post-migration behavior

- Any runtime-specific fields are discarded.
- Missing or inconsistent daemon data at runtime is handled by fresh daemon listing/opening, not by local fallback logic.

## Recommended file-level changes

### iOS

- `Sources/AppState.swift`
  - replace `resumeSession` / `takeOverExternalSession` split with a single daemon-driven `openConversation`
  - remove local restore orchestration helpers
- `Sources/ACP/DaemonClient.swift`
  - add new typed conversation API
- `Sources/Models/Session.swift`
  - migrate to `ConversationRef` or equivalent
- `Sources/Models/DaemonTypes.swift`
  - replace session-centric DTOs with conversation/runtime DTOs
- `Sources/Views/SessionPickerView.swift`
  - render conversation rows from daemon list + local cache

### daemon

- `opencan-daemon/internal/daemon/session_manager.go`
  - evolve into conversation registry logic or split into `conversation_registry.go`
- `opencan-daemon/internal/daemon/client_handler.go`
  - implement `daemon/conversation.*`
  - remove special `session/load` fallback routing once restore lives in daemon
- `opencan-daemon/internal/proxy/acp_proxy.go`
  - keep runtime/proxy responsibilities narrow
  - remove attach-time state promotion side effects

## Test strategy reset

The current tests over-index on implementation branches.
The rewritten suite should instead lock the protocol contract.

### Daemon contract tests

Must cover:

1. `conversation.create` returns attached runtime and empty replay
2. `conversation.open` reuses a live runtime when available
3. `conversation.open` restores from history when no live runtime exists
4. `conversation.open` returns `not_found` when history is unavailable
5. same `ownerId` can reclaim after reconnect
6. opening conversation B atomically detaches previous conversation A for the same owner
7. `conversation.list` deduplicates managed and discovered rows by `conversationId`
8. busy detached runtime continues to completion without owner attached
9. prompt terminal signals always settle daemon run state

### iOS contract tests

Must cover:

1. create → send prompt → terminal settle
2. reconnect active conversation using same `ownerId`
3. open restorable conversation from picker
4. ignore notifications from other runtime IDs
5. image mention prompt blocks still work
6. unavailable conversation surfaces a clean error and local row state

### Tests to delete or collapse

Delete tests whose only purpose is protecting app-side orchestration that should no longer exist:

- external takeover branch tests in `AppStateTests`
- attach-failure-then-inline-takeover tests
- CWD candidate retry matrix tests in iOS
- temporary notification scope tests
- routing hacks around history source session IDs

## Rollout phases

## Phase 0 — Lock current behavior at the edges

Before large code movement, freeze the contract with a small set of daemon and iOS high-value tests.
Do not add more branch tests.

## Phase 1 — Daemon conversation layer

- Introduce daemon conversation registry and `conversation.list/open/create/detach`
- Keep old `session.*` methods temporarily for compatibility if needed
- Add adapter logic inside daemon so old and new APIs can coexist during migration

## Phase 2 — iOS migration

- Add SwiftData migration to `ConversationRef`
- Switch `AppState` and `SessionPickerView` to new daemon API
- Remove app-side takeover/load orchestration
- Reduce notification filtering to current runtime only

## Phase 3 — Cleanup

- delete old `session.*` compatibility methods
- delete old SwiftData fields and dead migration scaffolding
- remove obsolete tests and docs

## Explicit decisions

1. **Do not stop at `resumeSession` / `adoptExternalSession` split.**
   That split is a valid interim refactor, but not the end state.
2. **Do not persist daemon-owned metadata as authority in iOS.**
3. **Do not keep `canonicalSessionId` in the long-term model.**
4. **Do not keep external-session adoption in AppState.**
5. **Prefer a clean API break over preserving ambiguous `sessionId` semantics.**

## Recommended immediate next step

Implement a daemon-side RFC prototype for `conversation.list` and `conversation.open` first.
Once those wire contracts are stable, the iOS rewrite becomes dramatically simpler and can be done with far fewer moving parts.
