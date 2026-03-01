import SwiftUI
import SwiftData

func workspacePathMatchesSessionCwd(workspacePath: String, sessionCwd: String, username: String?) -> Bool {
    let workspaceKeys = remotePathMatchKeys(workspacePath, username: username)
    guard !workspaceKeys.isEmpty else { return false }
    let sessionKeys = remotePathMatchKeys(sessionCwd, username: username)
    guard !sessionKeys.isEmpty else { return false }
    return !workspaceKeys.isDisjoint(with: sessionKeys)
}

/// Build path match keys for remote UNIX-like paths.
/// Keys normalize slashes and include common home-path expansions (`~`, `/home/<user>`, `/Users/<user>`).
func remotePathMatchKeys(_ rawPath: String, username: String?) -> Set<String> {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var candidates: Set<String> = [trimmed]

    if let username {
        let linuxHome = "/home/\(username)"
        let macHome = "/Users/\(username)"

        if trimmed == "~" {
            candidates.insert(linuxHome)
            candidates.insert(macHome)
        } else if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            candidates.insert("\(linuxHome)/\(suffix)")
            candidates.insert("\(macHome)/\(suffix)")
        } else if trimmed == linuxHome {
            candidates.insert("~")
            candidates.insert(macHome)
        } else if trimmed.hasPrefix("\(linuxHome)/") {
            let suffix = String(trimmed.dropFirst(linuxHome.count + 1))
            candidates.insert("~/" + suffix)
            candidates.insert("\(macHome)/\(suffix)")
        } else if trimmed == macHome {
            candidates.insert("~")
            candidates.insert(linuxHome)
        } else if trimmed.hasPrefix("\(macHome)/") {
            let suffix = String(trimmed.dropFirst(macHome.count + 1))
            candidates.insert("~/" + suffix)
            candidates.insert("\(linuxHome)/\(suffix)")
        }
    }

    return Set(candidates.compactMap { normalizedRemotePathKey($0) })
}

private func normalizedRemotePathKey(_ rawPath: String) -> String? {
    let parts = rawPath
        .split(separator: "/")
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "/")
}

/// Build merged session rows for a workspace by combining daemon + local records.
/// External daemon sessions are suppressed when they are already tracked as
/// history sources of a local recovered session to avoid duplicate list items.
func mergeWorkspaceSessions(
    workspacePath: String,
    username: String?,
    daemonSessions: [DaemonSessionInfo],
    localSessions: [Session]
) -> [UnifiedSession] {
    let recoveredHistorySourceIDs: Set<String> = Set(localSessions.compactMap { local in
        guard let historySessionId = normalizedSessionID(local.historySessionId),
              historySessionId != local.sessionId else {
            return nil
        }
        return historySessionId
    })

    var daemonByID: [String: DaemonSessionInfo] = [:]
    for daemonSession in daemonSessions {
        guard workspacePathMatchesSessionCwd(
            workspacePath: workspacePath,
            sessionCwd: daemonSession.cwd,
            username: username
        ) else {
            continue
        }
        if daemonSession.state == "external",
           recoveredHistorySourceIDs.contains(daemonSession.sessionId) {
            continue
        }
        daemonByID[daemonSession.sessionId] = daemonSession
    }

    var localByID: [String: Session] = [:]
    for localSession in localSessions {
        if let existing = localByID[localSession.sessionId],
           existing.lastUsedAt >= localSession.lastUsedAt {
            continue
        }
        localByID[localSession.sessionId] = localSession
    }

    let allIds = Set(daemonByID.keys).union(localByID.keys)
    let unified = allIds.map { sessionId -> UnifiedSession in
        let daemon = daemonByID[sessionId]
        let local = localByID[sessionId]
        return UnifiedSession(
            sessionId: sessionId,
            daemonState: daemon?.state,
            cwd: daemon?.cwd ?? workspacePath,
            lastEventSeq: daemon?.lastEventSeq,
            title: local?.title,
            daemonTitle: daemon?.title,
            lastUsedAt: local?.lastUsedAt,
            daemonUpdatedAt: daemon?.updatedAt,
            agentID: local?.agentID,
            agentCommand: local?.agentCommand ?? daemon?.command
        )
    }
    .filter { !$0.isEmptyPlaceholder }

    return unified.sorted { lhs, rhs in
        let lhsActive = lhs.daemonState == "prompting" || lhs.daemonState == "draining"
        let rhsActive = rhs.daemonState == "prompting" || rhs.daemonState == "draining"
        if lhsActive != rhsActive { return lhsActive }

        let lhsDate = lhs.effectiveLastUsedAt ?? .distantPast
        let rhsDate = rhs.effectiveLastUsedAt ?? .distantPast
        return lhsDate > rhsDate
    }
}

private func normalizedSessionID(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
}

