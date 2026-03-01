import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var forceScrollToken = 0

    var body: some View {
        VStack(spacing: 0) {
            ChatMessageListView(
                messages: appState.messages,
                isPrompting: appState.isPrompting,
                suspendAnimations: appState.suspendChatListAnimations,
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
        .onAppear {
            triggerInterruptedSessionRecovery()
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            triggerInterruptedSessionRecovery()
        }
        .onDisappear {
            Task {
                await appState.discardEmptyActiveSessionIfNeeded(modelContext: modelContext)
            }
        }
    }

    private func triggerInterruptedSessionRecovery() {
        Task {
            await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        }
    }
}
