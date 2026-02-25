import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $path) {
            NodeListView()
        }
        .onChange(of: appState.shouldPopToRoot) {
            if appState.shouldPopToRoot {
                path = NavigationPath()
                appState.shouldPopToRoot = false
            }
        }
    }
}
