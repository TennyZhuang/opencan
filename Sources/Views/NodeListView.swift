import SwiftUI
import SwiftData

struct NodeListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Node.name) private var nodes: [Node]
    @State private var showAddNode = false

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
    }

    private func deleteNodes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(nodes[index])
        }
    }
}
