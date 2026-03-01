import SwiftUI
import SwiftData

struct NodeFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SSHKeyPair.name) private var keys: [SSHKeyPair]
    @Query(sort: \Node.name) private var allNodes: [Node]

    var editingNode: Node?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var selectedKey: SSHKeyPair?
    @State private var selectedJump: Node?
    @State private var showImportKey = false
    @State private var importKeyName = ""
    @State private var importKeyPEM = ""
    @State private var importErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Node") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                }

                Section("SSH Key") {
                    Picker("Key", selection: $selectedKey) {
                        Text("None").tag(nil as SSHKeyPair?)
                        ForEach(keys) { key in
                            Text(key.name).tag(key as SSHKeyPair?)
                        }
                    }
                    Button("Import New Key...") {
                        showImportKey = true
                    }
                }

                Section("Jump Server") {
                    Picker("Jump Server", selection: $selectedJump) {
                        Text("None (direct)").tag(nil as Node?)
                        ForEach(availableJumpNodes) { node in
                            Text(node.name).tag(node as Node?)
                        }
                    }
                }
            }
            .navigationTitle(editingNode == nil ? "Add Node" : "Edit Node")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
                }
            }
            .onAppear { loadExisting() }
            .sheet(isPresented: $showImportKey) {
                importKeySheet
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            importErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "")
            }
        }
    }

    private var availableJumpNodes: [Node] {
        allNodes.filter { $0.persistentModelID != editingNode?.persistentModelID }
    }

    private var importKeySheet: some View {
        NavigationStack {
            Form {
                Section("Key Name") {
                    TextField("e.g. id_rsa_server", text: $importKeyName)
                        .textInputAutocapitalization(.never)
                }
                Section("Private Key (PEM)") {
                    TextEditor(text: $importKeyPEM)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("Import SSH Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importKeyName = ""
                        importKeyPEM = ""
                        showImportKey = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        if importKey() {
                            showImportKey = false
                        }
                    }
                    .disabled(importKeyName.isEmpty || importKeyPEM.isEmpty)
                }
            }
        }
    }

    private func loadExisting() {
        guard let node = editingNode else { return }
        name = node.name
        host = node.host
        port = String(node.port)
        username = node.username
        selectedKey = node.sshKey
        selectedJump = node.jumpServer
    }

    private func save() {
        let portNum = Int(port) ?? 22
        if let node = editingNode {
            node.name = name
            node.host = host
            node.port = portNum
            node.username = username
            node.sshKey = selectedKey
            node.jumpServer = selectedJump
        } else {
            let node = Node(name: name, host: host, port: portNum, username: username)
            node.sshKey = selectedKey
            node.jumpServer = selectedJump
            modelContext.insert(node)
        }
        dismiss()
    }

    @discardableResult
    private func importKey() -> Bool {
        guard !importKeyName.isEmpty, !importKeyPEM.isEmpty,
              let data = importKeyPEM.data(using: .utf8) else { return false }
        do {
            let key = try SSHKeyPair(name: importKeyName, privateKeyPEM: data)
            modelContext.insert(key)
            selectedKey = key
            importKeyName = ""
            importKeyPEM = ""
            return true
        } catch {
            importErrorMessage = error.localizedDescription
            return false
        }
    }
}
