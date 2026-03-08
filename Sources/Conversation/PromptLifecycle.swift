import Foundation

@MainActor
protocol PromptLifecycleAppState: AnyObject {
    var isPrompting: Bool { get set }
    var currentSessionId: String? { get set }
    var forceScrollToBottom: Bool { get set }
    var messages: [ChatMessage] { get set }
    var daemonSessions: [DaemonSessionInfo] { get set }
    var daemonClientForPromptLifecycle: DaemonClient? { get }
    var promptResponseTimeoutSecondsForLifecycle: TimeInterval { get }
    var promptResponseMaxWaitSecondsForLifecycle: TimeInterval { get }
    var promptResponsePollIntervalSecondsForLifecycle: TimeInterval { get }
    var promptLastActivityAtForLifecycle: [String: Date] { get set }

    func newTraceIDForPromptLifecycle() -> String
    func promptLifecycleRefreshDaemonSessions() async
    func promptLifecycleAddSystemMessage(_ text: String)
    func promptLifecycleContentDidChange()
    func promptLifecycleLastAssistantMessage() -> ChatMessage
}

enum PromptLifecycle {
    @MainActor
    static func executePrompt(
        appState: PromptLifecycleAppState,
        service: ACPService,
        sessionId: String,
        prompt: [PromptBlock],
        traceId: String?
    ) async {
        let timeoutSeconds = appState.promptResponseTimeoutSecondsForLifecycle
        do {
            let _ = try await Log.timed(
                "session/prompt",
                component: "PromptLifecycle",
                traceId: traceId,
                sessionId: sessionId
            ) {
                try await sendPromptAwaitingTerminalResponse(
                    appState: appState,
                    service: service,
                    sessionId: sessionId,
                    prompt: prompt,
                    monitorSessionId: sessionId,
                    traceId: traceId,
                    inactivityTimeoutSeconds: timeoutSeconds
                )
            }
            let promptStillActive = appState.isPrompting && appState.currentSessionId == sessionId
            guard promptStillActive else {
                Log.log(
                    level: "warning",
                    component: "PromptLifecycle",
                    "sendPrompt returned after prompt already settled",
                    traceId: traceId,
                    sessionId: sessionId
                )
                return
            }
            Log.log(component: "PromptLifecycle", "sendPrompt returned", traceId: traceId, sessionId: sessionId)
            settlePromptCompletion(appState: appState, sessionId: sessionId, refreshDaemonSessions: false)
        } catch {
            let normalizedError = normalizePromptSendError(
                error,
                timeoutSeconds: timeoutSeconds
            )
            let promptStillActive = appState.isPrompting && appState.currentSessionId == sessionId
            guard promptStillActive else {
                Log.log(
                    level: "warning",
                    component: "PromptLifecycle",
                    "sendPrompt finished after prompt already settled: \(normalizedError.localizedDescription)",
                    traceId: traceId,
                    sessionId: sessionId
                )
                return
            }
            Log.log(
                level: "error",
                component: "PromptLifecycle",
                "sendPrompt error: \(normalizedError.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId
            )
            presentPromptError(appState: appState, normalizedError)
            settlePromptCompletion(appState: appState, sessionId: sessionId, refreshDaemonSessions: true)
            appState.forceScrollToBottom = true
        }
    }

    @MainActor
    static func didReceiveSessionEvent(
        appState: PromptLifecycleAppState,
        event: SessionEvent,
        sessionId: String?
    ) {
        if let sessionId, appState.isPrompting {
            markPromptActivity(appState: appState, for: sessionId)
        }

        if case .promptComplete = event {
            settlePromptCompletion(appState: appState, sessionId: sessionId, refreshDaemonSessions: true)
            appState.forceScrollToBottom = true
        }
    }

    @MainActor
    static func clearAllPromptActivity(appState: PromptLifecycleAppState) {
        appState.promptLastActivityAtForLifecycle.removeAll()
    }

    @MainActor
    static func markPromptActivity(appState: PromptLifecycleAppState, for sessionId: String) {
        appState.promptLastActivityAtForLifecycle[sessionId] = Date()
    }

