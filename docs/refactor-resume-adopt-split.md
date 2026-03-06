# Plan: Separate resumeSession and adoptExternalSession

> Superseded as the primary direction by `docs/conversation-runtime-refactor.md`.
> Keep this document only as a smaller-scope fallback/transition plan.

## Context

`resumeSession()` (AppState.swift:550, ~350 lines) handles both managed sessions (attach+replay) and external sessions (create+attach+load) in interleaved code paths with 13+ error branches. This causes a bug-fixing treadmill: each fix risks regressions in other branches. We split into two isolated functions, keeping UX identical — users tap any session and it opens.

## Files to Modify

1. **`Sources/AppState.swift`** — main refactor target
2. **`Sources/Views/SessionPickerView.swift`** — update call site to dispatch
3. **`Tests/AppStateTests.swift`** — update tests

No daemon (Go) changes. No Session model changes. No SwiftData migration.

## Step 1: Add `openSession` dispatch entry point

Add a new public function in AppState that routes to the correct path:

```swift
/// Unified entry point: routes external sessions to adoption, managed to resume.
func openSession(sessionId: String, modelContext: ModelContext) async throws {
    let daemonSession = daemonSessions.first { $0.sessionId == sessionId }

    if daemonSession?.state == "external" {
        try await adoptExternalSession(
            externalSessionId: sessionId,
            workspace: activeWorkspace!,
            daemon: daemonClient!,
            modelContext: modelContext
        )
    } else {
        try await resumeSession(sessionId: sessionId, modelContext: modelContext)
    }
}
```

## Step 2: Update SessionPickerView call site

In `SessionPickerView.swift:341`, change:
```swift
// Before
try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)
// After
try await appState.openSession(sessionId: sessionId, modelContext: modelContext)
```

`recoverInterruptedSessionIfNeeded` (line 949) keeps calling `resumeSession` directly — interrupted sessions are always managed.

## Step 3: Extract `adoptExternalSession` from `takeOverExternalSession`

Create a new public function `adoptExternalSession()` by extracting and simplifying the existing `takeOverExternalSession()` (line 1830, 266 lines). Key differences from current code:

- **No `restorePreviousAttachmentIfNeeded`** — the caller (`openSession`) handles errors; we detach before starting and don't try to roll back on failure
- **No `temporaryNotificationSessionIDs`** — the current session ID is set to the new managed session after attach; notifications route naturally
- **Keeps command candidate retry** — `externalTakeoverCommandCandidates` is retained since retrying with alternate commands is valuable
- **Keeps CWD candidate logic** — `loadSessionFromCandidates` is retained but used with simplified candidate list
- **Keeps canonicalSessionId persistence** — we still write `canonicalSessionId` on the Session model for deduplication in `mergeWorkspaceSessions`; removing that field is a follow-up

Signature:
```swift
func adoptExternalSession(
    externalSessionId: String,
    workspace: Workspace,
    daemon: DaemonClient,
    modelContext: ModelContext
) async throws
```

Implementation outline (~120 lines):
1. `settlePromptingStateForSessionSwitch(clearMessages: true)`
2. Resolve agent command via `resolveSessionAgent` + `externalTakeoverCommandCandidates`
3. Build CWD candidates (daemon cwd + workspace path, max 2)
4. Loop over command candidates:
   a. `daemon.createSession(cwd:command:)`
   b. `attachSessionWithRetryIfNeeded(daemon:sessionId:lastEventSeq:0)`
   c. Set `currentSessionId`, `lastEventSeq`, clear messages
   d. `loadSessionFromCandidates(sessionId: externalSessionId, candidateCwds:)`
   e. If load failed and retryable → kill session, continue to next command
   f. If load failed terminally → kill session, throw
   g. If load succeeded → break
5. Persist Session record (find-or-create, set canonicalSessionId)
6. `addSystemMessage("External session resumed")`
7. `refreshDaemonSessions()`

Error cleanup: on attach failure or terminal load failure, kill the created session. No `restorePreviousAttachmentIfNeeded` — the previous session was already detached.

## Step 4: Simplify `resumeSession`

Remove from `resumeSession`:
1. **Lines 558-589**: External session redirect via `mappedManagedSessionForExternal` — DELETE (openSession handles routing)
2. **Lines 637-651**: External session branch calling `takeOverExternalSession` — DELETE
3. **Lines 692-726**: Attach failure → takeover recovery fallback — SIMPLIFY to just `markSessionDead + throw`
4. **Lines 754-845**: Merge running/idle replay branches into one unified path

Simplified `resumeSession` structure (~100 lines):

