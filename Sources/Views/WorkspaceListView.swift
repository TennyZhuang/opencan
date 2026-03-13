import SwiftUI
import SwiftData

struct WorkspaceListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let node: Node
    @State private var showAddWorkspace = false
    @State private var newName = ""
    @State private var newPath = ""
    @State private var pendingWorkspace: PendingWorkspace?
    @State private var showCreateDirectoryDialog = false
    @State private var workspaceCreationError: String?

    var body: some View {
        Group {
            if appState.connectionStatus == .connecting,
               appState.activeNode?.persistentModelID == node.persistentModelID {
                connectingView
            } else if appState.connectionStatus == .failed,
                      appState.activeNode?.persistentModelID == node.persistentModelID {
                connectingView
            } else {
                workspaceListContent
            }
        }
        .background(Brutal.cream.ignoresSafeArea())
        .navigationTitle(node.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(Brutal.display(17, weight: .bold))
                        .foregroundStyle(.black)
                    ForEach(nodeAgentBadges) { agent in
                        AgentAvailabilityBadge(agent: agent)
                    }
                }
                .lineLimit(1)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddWorkspace = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                        .foregroundStyle(.black)
                }
            }
        }
        .alert("Add Workspace", isPresented: $showAddWorkspace) {
            TextField("Name", text: $newName)
            TextField("Remote Path", text: $newPath)
            Button("Add") { addWorkspace() }
            Button("Cancel", role: .cancel) {
                clearWorkspaceForm()
            }
        }
        .confirmationDialog(
            "Create Remote Directory?",
            isPresented: $showCreateDirectoryDialog,
            titleVisibility: .visible,
            presenting: pendingWorkspace
        ) { pending in
            Button("Create Directory and Add Workspace") {
                Task {
                    await createDirectoryAndAddWorkspace(pending)
                }
            }
            Button("Add Workspace Without Creating Directory") {
                addWorkspaceRecord(name: pending.name, path: pending.path)
                self.pendingWorkspace = nil
            }
            Button("Cancel", role: .cancel) {
                self.pendingWorkspace = nil
            }
        } message: { pending in
            Text("Remote path '\(pending.path)' does not exist on \(node.name). Create it now?")
        }
        .alert(
            "Unable to Create Workspace",
            isPresented: workspaceCreationErrorBinding
        ) {
            Button("OK", role: .cancel) {
                workspaceCreationError = nil
            }
        } message: {
            Text(workspaceCreationError ?? "Unknown error")
        }
        .onAppear {
            let isSameNode = appState.activeNode?.persistentModelID == node.persistentModelID
            if appState.connectionStatus == .connected, isSameNode {
                Task { await appState.refreshAvailableAgents() }
            } else if appState.connectionStatus == .connecting, isSameNode {
                // Already connecting to this node, wait
            } else if OpenCANApp.isUITesting && !OpenCANApp.isUIIntegrationTesting {
                if let workspace = node.workspaces?.first {
                    appState.connectMock(workspace: workspace, scenario: OpenCANApp.uiTestMockScenario)
                }
            } else {
                appState.connect(node: node)
            }
        }
    }

    private var nodeAgentBadges: [AgentKind] {
        guard appState.activeNode?.persistentModelID == node.persistentModelID else { return [] }
        guard appState.connectionStatus == .connected else { return [] }
        guard appState.hasReliableAgentAvailability else { return [] }
        return appState.availableNodeAgents
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            if appState.connectionStatus == .connecting {
                if let progress = appState.daemonUploadProgress {
                    VStack(spacing: 12) {
                        Text("INSTALLING DAEMON")
                            .font(Brutal.mono(12, weight: .bold))
                            .foregroundStyle(.black)
                        ProgressView(value: progress)
                            .tint(Brutal.lime)
                        Text("\(Int(progress * 100))%")
                            .font(Brutal.mono(11))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                    .padding(20)
                    .brutalCard(fill: .white)
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.black)
                        Text("Connecting to \(node.name)...")
                            .font(Brutal.display(15))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
            } else if let error = appState.connectionError {
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.black)
                    Text(error)
                        .font(Brutal.mono(12))
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                    Button("Retry") { appState.connect(node: node) }
                        .buttonStyle(BrutalButtonStyle(fill: Brutal.mint, compact: true))
                }
                .padding(20)
                .brutalCard(fill: Brutal.pink.opacity(0.2))
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceListContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Connection status banner
                HStack(spacing: 8) {
                    Circle()
                        .fill(Brutal.lime)
                        .frame(width: 8, height: 8)
                    Text("CONNECTED")
                        .font(Brutal.mono(11, weight: .bold))
                        .foregroundStyle(.black)
                    Spacer()
                    BrutalChip("\((node.workspaces ?? []).count) workspaces", fill: Brutal.cyan, fontSize: 9)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brutal.lime.opacity(0.12))
                .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))

                ForEach(node.workspaces ?? []) { workspace in
                    NavigationLink {
                        SessionPickerView(workspace: workspace)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(workspace.name)
                                    .font(Brutal.display(16, weight: .bold))
                                    .foregroundStyle(.black)
                                Text(workspace.path)
                                    .font(Brutal.mono(12))
                                    .foregroundStyle(.black.opacity(0.6))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Brutal.display(14, weight: .bold))
                                .foregroundStyle(.black.opacity(0.4))
                        }
                        .padding(16)
                        .brutalCard(fill: .white)
                    }
                    .buttonStyle(.plain)
                }

                if (node.workspaces ?? []).isEmpty {
                    Text("NO WORKSPACES YET")
                        .font(Brutal.mono(14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.4))
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    @MainActor
    private func addWorkspace() {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty else { return }
        Task {
            await validateWorkspacePathAndAdd(name: trimmedName, path: trimmedPath)
        }
    }

    @MainActor
    private func validateWorkspacePathAndAdd(name: String, path: String) async {
        let shouldVerifyRemotePath = appState.connectionStatus == .connected
            && appState.activeNode?.persistentModelID == node.persistentModelID

        guard shouldVerifyRemotePath else {
            addWorkspaceRecord(name: name, path: path)
            clearWorkspaceForm()
            return
        }

        do {
            let exists = try await appState.workspaceDirectoryExists(path: path)
            if exists {
                addWorkspaceRecord(name: name, path: path)
            } else {
                pendingWorkspace = PendingWorkspace(name: name, path: path)
                showCreateDirectoryDialog = true
            }
            clearWorkspaceForm()
        } catch {
            clearWorkspaceForm()
            workspaceCreationError = "Failed to validate remote path: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createDirectoryAndAddWorkspace(_ pending: PendingWorkspace) async {
        do {
            try await appState.createWorkspaceDirectory(path: pending.path)
            addWorkspaceRecord(name: pending.name, path: pending.path)
            pendingWorkspace = nil
        } catch {
            workspaceCreationError = "Failed to create remote directory '\(pending.path)': \(error.localizedDescription)"
        }
    }

    @MainActor
    private func addWorkspaceRecord(name: String, path: String) {
        let ws = Workspace(name: name, path: path)
        ws.node = node
        modelContext.insert(ws)
    }

    @MainActor
    private func clearWorkspaceForm() {
        newName = ""
        newPath = ""
    }

    private var workspaceCreationErrorBinding: Binding<Bool> {
        Binding(
            get: { workspaceCreationError != nil },
            set: { isPresented in
                if !isPresented {
                    workspaceCreationError = nil
                }
            }
        )
    }

    private func deleteWorkspaces(at offsets: IndexSet) {
        let workspaces = node.workspaces ?? []
        for index in offsets {
            modelContext.delete(workspaces[index])
        }
    }

    private struct PendingWorkspace {
        let name: String
        let path: String
    }
}

struct AgentAvailabilityBadge: View {
    let agent: AgentKind

    var body: some View {
        BrutalChip(agent.displayName, fill: color, fontSize: 10)
    }

    private var color: Color {
        switch agent {
        case .claude: Brutal.cyan
        case .codex: Brutal.lavender
        }
    }
}