    @MainActor
    static func settlePromptCompletion(
        appState: PromptLifecycleAppState,
        sessionId: String?,
        refreshDaemonSessions: Bool
    ) {
        for msg in appState.messages where msg.role == .assistant && msg.isStreaming {
            msg.isStreaming = false
        }
        appState.isPrompting = false
        if let sessionId {
            clearPromptActivity(appState: appState, for: sessionId)
        } else if let currentSessionId = appState.currentSessionId {
            clearPromptActivity(appState: appState, for: currentSessionId)
        }
        if refreshDaemonSessions {
            Task { await appState.promptLifecycleRefreshDaemonSessions() }
        }
    }

    @MainActor
    static func clearPromptActivity(appState: PromptLifecycleAppState, for sessionId: String) {
        appState.promptLastActivityAtForLifecycle.removeValue(forKey: sessionId)
    }

    @MainActor
    private static func sendPromptAwaitingTerminalResponse(
        appState: PromptLifecycleAppState,
        service: ACPService,
        sessionId: String,
        prompt: [PromptBlock],
        monitorSessionId: String,
        traceId: String?,
        inactivityTimeoutSeconds: TimeInterval
    ) async throws -> StopReason {
        let startedAt = Date()
        markPromptActivity(appState: appState, for: monitorSessionId)
        let pollIntervalSeconds = min(
            appState.promptResponsePollIntervalSecondsForLifecycle,
            max(0.05, inactivityTimeoutSeconds / 2)
        )
        let maxWaitSeconds = max(
            inactivityTimeoutSeconds,
            appState.promptResponseMaxWaitSecondsForLifecycle
        )
        let client = service.client

        return try await withThrowingTaskGroup(of: StopReason.self) { group in
            group.addTask {
                try await ACPService(client: client).sendPrompt(
                    sessionId: sessionId,
                    prompt: prompt,
                    traceId: traceId
                )
            }

            group.addTask { @MainActor in
                while true {
                    try await Task.sleep(for: .seconds(pollIntervalSeconds))
                    let inactivity = promptInactivitySeconds(
                        appState: appState,
                        for: monitorSessionId,
                        fallback: startedAt
                    )
                    if inactivity < inactivityTimeoutSeconds {
                        continue
                    }

                    let promptStillActive = appState.isPrompting && appState.currentSessionId == monitorSessionId
                    if !promptStillActive {
                        throw CancellationError()
                    }

                    let elapsedSeconds = max(0, Date().timeIntervalSince(startedAt))
                    if elapsedSeconds >= maxWaitSeconds {
                        throw PromptResponseTimeoutError(seconds: maxWaitSeconds)
                    }

                    let shouldKeepWaiting = await shouldKeepWaitingForPromptAfterInactivity(
                        appState: appState,
                        sessionId: monitorSessionId,
                        traceId: traceId
                    )
                    if shouldKeepWaiting {
                        markPromptActivity(appState: appState, for: monitorSessionId)
                        continue
                    }

                    throw PromptResponseTimeoutError(seconds: inactivityTimeoutSeconds)
                }
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    @MainActor
    private static func shouldKeepWaitingForPromptAfterInactivity(
        appState: PromptLifecycleAppState,
        sessionId: String,
        traceId: String?
    ) async -> Bool {
        let cachedState = appState.daemonSessions.first(where: { $0.sessionId == sessionId })?.state
        guard let daemon = appState.daemonClientForPromptLifecycle else {
            return isBusyDaemonSessionState(cachedState)
        }

        do {
            let sessions = try await fetchDaemonSessionsForPromptWatchdog(
                daemon: daemon,
                traceId: traceId
            )
            if let refreshed = sessions.first(where: { $0.sessionId == sessionId }) {
                if let index = appState.daemonSessions.firstIndex(where: { $0.sessionId == sessionId }) {
                    appState.daemonSessions[index] = refreshed
                } else {
                    appState.daemonSessions.append(refreshed)
                }
                let busy = isBusyDaemonSessionState(refreshed.state)
                if busy {
                    Log.log(
                        level: "warning",
                        component: "PromptLifecycle",
                        "prompt watchdog deferred timeout; daemon state=\(refreshed.state)",
                        traceId: traceId,
                        sessionId: sessionId
                    )
                }
                return busy
            }
            return false
        } catch {
            let cachedBusy = isBusyDaemonSessionState(cachedState)
            Log.log(
                level: "warning",
                component: "PromptLifecycle",
                "prompt watchdog daemon state check failed (cachedBusy=\(cachedBusy)): \(error.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId
            )
            return cachedBusy
        }
    }

    nonisolated private static func fetchDaemonSessionsForPromptWatchdog(
        daemon: DaemonClient,
        traceId: String?
    ) async throws -> [DaemonSessionInfo] {
        try await daemon.listSessions(traceId: traceId)
    }

    private static func isBusyDaemonSessionState(_ state: String?) -> Bool {
        guard let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "starting"
            || normalized == "prompting"
            || normalized == "draining"
    }

    @MainActor
    private static func promptInactivitySeconds(
        appState: PromptLifecycleAppState,
        for sessionId: String,
        fallback: Date
    ) -> TimeInterval {
        let lastActivity = appState.promptLastActivityAtForLifecycle[sessionId] ?? fallback
        return max(0, Date().timeIntervalSince(lastActivity))
    }

    @MainActor
    private static func presentPromptError(
        appState: PromptLifecycleAppState,
        _ error: Error
    ) {
        let presentation = userFacingPromptError(error)
        let assistant = appState.promptLifecycleLastAssistantMessage()
        let errorLine = "[Error: \(presentation.inline)]"
        if assistant.content.isEmpty {
            assistant.content = errorLine
        } else {
            assistant.content += "\n\(errorLine)"
        }
        if let guidance = presentation.guidance {
            appState.promptLifecycleAddSystemMessage(guidance)
        }
        appState.promptLifecycleContentDidChange()
    }

    private static func userFacingPromptError(_ error: Error) -> (inline: String, guidance: String?) {
        if let promptTimeout = error as? PromptResponseTimeoutError {
            let seconds = max(1, Int(promptTimeout.seconds.rounded()))
            return (
                "Timed out waiting for model response.",
                "No terminal response or streaming updates were received within \(seconds)s. You can resend the message."
            )
        }

        if error is CancellationError {
            return (
                "Connection interrupted while waiting for a response.",
                "Connection dropped during the request. Please resend after reconnecting."
            )
        }

        guard let acpError = error as? ACPError else {
            return (error.localizedDescription, nil)
        }

        func trimmedSummary(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            let maxLength = 220
            guard text.count > maxLength else { return text }
            let end = text.index(text.startIndex, offsetBy: maxLength)
            return String(text[..<end]) + "…"
        }

        if acpError.isModelUnavailable {
            if let requestID = acpError.backendRequestID {
                return (
                    "Model unavailable on current provider group.",
                    "Model routing failed (`model_not_found`, request id: \(requestID)). Try switching model/group, then resend."
                )
            }
            return (
                "Model unavailable on current provider group.",
                "Model routing failed (`model_not_found`). Try switching model/group, then resend."
            )
        }

        if acpError.isServiceOverloaded {
            let detail = trimmedSummary(acpError.summary)
            if let detail {
                return (
                    "Upstream service is temporarily overloaded.",
                    "The provider returned a temporary overload/service-unavailable error. Wait a few seconds and resend. Details: \(detail)"
                )
            }
            return (
                "Upstream service is temporarily overloaded.",
                "The provider returned a temporary overload/service-unavailable error. Wait a few seconds and resend."
            )
        }

        if acpError.isQueryClosedBeforeResponse {
            return (
                "Upstream request ended before a response arrived.",
                "The backend closed this query before sending a terminal response. Retry the message; if this repeats, reopen the session."
            )
        }

        if acpError.isNotAttached {
            return (
                "Session is no longer attached.",
                "Server session detached. Re-open the session and retry."
            )
        }

        if acpError.isSessionNotFound {
            return (
                "Session not found on server.",
                "Session no longer exists remotely. Create a new session to continue."
            )
        }

        if acpError.rpcCode == -32603 {
            if let detail = trimmedSummary(acpError.summary), detail.caseInsensitiveCompare("Internal error") != .orderedSame {
                return (
                    "Server failed while processing this prompt.",
                    detail
                )
            }
            return (
                "Server failed while processing this prompt.",
                "The server returned an internal error. Please retry in a moment."
            )
        }

        return (acpError.errorDescription ?? error.localizedDescription, nil)
    }

    private static func normalizePromptSendError(_ error: Error, timeoutSeconds: TimeInterval) -> Error {
        if let appStateError = error as? AppStateError,
           case .timeout = appStateError {
            return PromptResponseTimeoutError(seconds: timeoutSeconds)
        }
        return error
    }
}
