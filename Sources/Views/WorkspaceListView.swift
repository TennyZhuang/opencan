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
        .navigationTitle(node.name)
        .toolbar {
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
