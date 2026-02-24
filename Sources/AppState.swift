import Foundation
import SwiftUI

/// Root state coordinator connecting SSH, ACP, and UI.
@Observable
final class AppState {
    // Connection
    var serverConfig = ServerConfig.demo
    var connectionStatus: ConnectionStatus = .disconnected
    var connectionError: String?

    // Chat
    var messages: [ChatMessage] = []
    var currentSessionId: String?
    var sessions: [SessionInfo] = []
    var isPrompting = false

    // Internal
    private let sshManager = SSHConnectionManager()
    private var acpClient: ACPClient?
    private var acpService: ACPService?
    private var transport: SSHStdioTransport?
    private var notificationTask: Task<Void, Never>?
    private var ptyTask: Task<Void, Never>?

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    // MARK: - Connection

    func connect() {
        guard connectionStatus != .connecting else { return }
        connectionStatus = .connecting
        connectionError = nil

        Task {
            do {
                let t = try await sshManager.connect(config: serverConfig)
                self.transport = t

                ptyTask = Task {
                    do {
                        if #available(macOS 15.0, iOS 18.0, *) {
                            try await sshManager.startPTY(
                                transport: t,
                                command: serverConfig.command
                            )
                        }
                    } catch {
                        await MainActor.run {
                            self.connectionError = "PTY closed: \(error.localizedDescription)"
                            self.connectionStatus = .disconnected
                        }
                    }
                }

                let client = ACPClient(transport: t)
                await client.start()
                self.acpClient = client
                let service = ACPService(client: client)
                self.acpService = service

                let _ = try await service.initialize()
                print("[AppState] ACP initialized")

                let sessionId = try await service.createSession(cwd: "/tmp/opencan-workspace")
                self.currentSessionId = sessionId
                self.sessions = [SessionInfo(sessionId: sessionId)]

                startNotificationListener()

                await MainActor.run {
                    self.connectionStatus = .connected
                    self.addSystemMessage("Connected to \(self.serverConfig.name)")
                }
            } catch {
                await MainActor.run {
                    self.connectionError = error.localizedDescription
                    self.connectionStatus = .failed
                }
            }
        }
    }

    func disconnect() {
        notificationTask?.cancel()
        ptyTask?.cancel()
        Task {
            if let client = acpClient { await client.stop() }
            if let t = transport { await t.close() }
            await sshManager.disconnect()
        }
        acpClient = nil
        acpService = nil
        transport = nil
        connectionStatus = .disconnected
        currentSessionId = nil
        messages = []
    }

    // MARK: - Chat

    func sendMessage(_ text: String) {
        guard !text.isEmpty, !isPrompting,
              let service = acpService,
              let sessionId = currentSessionId else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: .assistant, isStreaming: true)
        messages.append(assistantMsg)
        isPrompting = true

        Task {
            do {
                let _ = try await service.sendPrompt(sessionId: sessionId, text: text)
                await MainActor.run {
                    assistantMsg.isStreaming = false
                    self.isPrompting = false
                }
            } catch {
                await MainActor.run {
                    assistantMsg.content += "\n[Error: \(error.localizedDescription)]"
                    assistantMsg.isStreaming = false
                    self.isPrompting = false
                }
            }
        }
    }

    // MARK: - Notifications

    private func startNotificationListener() {
        guard let client = acpClient else { return }
        notificationTask = Task {
            for await notification in await client.notifications {
                guard let event = SessionUpdateParser.parse(notification) else { continue }
                await MainActor.run { self.handleSessionEvent(event) }
            }
        }
    }

    private func handleSessionEvent(_ event: SessionEvent) {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return }
        switch event {
        case .agentMessage(let text):
            last.content = text
        case .agentMessageDelta(let text):
            last.content += text
        case .toolCall(let id, let name, let input):
            last.toolCalls.append(ToolCallInfo(id: id, name: name, input: input))
        case .toolCallUpdate(let id, let output):
            if let i = last.toolCalls.firstIndex(where: { $0.id == id }) {
                last.toolCalls[i].output = (last.toolCalls[i].output ?? "") + output
            }
        case .toolCallComplete(let id):
            if let i = last.toolCalls.firstIndex(where: { $0.id == id }) {
                last.toolCalls[i].isComplete = true
            }
        case .thought(let text):
            last.content += "\n> \(text)"
        case .promptComplete:
            last.isStreaming = false
            isPrompting = false
        }
    }

    private func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }
}