```
1. Guard daemon + workspace
2. Resolve agent metadata (resolveSessionAgent) — keep for persistence
3. Fast path: same session re-entry → return
4. settlePromptingStateForSessionSwitch + detachCurrentSessionIfNeeded
5. attachSessionWithRetryIfNeeded
   - Ownership conflict → restorePreviousAttachmentIfNeeded + throw
   - Session missing → markSessionDead + throw (NO takeover fallback)
   - Other error → restorePreviousAttachmentIfNeeded + throw
6. Set currentSessionId, clear messages
7. Unified replay:
   - if running: isPrompting = true
   - replay buffered events
   - if !hasRenderableConversation: loadSessionHistory (own ID, 2 CWD candidates max)
   - if running: isPrompting = false
   - clear streaming indicators
8. Persist Session record
9. addSystemMessage
10. refreshDaemonSessions
```

**Keep `restorePreviousAttachmentIfNeeded`** in resumeSession for the ownership-conflict and generic-error cases — these represent "I was looking at session A, tried to switch to B, B rejected me, go back to A". This rollback is only needed when we detached A before trying B.

## Step 5: Delete `takeOverExternalSession`

After `adoptExternalSession` is working, delete the old `takeOverExternalSession` function (lines 1830-2095) entirely. The new `adoptExternalSession` replaces it.

## Step 6: Clean up helpers

- **`mappedManagedSessionForExternal()`** (line 1580): DELETE — no longer called from resumeSession. The deduplication in `mergeWorkspaceSessions` still works via `canonicalSessionId` on the Session model.
- **`temporaryNotificationSessionIDs`** (line 78): Remove the property and all references. `adoptExternalSession` sets `currentSessionId` to the new managed session, so the notification listener naturally accepts events for it.
- **`shouldHandleSessionNotification` / `activeSessionNotificationIDs`**: Remove `temporaryNotificationSessionIDs` from the union. Should simplify to just `[currentSessionId]`.

## Step 7: Update tests

### Tests to rewrite (move from resumeSession to adoptExternalSession/openSession):
- `testResumeExternalSessionTakeover` → `testAdoptExternalSession`
- `testResumeExternalSessionRedirectsToMappedManagedSessionWithoutDaemonManagedRow` → DELETE (no more redirect; openSession dispatches directly)
- `testResumeExternalSessionTakeoverRetriesAlternateCommandAfterQueryClosed` → `testAdoptExternalSessionRetriesAlternateCommand`
- `testResumeExternalSessionTakeoverRetriesAlternateCommandAfterSessionNotFound` → merge with above
- `testResumeExternalSessionTakeoverLoadFailureDoesNotPersistManagedSessionID` → `testAdoptExternalSessionLoadFailureDoesNotPersist`
- `testResumeExternalSessionTakeoverCleansCreatedSessionWhenAttachFails` → `testAdoptExternalSessionCleansOnAttachFailure`

### Tests to simplify:
- `testResumeMissingSessionAttemptsTakeoverRecovery` → `testResumeMissingSessionMarksDeadDirectly` (no takeover attempt, just mark dead)
- `testResumeMissingSessionTakeoverFailureMarksSessionDead` → DELETE (merged into above)

### Tests to keep as-is (may need minor assertion updates):
- `testNewSessionSendMessage` ✓
- `testSendMessageWithoutPromptCompleteStillClearsPrompting` ✓
- `testIgnoresNotificationsFromOtherSessions` ✓
- `testResumeDrainingPromptCompleteInBuffer` ✓
- `testResumeAttachRejectedByActiveOwner` ✓ (still in resumeSession)
- `testResumeAttachFailureRestoresPreviousAttachment` ✓ (still in resumeSession)
- `testResumeMissingSessionMarksDeadAndThrowsNotRecoverable` ✓ (simpler: no takeover attempt)
- `testResumeExternalSessionTakeover` in contract tests → rename to `testAdoptExternalSession`
- `testUnifiedSessionExternalIsResumable` ✓ (keep, external sessions are still resumable via openSession)

### New test:
- `testOpenSessionDispatchesExternalToAdopt` — verify openSession routes external to adoptExternalSession

## Step 8: Update `mergeWorkspaceSessions` (minor)

The `managedByCanonicalExternalID` dedup logic (SessionPickerView.swift:68-86) continues to work because we still write `canonicalSessionId`. No change needed now; removing `canonicalSessionId` is a follow-up.

## Verification

1. **Build**: `xcodegen generate && xcodebuild -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -quiet build`
2. **Unit tests**: `xcodebuild test -scheme OpenCAN -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:OpenCANTests`
3. **Contract regression tests** (must all pass):
   - `testNewSessionSendMessage`
   - `testSendMessageWithoutPromptCompleteStillClearsPrompting`
   - `testIgnoresNotificationsFromOtherSessions`
   - `testResumeDrainingPromptCompleteInBuffer`
   - `testResumeMissingSessionMarksDeadAndThrowsNotRecoverable`
   - `testResumeExternalSessionTakeover` (renamed to testAdoptExternalSession)
   - `testSendMessageWithImageMentionAddsResourceLinkPromptBlock`
4. **Manual check**: Ensure `resumeSession` no longer contains any `external` / `takeover` / `takeOver` references
