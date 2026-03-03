# Session 1:1 Simplification Plan

## Problem Statement

The current design allows a UI `Session` record to diverge from its underlying
daemon/agent thread. A single SwiftData `Session` may carry two IDs:

- `sessionId` — the current daemon session (where the ACP process lives)
- `historySessionId` — the original conversation source (used for recovery)

This divergence is caused exclusively by the **history recovery path**
(`resumeHistorySession`), which creates a new ACP process and loads an old
conversation into it via `session/load` with `__routeToSession` routing.

In practice, there is only ever 0 or 1 client attached to a given agent thread.
The N:M routing indirection adds significant complexity for a recovery scenario
that produces an imperfect result (new agent process with no in-memory state,
just a replayed transcript).

## Current Architecture

### Session Model Fields

```swift
@Model final class Session {
    var sessionId: String            // Current daemon session ID
    var sessionCwd: String?
    var historySessionId: String?    // Original conversation (recovery only)
    var historySessionCwd: String?   // CWD for history load (recovery only)
    // ...
}
```

### Recovery Flow (What Creates the Divergence)

```
1. Daemon forgot session "old-123"
2. iOS: daemon/session.attach("old-123") → error "session not found"
3. iOS: daemon/session.create() → "new-456"
4. iOS: daemon/session.attach("new-456")
5. iOS: session/load(sessionId: "old-123", __routeToSession: "new-456")
         ↑ tells ACP which conversation    ↑ tells daemon which proxy
6. SwiftData update:
     sessionId:        "old-123" → "new-456"
     historySessionId: nil       → "old-123"
```

### Components Involved in Routing

| Layer | Component | Role |
|-------|-----------|------|
| iOS Model | `Session.historySessionId` | Tracks original conversation source |
| iOS AppState | `resumeHistorySession()` | Creates new session + loads old history |
| iOS AppState | `activeSessionNotificationIDs()` | Accepts events from both current + history IDs |
| iOS AppState | `historyLoadSessionIds` scope | Accepts events during history replay |
| iOS AppState | `resolvePromptTargetSession()` | **Dead code** — always returns `(id, nil)` |
| iOS ACP | `ACPService.sendPrompt(routeToSessionId:)` | Carries routing param (always nil in practice) |
| iOS ACP | `ACPService.loadSession(routeToSessionId:)` | Carries routing param (used during recovery) |
| Daemon | `ExtractRouteToSession()` | Parses `__routeToSession` from JSON-RPC params |
| Daemon | `handleACPRequest()` routing logic | Overrides proxy lookup for load/prompt |

### Key Observation: Prompt Routing Is Already Dead

`resolvePromptTargetSession` at `AppState.swift:1345` always returns
`(daemonSessionId, nil)`. The `__routeToSession` parameter flows through the
entire `sendMessage → sendPrompt` call chain but is **always nil**. The
daemon-side support for routing on `session/prompt` exists but is never
exercised by the iOS client.

## Proposed Simplification

### Core Principle

**1 UI Session = 1 Agent Thread.** If the agent thread dies and cannot be
reattached, the session is dead. No silent creation of replacement sessions.

### What Gets Removed

#### iOS — Session Model
- `Session.historySessionId`
- `Session.historySessionCwd`
- SwiftData migration to drop these columns

#### iOS — AppState
- `resumeHistorySession()` (entire function, ~120 lines)
- `resolvePromptTargetSession()` (dead code)
- `historyLoadSessionIds` set + `beginHistoryLoadScope()` / `endHistoryLoadScope()`
- `prepareHistoryReplayTracking(for:)` / `clearHistoryReplayTracking(for:)`
- Dual-ID logic in `activeSessionNotificationIDs()` (just return `currentSessionId`)
- `sourceSessionId` / `sourceSessionCwd` computation in `resumeSession()`
- History-source branching in the idle/completed replay path of `resumeSession()`
- `routeToSessionId` parameter from `loadSessionFromCandidates()`

