import SwiftUI
import SwiftData

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
                Task { await appState.refreshDaemonSessions() }
            }
    }

    /// Merge daemon sessions and local SwiftData sessions into a single list.
    private var unifiedSessions: [UnifiedSession] {
        let normalizedPath = workspace.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Index daemon sessions (filtered by workspace cwd) by sessionId
        var daemonByID: [String: DaemonSessionInfo] = [:]
        for ds in appState.daemonSessions {
            if ds.cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedPath {
                daemonByID[ds.sessionId] = ds
            }
        }

        // Index local sessions by sessionId
        var localByID: [String: Session] = [:]
        for ls in workspace.sessions ?? [] {
            localByID[ls.sessionId] = ls
        }

        // Union all sessionIds
        let allIds = Set(daemonByID.keys).union(localByID.keys)

        let unified = allIds.map { sid -> UnifiedSession in
            let daemon = daemonByID[sid]
            let local = localByID[sid]
            return UnifiedSession(
                sessionId: sid,
                daemonState: daemon?.state,
                cwd: daemon?.cwd ?? workspace.path,
                lastEventSeq: daemon?.lastEventSeq,
                title: local?.title,
                daemonTitle: daemon?.title,
                lastUsedAt: local?.lastUsedAt,
                agentID: local?.agentID,
                agentCommand: local?.agentCommand ?? daemon?.command
            )
        }

        // Sort: active (prompting/draining) first, then by lastUsedAt desc.
        // External and daemon sessions are intermixed by time.
        return unified.sorted { a, b in
            let aActive = a.daemonState == "prompting" || a.daemonState == "draining"
            let bActive = b.daemonState == "prompting" || b.daemonState == "draining"
            if aActive != bActive { return aActive }

            let aDate = a.lastUsedAt ?? .distantPast
            let bDate = b.lastUsedAt ?? .distantPast
            return aDate > bDate
        }
    }

    private var availableAgents: [AgentKind] {
        let preferred = AgentKind(rawValue: defaultAgentID)
        return AgentKind.allCases.sorted { lhs, rhs in
            if lhs == preferred { return true }
            if rhs == preferred { return false }
            return lhs.displayName < rhs.displayName
        }
    }

    private var defaultAgent: AgentKind {
        AgentKind(rawValue: defaultAgentID) ?? .claude
    }

    private var sessionListView: some View {
        List {
            Section {
                if OpenCANApp.isUITesting {
                    Button {
                        Task { await createNew(agent: defaultAgent) }
                    } label: {
                        HStack {
                            Label("New Session", systemImage: "plus.circle")
                            if appState.isCreatingSession, loadingSessionId == nil {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isCreatingSession)
                } else {
                    Menu {
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
                    } label: {
                        HStack {
                            Label("New Session", systemImage: "plus.circle")
                            if appState.isCreatingSession, loadingSessionId == nil {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isCreatingSession)
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
                                    if let date = session.lastUsedAt {
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
