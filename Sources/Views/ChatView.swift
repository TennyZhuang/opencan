import SwiftUI
import SwiftData

func reconnectRetryDelaySeconds(forAttempt attempt: Int, randomUnit: Double = Double.random(in: 0 ... 1)) -> TimeInterval {
    let clampedAttempt = max(attempt, 0)
    let baseDelay = pow(2, Double(clampedAttempt))
    let clampedRandom = min(max(randomUnit, 0), 1)
    let jitterFactor = 0.8 + (clampedRandom * 0.4)
    return min(30, max(1, baseDelay * jitterFactor))
}

func shouldShowBackToBottomButton(distanceFromBottom: CGFloat, threshold: CGFloat = 200) -> Bool {
    distanceFromBottom > threshold
}

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var forceScrollToken = 0
    @State private var reconnectTask: Task<Void, Never>?
    @State private var nextReconnectDelaySeconds: Int?
    @State private var showsBackToBottomButton = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ChatMessageListView(
                    messages: appState.messages,
                    isPrompting: appState.isPrompting,
                    contentVersion: appState.contentVersion,
                    forceScrollToken: forceScrollToken
                ) { isVisible in
                    withAnimation(.easeOut(duration: 0.18)) {
                        showsBackToBottomButton = isVisible
                    }
                }
                .onChange(of: appState.forceScrollToBottom) {
                    guard appState.forceScrollToBottom else { return }
                    appState.forceScrollToBottom = false
                    forceScrollToken += 1
                }

                Rectangle()
                    .fill(Color.black)
                    .frame(height: Brutal.border)

                InputBarView()
                    .disabled(!appState.canSendMessages)
            }

            if showsBackToBottomButton {
                backToBottomButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 86)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

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
                    BrutalChip("LIVE", fill: Brutal.mint, fontSize: 9)
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

    private var backToBottomButton: some View {
        Button {
            forceScrollToken += 1
            withAnimation(.easeOut(duration: 0.12)) {
                showsBackToBottomButton = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .black))
                Text("Bottom")
                    .font(Brutal.mono(12, weight: .bold))
            }
        }
        .buttonStyle(BrutalButtonStyle(fill: Brutal.lime, compact: true))
        .accessibilityIdentifier("chat-back-to-bottom")
    }

    @ViewBuilder
    private var reconnectOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .allowsHitTesting(false)

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
                Text("Chat history stays scrollable while reconnect runs.")
                    .font(Brutal.mono(11, weight: .bold))
                    .foregroundStyle(.black.opacity(0.5))
                    .multilineTextAlignment(.center)
                Button("Cancel Reconnect", role: .cancel) {
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    nextReconnectDelaySeconds = nil
                    appState.cancelInterruptedSessionRecovery()
                }
                .buttonStyle(BrutalButtonStyle(fill: Brutal.pink, compact: true))
                .font(Brutal.mono(12, weight: .bold))
                .accessibilityIdentifier("chat-reconnect-cancel")
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
            if let nextReconnectDelaySeconds {
                return "Reconnect failed. Retrying in \(nextReconnectDelaySeconds)s..."
            }
            return "Reconnect failed. Retrying..."
        case .disconnected:
            if let nextReconnectDelaySeconds {
                return "Trying to restore the current chat. Next retry in \(nextReconnectDelaySeconds)s..."
            }
            return "Trying to restore the current chat..."
        }
    }

    private func updateReconnectTask() {
        let shouldRun = scenePhase == .active && appState.shouldShowChatReconnectOverlay
        guard shouldRun else {
            reconnectTask?.cancel()
            reconnectTask = nil
            nextReconnectDelaySeconds = nil
            return
        }

        reconnectTask?.cancel()
        nextReconnectDelaySeconds = nil
        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
                if !appState.shouldShowChatReconnectOverlay {
                    break
                }
                let nextDelay = reconnectRetryDelaySeconds(forAttempt: attempt)
                await MainActor.run {
                    nextReconnectDelaySeconds = max(1, Int(ceil(nextDelay)))
                }
                try? await Task.sleep(for: .seconds(nextDelay))
                attempt += 1
            }
            await MainActor.run {
                nextReconnectDelaySeconds = nil
            }
        }
    }
}
