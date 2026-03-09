import SwiftUI
import SwiftData

struct NodeListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Node.name) private var nodes: [Node]
    @State private var showAddNode = false
    @State private var showAgentSettings = false
    @State private var showDiagnostics = false
    @State private var showAbout = false

    var body: some View {
        List {
            brandingRow

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
                    Button("About & Licenses") {
                        showAbout = true
                    }
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
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    private var brandingRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 96, height: 96)

                Image("LogoWordmark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 36)

                Image("LogoTagline")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 20)
            }
            Spacer()
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenCAN logo")
    }

    private func deleteNodes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(nodes[index])
        }
    }
}