#### iOS — ACPService
- `routeToSessionId` parameter from `sendPrompt()` and `loadSession()`

#### Daemon — Protocol
- `ExtractRouteToSession()` function
- `__routeToSession` field parsing
- `TestExtractRouteToSession` / `TestExtractRouteToSession_MissingOrInvalid` tests

#### Daemon — Client Handler
- `__routeToSession` override block in `handleACPRequest()` (lines 396-406)

#### Tests
- `testResumeHistorySession`
- `testResumeRecoveredSessionUsesOriginalHistorySource`
- `testResumeExternalAgentSessionDemotesBootstrapPromptToSystemMessage`
- Routing-related daemon integration tests

### What Changes in `resumeSession()`

The current 4 recovery paths collapse to 2:

**Before (4 paths):**
1. External session → `resumeHistorySession()`
2. Running session → attach + buffer replay
3. Idle/completed → attach + buffer replay + optional `session/load` (with routing)
4. Attach error "not found" → `resumeHistorySession()`

**After (2 paths):**
1. **Session in daemon** → attach + buffer replay + optional `session/load`
   (own ID, no routing)
2. **Session NOT in daemon** (including external) → mark as dead, surface error

```swift
// Simplified resumeSession sketch
func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
    // ... setup ...

    // External or unknown sessions are not resumable.
    guard let daemonKnownSession = daemonSessions.first(where: { $0.sessionId == sessionId }),
          daemonKnownSession.state != "external" else {
        markSessionDead(sessionId: sessionId, modelContext: modelContext)
        throw AppStateError.sessionNotRecoverable(sessionId)
    }

    await detachCurrentSessionIfNeeded(...)

    let result: DaemonAttachResult
    do {
        result = try await attachSessionWithRetryIfNeeded(...)
    } catch {
        if shouldTreatAttachFailureAsOwnershipConflict(error) {
            await restorePreviousAttachmentIfNeeded(...)
            throw AppStateError.sessionAttachedByAnotherClient(sessionId)
        }
        // Session gone — mark dead, don't recover.
        markSessionDead(sessionId: sessionId, modelContext: modelContext)
        throw AppStateError.sessionNotRecoverable(sessionId)
    }

    // Attach succeeded — replay buffer
    self.currentSessionId = sessionId
    let isRunning = result.state == "prompting" || result.state == "draining"

    if isRunning {
        isPrompting = true
        for buffered in result.bufferedEvents { ... }
        isPrompting = false
    } else {
        for buffered in result.bufferedEvents { ... }
        if !hasRenderableConversation() {
            // Backfill from own history — no routing needed
            await loadSessionFromCandidates(
                sessionId: sessionId,
                traceId: traceId,
                candidateCwds: primaryCwds
            )
        }
    }

    // Update SwiftData record (no historySessionId)
    existing.lastUsedAt = Date()
    existing.sessionCwd = resolvedSessionCwd
}
```

### Notification Filtering Simplification

```swift
// Before: must track two IDs + history load scope
private func activeSessionNotificationIDs() -> Set<String> {
    guard let currentSessionId else { return [] }
    var ids: Set<String> = [currentSessionId]
    if let sourceSessionId = activeSession?.historySessionId,
       sourceSessionId != currentSessionId {
        ids.insert(sourceSessionId)
    }
    return ids
}

// After: single ID
private func activeSessionNotificationIDs() -> Set<String> {
    guard let currentSessionId else { return [] }
    return [currentSessionId]
}
```

The `historyLoadSessionIds` set and its begin/end scope management are removed
entirely. `shouldHandleSessionNotification` simplifies to just checking
`activeSessionNotificationIDs()`.

## Phase 3 (Optional): Explicit "Restart from History" UX

If we want to preserve the ability to continue a dead conversation, offer it as
an **explicit user action** rather than a silent recovery:

