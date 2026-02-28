import SwiftUI
import SwiftData

struct WorkspaceListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let node: Node
    @State private var showAddWorkspace = false
    @State private var newName = ""
    @State private var newPath = ""

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
        .navigationTitle(node.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.headline)
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
                }
            }
        }
        .alert("Add Workspace", isPresented: $showAddWorkspace) {
            TextField("Name", text: $newName)
            TextField("Remote Path", text: $newPath)
            Button("Add") { addWorkspace() }
            Button("Cancel", role: .cancel) {
                newName = ""
                newPath = ""
            }
        }
        .onAppear {
            let isSameNode = appState.activeNode?.persistentModelID == node.persistentModelID
            if appState.connectionStatus == .connected, isSameNode {
                // Already connected to this node
                Task { await appState.refreshAvailableAgents() }
            } else if appState.connectionStatus == .connecting, isSameNode {
                // Already connecting to this node, wait
            } else if OpenCANApp.isUITesting {
                // UI tests use mock transport — connectMock needs a workspace
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
                    Text("Connecting to \(node.name)...")
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
                Button("Retry") { appState.connect(node: node) }
            }
        }
        .padding()
    }

    private var workspaceListContent: some View {
        List {
            ForEach(node.workspaces ?? []) { workspace in
                NavigationLink {
                    SessionPickerView(workspace: workspace)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.name)
                            .font(.headline)
                        Text(workspace.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete(perform: deleteWorkspaces)
        }
    }

    private func addWorkspace() {
        guard !newName.isEmpty, !newPath.isEmpty else { return }
        let ws = Workspace(name: newName, path: newPath)
        ws.node = node
        modelContext.insert(ws)
        newName = ""
        newPath = ""
    }

    private func deleteWorkspaces(at offsets: IndexSet) {
        let workspaces = node.workspaces ?? []
        for index in offsets {
            modelContext.delete(workspaces[index])
        }
    }
}

struct AgentAvailabilityBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch agent {
        case .claude: .blue
        case .codex: .purple
        }
    }
}
