import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var forceScrollToken = 0
    @State private var reconnectTask: Task<Void, Never>?

    var body: some View {
        ZStack {
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

                Rectangle()
                    .fill(Color.black)
                    .frame(height: Brutal.border)

                InputBarView()
            }
            .disabled(appState.shouldShowChatReconnectOverlay)

            if appState.shouldShowChatReconnectOverlay {
                reconnectOverlay
            }
        }
        .background(Brutal.cream.ignoresSafeArea())
        .navigationTitle(appState.activeWorkspace?.name ?? "Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(appState.activeWorkspace?.name ?? "Chat")
                        .font(Brutal.display(17, weight: .bold))
                        .foregroundStyle(.black)
                    BrutalChip("LIVE", fill: Brutal.lime, fontSize: 9)
                }
            }
            #endif
            ToolbarItem(placement: .confirmationAction) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                }
                .font(Brutal.mono(13, weight: .bold))
                .foregroundStyle(Brutal.pink)
            }
        }
        .onAppear {
            updateReconnectTask()
        }
        .onChange(of: scenePhase) {
            updateReconnectTask()
        }
        .onChange(of: appState.shouldShowChatReconnectOverlay) {
            updateReconnectTask()
        }
        .onDisappear {
            reconnectTask?.cancel()
            reconnectTask = nil
            Task {
                await appState.discardEmptyActiveSessionIfNeeded(modelContext: modelContext)
            }
        }
    }

    @ViewBuilder
    private var reconnectOverlay: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.black)
                    ProgressView()
                        .tint(.black)
                    Text(reconnectOverlayTitle)
                        .font(Brutal.display(17, weight: .bold))
                        .foregroundStyle(.black)
                    Text(reconnectOverlayMessage)
                        .font(Brutal.display(14))
                        .foregroundStyle(.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .brutalCard(fill: .white, shadow: Brutal.shadowLg, border: Brutal.borderThick)
                .padding(24)
            }
    }

    private var reconnectOverlayTitle: String {
        switch appState.connectionStatus {
        case .connecting:
            return "Reconnecting"
        case .connected:
            return "Restoring conversation"
        case .failed, .disconnected:
            return "Connection lost"
        }
    }

    private var reconnectOverlayMessage: String {
        let nodeName = appState.activeNode?.name ?? "server"
        switch appState.connectionStatus {
        case .connecting:
            return "Reconnecting to \(nodeName)..."
        case .connected:
            return "Attaching back to the current session..."
        case .failed:
            return "Reconnect failed. Retrying..."
        case .disconnected:
            return "Trying to restore the current chat..."
        }
    }

    private func updateReconnectTask() {
        let shouldRun = scenePhase == .active && appState.shouldShowChatReconnectOverlay
        guard shouldRun else {
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task {
            while !Task.isCancelled {
                await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
                if !appState.shouldShowChatReconnectOverlay {
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
