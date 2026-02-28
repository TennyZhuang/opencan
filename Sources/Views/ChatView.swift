import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @State private var forceScrollToken = 0

    var body: some View {
        VStack(spacing: 0) {
            ChatMessageListView(
                messages: appState.messages,
                isPrompting: appState.isPrompting,
                contentVersion: appState.contentVersion,
                forceScrollToken: forceScrollToken
            )
            .onChange(of: appState.forceScrollToBottom) {
                guard appState.forceScrollToBottom else { return }
                appState.forceScrollToBottom = false
                forceScrollToken += 1
            }

            Divider()
            InputBarView()
        }
        .navigationTitle(appState.activeWorkspace?.name ?? "Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                }
            }
        }
    }
}
