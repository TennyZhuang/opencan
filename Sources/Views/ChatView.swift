import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    /// Tracks whether the bottom anchor is visible.
    /// Used to decide auto-scroll when NOT actively streaming.
    @State private var isNearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.spacing) {
                        ForEach(appState.messages) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                        }
                        // Invisible anchor for scrollTo target.
                        // onAppear/onDisappear approximate whether user
                        // is scrolled near the bottom.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                // Streaming content changed (debounced).
                // During active prompting, always follow content.
                // When idle, only scroll if user is near bottom.
                .onChange(of: appState.contentVersion) {
                    if appState.isPrompting || isNearBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                // User sent a message — always scroll to bottom.
                .onChange(of: appState.forceScrollToBottom) {
                    guard appState.forceScrollToBottom else { return }
                    appState.forceScrollToBottom = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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
