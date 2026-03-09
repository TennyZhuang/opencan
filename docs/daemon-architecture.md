# OpenCAN Daemon Architecture

This document describes the current daemon contract after the conversation/runtime refactor.

## Goal

OpenCAN lets a phone control remote coding agents over SSH while surviving unstable mobile connectivity.

The key invariant is:

- SSH connections may disconnect.
- Remote work must keep running when appropriate.
- Reconnect must restore the same conversation whenever possible.

## Core Model

### `conversationId`

Stable identity for a chat history.

- Persisted by the iOS app.
- Used to reopen an existing chat.
- May outlive any specific daemon-managed process.

### `runtimeId`

Ephemeral identity for a live daemon-managed ACP runtime.

- Maps to one `ACPProxy` process instance.
- Changes when the daemon recreates a runtime from history.
- Used for live routing and buffered event replay.

### `ownerId`

Stable per-install client identity.

- Sent by iOS on `daemon/conversation.create` and `daemon/conversation.open`.
- Allows same-owner reclaim after transport loss.
- Enforces single active owner per live runtime.

## Source of Truth

### iOS owns

- navigation state
- local rendering state
- cached local metadata for presentation
- persisted `conversationId` records in SwiftData

### daemon owns

- conversation ↔ runtime mapping
- ACP process lifecycle
- attach ownership
- buffered event replay
- restore-from-history orchestration

### ACP owns

- underlying agent protocol
- conversation history storage/load semantics
- agent execution state inside a live runtime

## High-Level Architecture

```text
iOS app
  └─ SSH PTY -> `opencan-daemon attach`
       └─ ClientHandler
            ├─ daemon methods handled locally
            └─ ACP requests forwarded to attached runtime

opencan-daemon
  ├─ SessionManager
  │   ├─ managed runtimes (`runtimeId` -> ACPProxy)
  │   └─ conversation registry (`conversationId` <-> `runtimeId`)
  └─ ACPProxy
      ├─ child ACP process
      ├─ state machine
      └─ buffered `session/update` events
```

## Public Daemon Methods

### Lifecycle API

- `daemon/conversation.create`
  - creates a new runtime
  - attaches the caller as owner immediately
  - returns `conversation` + `attachment`

- `daemon/conversation.open`
  - reattaches to an existing managed runtime when available
  - otherwise restores a new runtime from ACP history
  - returns `conversation` + `attachment`

- `daemon/conversation.detach`
  - detaches the current client from the conversation's active runtime
  - does not delete history

- `daemon/conversation.list`
  - returns conversation-oriented rows for picker/open UX
  - deduplicates managed and discovered history

### Diagnostic / operational API

- `daemon/session.list`
  - runtime-oriented diagnostic view
  - still used for watchdogs, pruning, and low-level state inspection

- `daemon/session.kill`
  - kills a specific managed runtime

- `daemon/agent.probe`
  - checks launcher availability on the remote host

- `daemon/logs`
  - returns recent in-memory daemon logs plus current log storage metadata

## Ownership Rules

1. A live runtime has at most one attached owner.
2. A reconnect with the same `ownerId` may reclaim that runtime.
3. A different `ownerId` is rejected while another owner is attached.
4. One owner should have at most one attached runtime at a time.
5. Detach removes live attachment only; it does not delete conversation history.

## Restore Rules

When iOS opens a conversation:

1. daemon checks whether a managed runtime already exists for that `conversationId`
2. if yes, daemon reattaches and replays buffered events after `lastEventSeq`
3. if not, daemon discovers loadable ACP history entries
4. daemon creates a fresh runtime
5. daemon performs daemon-owned history restore inside the new runtime
6. daemon binds `conversationId -> runtimeId`
7. daemon returns the new runtime attachment to iOS

iOS no longer orchestrates restore fallback itself.

## Request Routing Invariant

Managed attachment and buffered replay are runtime-oriented, but upstream ACP requests must preserve conversation identity.

- iOS opens and reopens conversations through daemon-owned `runtimeId` attachments.
- The daemon may recreate a fresh runtime for an existing `conversationId`.
- When forwarding ACP calls like `session/prompt`, the daemon must preserve the stable `conversationId` even when the live runtime uses a different `runtimeId`; daemon-owned restore requests must follow the same rule internally.
- Failing to do this breaks restored conversations: the UI can replay history correctly while the underlying agent sees an empty context.

This is a regression boundary, not an implementation detail.

## Replay Contract

Forwarded `session/update` notifications include:

- `__seq`
- `runtimeId`
- `conversationId`

`daemon/conversation.open` accepts:

- `conversationId`
- `ownerId`
- `lastRuntimeId`
- `lastEventSeq`
- optional restore hints such as `preferredCommand` and `cwdHint`

Replay behavior:

- if reopening the same runtime, daemon replays buffered events with `seq > lastEventSeq`
- if restore produces a new runtime, replay starts from the new runtime's buffer

## Runtime State Machine

Managed runtimes use the ACP proxy state machine:

- `Starting`
- `Idle`
- `Prompting`
- `Draining`
- `Completed`
- `Dead`
- `External` for discovered-but-unmanaged ACP history rows

Conversation-facing UI states are derived from these runtime states.

## Prompt Lifecycle Contract

Every `session/prompt` must terminate via at least one of:

- `session/update` with `prompt_complete`
- JSON-RPC error response
- JSON-RPC success response

After termination, daemon state must not remain stuck in `prompting` or `draining`.

## Why `session.list` Still Exists

The refactor removes `daemon/session.create|attach|detach`, but keeps `daemon/session.list|kill` because they are still useful for:

- diagnostics
- low-level daemon/runtime inspection
- pruning orphaned or empty managed runtimes
- watchdog logic that reasons about runtime state rather than conversation state

## Obsolete API

These daemon methods are removed and must not be used anymore:

- `daemon/session.create`
- `daemon/session.attach`
- `daemon/session.detach`

Use `daemon/conversation.create|open|detach` instead.
