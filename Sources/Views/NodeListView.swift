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
        ScrollView {
            VStack(spacing: 16) {
                brandingRow
                    .padding(.top, 20)

                if !nodes.isEmpty {
                    HStack {
                        Text("NODES")
                            .font(Brutal.mono(12, weight: .bold))
                            .foregroundStyle(.black.opacity(0.5))
                        BrutalChip("\(nodes.count)", fill: Brutal.cyan, fontSize: 10)
                        Spacer()
                    }
                }

                ForEach(nodes) { node in
                    NavigationLink {
                        WorkspaceListView(node: node)
                    } label: {
                        nodeCard(node)
                    }
                    .buttonStyle(.plain)
                }

                if nodes.isEmpty {
                    Text("NO NODES YET")
                        .font(Brutal.mono(14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.4))
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Brutal.cream.ignoresSafeArea())
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
                        .foregroundStyle(.black)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddNode = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                        .foregroundStyle(.black)
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

    private func nodeCard(_ node: Node) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(node.name)
                    .font(Brutal.display(17, weight: .bold))
                    .foregroundStyle(.black)
                Text("\(node.username)@\(node.host):\(node.port)")
                    .font(Brutal.mono(12))
                    .foregroundStyle(.black.opacity(0.6))
                if let jump = node.jumpServer {
                    BrutalChip("via \(jump.name)", fill: Brutal.orange, fontSize: 10)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Brutal.display(14, weight: .bold))
                .foregroundStyle(.black.opacity(0.4))
        }
        .padding(16)
        .brutalCard(fill: .white)
    }

    private var brandingRow: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 80, height: 80)

                Image("LogoWordmark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 32)

                Image("LogoTagline")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 18)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.white)
            .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenCAN logo")
    }

    private func deleteNodes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(nodes[index])
        }
    }
}
