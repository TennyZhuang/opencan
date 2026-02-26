import SwiftUI
import SwiftData

struct SessionPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let workspace: Workspace
    @State private var hasConnected = false
    @State private var navigateToChat = false
    @State private var loadingSessionId: String?

    var body: some View {
        Group {
            if !hasConnected {
                connectingView
            } else {
                sessionListView
            }
        }
        .navigationTitle("Sessions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(isPresented: $navigateToChat) {
            ChatView()
        }
        .onAppear {
            let isSameWorkspace = appState.activeWorkspace?.persistentModelID == workspace.persistentModelID
            if appState.connectionStatus == .connected, isSameWorkspace {
                hasConnected = true
                Task { await appState.refreshDaemonSessions() }
            } else if appState.connectionStatus == .connecting, isSameWorkspace {
                // Already connecting to this workspace, wait for it
            } else if OpenCANApp.isUITesting {
                appState.connectMock(workspace: workspace)
            } else {
                appState.connect(workspace: workspace)
            }
        }
        .onChange(of: appState.connectionStatus) {
            if appState.connectionStatus == .connected,
               appState.activeWorkspace?.persistentModelID == workspace.persistentModelID {
                hasConnected = true
            }
        }
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            if appState.connectionStatus == .connecting {
                if let progress = appState.daemonUploadProgress {
                    ProgressView(value: progress) {
                        Text("Installing daemon...")
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                } else {
                    ProgressView()
                    Text("Connecting to \(workspace.node?.name ?? "node")...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = appState.connectionError {
                Image(systemName: "xmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") { appState.connect(workspace: workspace) }
            }
        }
        .padding()
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
                lastUsedAt: local?.lastUsedAt
            )
        }

        // Sort: active (prompting/draining) first → daemon-known → by lastUsedAt desc
        return unified.sorted { a, b in
            let aActive = a.daemonState == "prompting" || a.daemonState == "draining"
            let bActive = b.daemonState == "prompting" || b.daemonState == "draining"
            if aActive != bActive { return aActive }

            let aDaemon = a.daemonState != nil
            let bDaemon = b.daemonState != nil
            if aDaemon != bDaemon { return aDaemon }

            let aDate = a.lastUsedAt ?? .distantPast
            let bDate = b.lastUsedAt ?? .distantPast
            return aDate > bDate
        }
    }

    private var sessionListView: some View {
        List {
            Section {
                Button {
                    Task { await createNew() }
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

    private func createNew() async {
        appState.isCreatingSession = true
        defer { appState.isCreatingSession = false }
        do {
            try await appState.createNewSession(modelContext: modelContext)
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
        default: .gray
        }
    }
}
