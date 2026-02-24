import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.connectionStatus {
            case .disconnected, .connecting, .failed:
                ConnectionView()
            case .connected:
                ChatView()
            }
        }
    }
}
