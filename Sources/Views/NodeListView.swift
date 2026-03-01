import SwiftUI
import SwiftData

struct NodeListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Node.name) private var nodes: [Node]
    @State private var showAddNode = false
    @State private var showAgentSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        List {
            ForEach(nodes) { node in
                NavigationLink {
                    WorkspaceListView(node: node)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name)
                            .font(.headline)
                        Text("\(node.username)@\(node.host):\(node.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let jump = node.jumpServer {
                            Text("via \(jump.name)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete(perform: deleteNodes)
        }
        .navigationTitle("Nodes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Agent Settings") {
                        showAgentSettings = true
                    }
                    Button("Diagnostics") {
                        showDiagnostics = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddNode = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddNode) {
            NodeFormView()
        }
        .sheet(isPresented: $showAgentSettings) {
            AgentSettingsView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticView()
        }
    }

    private func deleteNodes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(nodes[index])
        }
        do {
            try modelContext.save()
            let remainingKeys = try modelContext.fetch(FetchDescriptor<SSHKeyPair>())
            let validIdentifiers = SSHKeyPair.keychainIdentifiers(in: remainingKeys)
            let removed = try SSHKeyPair.cleanupOrphanedKeychainEntries(validIdentifiers: validIdentifiers)
            if removed > 0 {
                Log.toFile("[Security] Removed \(removed) orphaned SSH keychain entr\(removed == 1 ? "y" : "ies") after node deletion")
            }
        } catch {
            Log.toFile("[Security] Failed to clean up SSH keychain entries after node deletion: \(error)")
        }
    }
}