struct SessionPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AgentCommandStore.defaultAgentKey) private var defaultAgentID = AgentKind.claude.rawValue
    let workspace: Workspace
    @State private var navigateToChat = false
    @State private var loadingSessionId: String?

    var body: some View {
        sessionListView
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(isPresented: $navigateToChat) {
                ChatView()
            }
            .onAppear {
                appState.activeWorkspace = workspace
                Task {
                    await appState.refreshDaemonSessions()
                    await appState.refreshAvailableAgents()
                }
            }
            .onDisappear {
                // Clear activeWorkspace when leaving this view so stale state
                // doesn't leak into a sibling workspace's SessionPickerView
                // during navigation transitions.
                if appState.activeWorkspace?.persistentModelID == workspace.persistentModelID {
                    appState.activeWorkspace = nil
                }
            }
    }

    /// Merge daemon sessions and local SwiftData sessions into a single list.
    private var unifiedSessions: [UnifiedSession] {
        mergeWorkspaceSessions(
            workspacePath: workspace.path,
            username: workspace.node?.username,
            daemonSessions: appState.daemonSessions,
            localSessions: workspace.sessions ?? []
        )
    }

    private var availableAgents: [AgentKind] {
        let filtered: [AgentKind]
        if appState.hasReliableAgentAvailability {
            let availableSet = Set(appState.availableNodeAgents)
            filtered = AgentKind.allCases.filter { availableSet.contains($0) }
        } else {
            filtered = AgentKind.allCases
        }
        let preferred = AgentKind(rawValue: defaultAgentID)
        return filtered
            .sorted { lhs, rhs in
            if lhs == preferred { return true }
            if rhs == preferred { return false }
            return lhs.displayName < rhs.displayName
        }
    }

    private var defaultCreateAgent: AgentKind? {
        let preferred = AgentKind(rawValue: defaultAgentID)
        if let preferred, availableAgents.contains(preferred) {
            return preferred
        }
        return availableAgents.first
    }

    private var sessionListView: some View {
        List {
            Section {
                if OpenCANApp.isUITesting {
                    Button {
                        guard let agent = defaultCreateAgent else { return }
                        Task { await createNew(agent: agent) }
                    } label: {
                        HStack {
                            Label("New Session", systemImage: "plus.circle")
                            if appState.isCreatingSession, loadingSessionId == nil {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isCreatingSession || defaultCreateAgent == nil)
                } else {
                    Menu {
                        if appState.hasReliableAgentAvailability && availableAgents.isEmpty {
                            Text("No available agents on this node")
                        } else {
                            ForEach(availableAgents) { agent in
                                Button {
                                    Task { await createNew(agent: agent) }
                                } label: {
                                    let command = AgentCommandStore.command(for: agent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.displayName)
                                        Text(command)
                                            .font(.caption2)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Label("New Session", systemImage: "plus.circle")
                            if appState.isCreatingSession, loadingSessionId == nil {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isCreatingSession || (appState.hasReliableAgentAvailability && availableAgents.isEmpty))
                }
            }

            let sessions = unifiedSessions
            if !sessions.isEmpty {
                Section("Sessions") {
                    ForEach(sessions) { session in
                        Button {
                            Task { await resume(sessionId: session.sessionId) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.displayTitle)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let agentName = session.agentDisplayName {
                                        Text(agentName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(String(session.sessionId.prefix(8)) + "…")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    if let date = session.effectiveLastUsedAt {
                                        Text(date.formatted(.relative(presentation: .named)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                SessionStateBadge(state: session.displayState)
                                if loadingSessionId == session.sessionId {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(appState.isCreatingSession || !session.isResumable)
                    }
                }
            }
        }
        .refreshable {
            await appState.refreshDaemonSessions()
        }
    }

    private func createNew(agent: AgentKind) async {
        appState.isCreatingSession = true
        defer { appState.isCreatingSession = false }
        do {
            try await appState.createNewSession(modelContext: modelContext, agent: agent)
            navigateToChat = true
        } catch {
            appState.connectionError = error.localizedDescription
        }
    }

    private func resume(sessionId: String) async {
        appState.isCreatingSession = true
        loadingSessionId = sessionId
        defer {
            appState.isCreatingSession = false
            loadingSessionId = nil
        }
        do {
            try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)
            navigateToChat = true
        } catch {
            appState.connectionError = error.localizedDescription
        }
    }
}

/// Colored badge showing the daemon session state.
struct SessionStateBadge: View {
    let state: String

    var body: some View {
        Text(displayText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var displayText: String {
        switch state {
        case "idle": "Idle"
        case "prompting": "Running"
        case "draining": "Running"
        case "completed": "Done"
        case "dead": "Dead"
        case "starting": "Starting"
        case "history": "History"
        case "external": "External"
        default: state.capitalized
        }
    }

    private var backgroundColor: Color {
        switch state {
        case "idle": .gray
        case "prompting": .blue
        case "draining": .orange
        case "completed": .green
        case "dead": .red
        case "starting": .yellow
        case "history": .secondary
        case "external": .purple
        default: .gray
        }
    }
}
