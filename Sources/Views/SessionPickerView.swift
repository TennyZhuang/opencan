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
                ProgressView()
                Text("Connecting to \(workspace.node?.name ?? "node")...")
                    .foregroundStyle(.secondary)
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

    private var filteredRemoteSessions: [(sessionId: String, cwd: String?, title: String?)] {
        let normalizedPath = workspace.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return appState.remoteSessions.filter {
            guard let cwd = $0.cwd else { return false }
            return cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedPath
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

            if !filteredRemoteSessions.isEmpty {
                Section("Remote Sessions") {
                    ForEach(filteredRemoteSessions, id: \.sessionId) { session in
                        Button {
                            Task { await resume(sessionId: session.sessionId) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let title = session.title {
                                        Text(title)
                                            .lineLimit(1)
                                    }
                                    Text(session.sessionId)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if loadingSessionId == session.sessionId {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(appState.isCreatingSession)
                    }
                }
            }

            let localSessions = (workspace.sessions ?? [])
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
            if !localSessions.isEmpty {
                Section("Recent Sessions") {
                    ForEach(localSessions) { session in
                        Button {
                            Task { await resume(sessionId: session.sessionId) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title ?? session.sessionId)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                    Text(session.lastUsedAt.formatted(.relative(presentation: .named)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if loadingSessionId == session.sessionId {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(appState.isCreatingSession)
                    }
                }
            }
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
