import SwiftUI
import SwiftData

func workspacePathMatchesConversationCwd(workspacePath: String, conversationCwd: String, username: String?) -> Bool {
    let workspaceKeys = remotePathMatchKeys(workspacePath, username: username)
    guard !workspaceKeys.isEmpty else { return false }
    let conversationKeys = remotePathMatchKeys(conversationCwd, username: username)
    guard !conversationKeys.isEmpty else { return false }
    return !workspaceKeys.isDisjoint(with: conversationKeys)
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

/// Build merged conversation rows for a workspace by combining daemon + local records.
func mergeWorkspaceSessions(
    workspacePath: String,
    username: String?,
    daemonConversations: [DaemonConversationInfo],
    localSessions: [Session]
) -> [UnifiedSession] {
    var localByConversationID: [String: Session] = [:]
    for localSession in localSessions {
        let conversationId = localSession.conversationId
        if let existing = localByConversationID[conversationId],
           existing.lastUsedAt >= localSession.lastUsedAt {
            continue
        }
        localByConversationID[conversationId] = localSession
    }

    var daemonByConversationID: [String: DaemonConversationInfo] = [:]
    for conversation in daemonConversations {
        let isKnownLocalConversation = localByConversationID[conversation.conversationId] != nil
        guard isKnownLocalConversation || workspacePathMatchesConversationCwd(
            workspacePath: workspacePath,
            conversationCwd: conversation.cwd,
            username: username
        ) else {
            continue
        }
        daemonByConversationID[conversation.conversationId] = conversation
    }

    let allIds = Set(daemonByConversationID.keys).union(localByConversationID.keys)
    let unified = allIds.map { conversationId -> UnifiedSession in
        let daemon = daemonByConversationID[conversationId]
        let local = localByConversationID[conversationId]
        return UnifiedSession(
            conversationId: conversationId,
            runtimeId: daemon?.runtimeId ?? local?.runtimeId,
            daemonState: daemon?.state,
            cwd: daemon?.cwd ?? local?.conversationCwd ?? workspacePath,
            lastEventSeq: daemon?.lastEventSeq,
            title: local?.title,
            daemonTitle: daemon?.title,
            lastUsedAt: local?.lastUsedAt,
            daemonUpdatedAt: daemon?.updatedAt,
            agentID: local?.agentID,
            agentCommand: local?.agentCommand ?? daemon?.command,
            hasLocalRecord: local != nil
        )
    }
    .filter { !$0.isEmptyPlaceholder }

    return unified.sorted { lhs, rhs in
        let lhsRunning = lhs.displayState == "running"
        let rhsRunning = rhs.displayState == "running"
        if lhsRunning != rhsRunning { return lhsRunning }

        let lhsAttached = lhs.displayState == "attached"
        let rhsAttached = rhs.displayState == "attached"
        if lhsAttached != rhsAttached { return lhsAttached }

        let lhsDate = lhs.effectiveLastUsedAt ?? .distantPast
        let rhsDate = rhs.effectiveLastUsedAt ?? .distantPast
        return lhsDate > rhsDate
    }
}

struct SessionPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AgentCommandStore.defaultAgentKey) private var defaultAgentID = AgentKind.claude.rawValue
    let workspace: Workspace
    @State private var navigateToChat = false
    @State private var loadingConversationId: String?
    @State private var openErrorMessage: String?

    var body: some View {
        sessionListView
            .background(Brutal.cream.ignoresSafeArea())
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(isPresented: $navigateToChat) {
                ChatView()
            }
            .alert(
                "Cannot Open Session",
                isPresented: Binding(
                    get: { openErrorMessage != nil },
                    set: { showing in
                        if !showing { openErrorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(openErrorMessage ?? "Unknown error")
            }
            .onAppear {
                appState.activeWorkspace = workspace
                Task {
                    await appState.refreshDaemonSessions()
                    await appState.refreshAvailableAgents()
                }
            }
            .onDisappear {
                if appState.activeWorkspace?.persistentModelID == workspace.persistentModelID {
                    appState.activeWorkspace = nil
                }
            }
    }

    private var unifiedSessions: [UnifiedSession] {
        mergeWorkspaceSessions(
            workspacePath: workspace.path,
            username: workspace.node?.username,
            daemonConversations: appState.daemonConversations,
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
        return filtered.sorted { lhs, rhs in
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
        ScrollView {
            VStack(spacing: 12) {
                // New Session button
                newSessionButton
                    .padding(.top, 8)

                // Session list
                let sessions = unifiedSessions
                if !sessions.isEmpty {
                    HStack(spacing: 6) {
                        Text("SESSIONS")
                            .font(Brutal.mono(12, weight: .bold))
                            .foregroundStyle(.black.opacity(0.5))
                        BrutalChip("\(sessions.count)", fill: Brutal.cyan, fontSize: 9)
                        let running = sessions.filter {
                            ["running", "prompting", "draining", "attached"].contains($0.displayState)
                        }.count
                        if running > 0 {
                            BrutalChip("\(running) active", fill: Brutal.lime, fontSize: 9)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)

                    ForEach(sessions) { session in
                        Button {
                            Task { @MainActor in await openConversation(conversationId: session.conversationId) }
                        } label: {
                            sessionCard(session)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isCreatingSession || !session.isResumable)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var newSessionButton: some View {
        if OpenCANApp.isUITesting {
            Button {
                guard let agent = defaultCreateAgent else { return }
                Task { @MainActor in await createNew(agent: agent) }
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .font(Brutal.display(16, weight: .bold))
                    Text("New Session")
                        .font(Brutal.display(16, weight: .bold))
                    if appState.isCreatingSession, loadingConversationId == nil {
                        Spacer()
                        ProgressView()
                            .tint(.black)
                    }
                }
                .foregroundStyle(.black)
            }
            .buttonStyle(BrutalButtonStyle(fill: Brutal.lime))
            .disabled(appState.isCreatingSession || defaultCreateAgent == nil)
        } else {
            Menu {
                if appState.hasReliableAgentAvailability && availableAgents.isEmpty {
                    Text("No available agents on this node")
                } else {
                    ForEach(availableAgents) { agent in
                        Button {
                            Task { @MainActor in await createNew(agent: agent) }
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
                    Image(systemName: "plus.circle")
                        .font(Brutal.display(16, weight: .bold))
                    Text("New Session")
                        .font(Brutal.display(16, weight: .bold))
                    if appState.isCreatingSession, loadingConversationId == nil {
                        Spacer()
                        ProgressView()
                            .tint(.black)
                    }
                }
                .foregroundStyle(.black)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brutalCard(fill: Brutal.lime)
            }
            .disabled(appState.isCreatingSession || (appState.hasReliableAgentAvailability && availableAgents.isEmpty))
        }
    }

    private func sessionCard(_ session: UnifiedSession) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(Brutal.mono(14, weight: .medium))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                if let agentName = session.agentDisplayName {
                    Text(agentName)
                        .font(Brutal.mono(11))
                        .foregroundStyle(.black.opacity(0.5))
                }
                Text(session.conversationId)
                    .font(Brutal.mono(10))
                    .foregroundStyle(.black.opacity(0.3))
                    .lineLimit(1)
                if let runtimeId = session.effectiveRuntimeId,
                   runtimeId != session.conversationId {
                    Text("runtime: \(runtimeId)")
                        .font(Brutal.mono(10))
                        .foregroundStyle(.black.opacity(0.3))
                        .lineLimit(1)
                }
                if let date = session.effectiveLastUsedAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(Brutal.mono(11))
                        .foregroundStyle(.black.opacity(0.5))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                SessionStateBadge(state: session.displayState)
                if loadingConversationId == session.conversationId {
                    ProgressView()
                        .tint(.black)
                }
            }
        }
        .padding(14)
        .brutalCard(fill: sessionCardFill(session), shadow: Brutal.shadowSm)
    }

    private func sessionCardFill(_ session: UnifiedSession) -> Color {
        switch session.displayState {
        case "running", "prompting", "draining": Brutal.lime.opacity(0.15)
        case "attached": Brutal.cyan.opacity(0.15)
        case "starting": Brutal.orange.opacity(0.15)
        default: .white
        }
    }

    @MainActor
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

    @MainActor
    private func openConversation(conversationId: String) async {
        appState.isCreatingSession = true
        loadingConversationId = conversationId
        defer {
            appState.isCreatingSession = false
            loadingConversationId = nil
        }
        do {
            try await appState.openSession(conversationId: conversationId, modelContext: modelContext)
            navigateToChat = true
        } catch {
            appState.connectionError = error.localizedDescription
            openErrorMessage = error.localizedDescription
        }
    }
}

/// Colored badge showing the daemon conversation state.
struct SessionStateBadge: View {
    let state: String

    var body: some View {
        BrutalChip(displayText, fill: backgroundColor, fontSize: 10)
    }

    private var displayText: String {
        switch state {
        case "running", "prompting", "draining": "Running"
        case "attached": "Attached"
        case "ready", "idle", "completed": "Ready"
        case "restorable", "external": "Restorable"
        case "unavailable", "dead": "Unavailable"
        case "starting": "Starting"
        default: state.capitalized
        }
    }

    private var backgroundColor: Color {
        switch state {
        case "running", "prompting", "draining": Brutal.lime
        case "attached": Brutal.mint
        case "ready", "idle", "completed": Color(hex: 0xDDDDDD)
        case "restorable", "external": Brutal.lavender
        case "unavailable", "dead": Brutal.pink
        case "starting": Brutal.orange
        default: Color(hex: 0xDDDDDD)
        }
    }
}
