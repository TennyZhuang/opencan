import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    /// Tracks whether the bottom anchor is visible.
    /// Used to decide auto-scroll when NOT actively streaming.
    @State private var isNearBottom = true
    /// Follow-up scroll to correct for MarkdownView async layout
    /// and LazyVStack height estimation drift.
    @State private var followUpTask: Task<Void, Never>?

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
                // Streaming content changed (throttled).
                // During active prompting, always follow content.
                // When idle, only scroll if user is near bottom.
                .onChange(of: appState.contentVersion) {
                    if appState.isPrompting || isNearBottom {
                        scrollToBottom(proxy: proxy, animated: !appState.isPrompting)
                    }
                }
                // User sent a message or prompt completed —
                // always scroll to bottom.
                .onChange(of: appState.forceScrollToBottom) {
                    guard appState.forceScrollToBottom else { return }
                    appState.forceScrollToBottom = false
                    scrollToBottom(proxy: proxy, animated: true)
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

    /// Scroll to bottom with an optional follow-up to catch layout drift.
    /// MarkdownView (UIKit-backed) lays out asynchronously — a second
    /// scroll 250ms later corrects for height changes that occur after
    /// the first scrollTo.
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }

        // Schedule follow-up scroll. Cancelled if another scroll starts
        // before it fires (prevents pile-up during rapid streaming).
        followUpTask?.cancel()
        followUpTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
