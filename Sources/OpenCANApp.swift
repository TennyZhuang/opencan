import SwiftUI
import SwiftData

@main
struct OpenCANApp: App {
    @State private var appState = AppState()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: SSHKeyPair.self, Node.self, Workspace.self, Session.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear { seedDemoDataIfNeeded() }
        }
        .modelContainer(modelContainer)
    }

    /// On first launch, seed the database with the demo cp32 config.
    private func seedDemoDataIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "demoDataSeeded") else { return }

        let context = ModelContext(modelContainer)

        // Import the bundled SSH key
        guard let keyURL = Bundle.main.url(forResource: "id_rsa_zd", withExtension: nil),
              let keyData = try? Data(contentsOf: keyURL) else {
            Log.toFile("[Seed] Demo SSH key not found in bundle, skipping seed")
            return
        }

        let key = SSHKeyPair(name: "id_rsa_zd", privateKeyPEM: keyData)
        context.insert(key)

        let jumpNode = Node(name: "cp01", host: "42.62.6.84", port: 22, username: "tyzhuang")
        jumpNode.sshKey = key
        context.insert(jumpNode)

        let targetNode = Node(name: "cp32", host: "192.168.2.29", port: 22, username: "tyzhuang")
        targetNode.sshKey = key
        targetNode.jumpServer = jumpNode
        context.insert(targetNode)

        let workspace = Workspace(name: "home", path: "/home/tyzhuang")
        workspace.node = targetNode
        context.insert(workspace)

        try? context.save()
        UserDefaults.standard.set(true, forKey: "demoDataSeeded")
    }
}