1. Dead sessions show a "Restart conversation" button in `SessionPickerView`
2. Tapping it creates a new session + `session/load` from the old conversation
3. This is a NEW session entry in the list, not a mutation of the old one
4. The old session remains in the list as a dead historical record

### Daemon Change for Restart

When the user explicitly restarts, we call:
```
daemon/session.create() → "new-456"
daemon/session.attach("new-456")
session/load(sessionId: "old-123", cwd: ...)
```

The problem: `session/load(sessionId: "old-123")` routes to
`attachedProxies["old-123"]` which doesn't exist. Two options:

**Option A — Daemon fallback routing for `session/load`:**
If `session/load` targets a sessionId the client isn't attached to, route to
the client's single attached proxy. This eliminates `__routeToSession` entirely.

```go
// In handleACPRequest, special case for session/load:
if msg.Method == protocol.MethodSessionLoad {
    if _, ok := h.attachedProxies[sessionID]; !ok {
        // sessionId is a history reference, not a live proxy.
        // Route to the client's attached proxy (should be exactly one).
        if len(h.attachedProxies) == 1 {
            for _, p := range h.attachedProxies {
                p.ForwardFromClient(msg, h)
                return
            }
        }
        // No attached proxy or ambiguous — error
        h.Send(protocol.NewErrorResponse(*msg.ID, -32602, "not attached to session: "+sessionID))
        return
    }
}
```

**Option B — Use a dedicated daemon method:**
```
daemon/session.loadHistory(targetSessionId: "new-456", sourceSessionId: "old-123", cwd: ...)
```
Daemon handles routing internally. Cleaner API boundary but a new method.

**Option A is recommended** — it's a minimal daemon change that makes
`session/load` work naturally without any client-side routing hints.

## Execution Plan

### Phase 1 — Remove Dead Code (No Behavioral Change)

1. Remove `resolvePromptTargetSession()` from AppState
2. Remove `routeToSessionId` parameter from `sendPrompt()` call chain
3. Remove `routeToSessionId` from `sendMessage` → `dispatchPrompt` pipeline
4. Update tests that reference prompt routing

### Phase 2 — Remove History Recovery

1. Remove `historySessionId` / `historySessionCwd` from `Session` model
2. Delete `resumeHistorySession()` from AppState
3. Simplify `resumeSession()` to 2-path model (attach or dead)
4. Remove `historyLoadSessionIds`, scope tracking, dual-ID notification filtering
5. Remove `__routeToSession` from `ACPService.loadSession()`
6. Remove `ExtractRouteToSession` and routing override from daemon
7. Add `markSessionDead()` helper + dead-session UI handling
8. Update/remove affected tests
9. Add SwiftData migration for dropped fields
10. Update CLAUDE.md architecture docs

### Phase 3 — Explicit Restart UX (Optional)

1. Add daemon fallback routing for `session/load` (Option A above)
2. Add "Restart conversation" action in `SessionPickerView` for dead sessions
3. Restart creates a new `Session` record (old one stays as historical)
4. No `historySessionId` needed — the new session is independent

## Impact Assessment

### Lines of Code Removed (Estimate)
- `resumeHistorySession()`: ~120 lines
- History load scope tracking: ~60 lines
- Notification filtering dual-ID logic: ~30 lines
- `resolvePromptTargetSession` + routing params: ~40 lines
- Daemon routing override: ~15 lines
- Tests: ~150 lines
- **Total: ~400+ lines removed**

### Risk Areas
- External session handling changes (currently silently adopted → now dead)
- Daemon restart experience degrades unless Phase 3 is implemented
- SwiftData migration for existing users with `historySessionId` set

### Contract Tests to Update
Per CLAUDE.md, these contract tests are affected:
- `testResumeHistorySession` — remove
- `testResumeRecoveredSessionUsesOriginalHistorySource` — remove
- `testResumeExternalAgentSessionDemotesBootstrapPromptToSystemMessage` — remove or rework
- Daemon routing tests — remove
