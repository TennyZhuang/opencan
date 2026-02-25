import Foundation
import SwiftUI
import os

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

                // Wait for PTY to be ready before sending ACP messages
                await t.waitUntilReady()

                let client = ACPClient(transport: t)
                await client.start()
                self.acpClient = client
                let service = ACPService(client: client)
                self.acpService = service

                let initResult = try await service.initialize()
                Log.app.info("ACP initialized: \(String(describing: initResult))")
                Log.toFile("[AppState] ACP initialized")

                // Skip auth — agent has it pre-configured on the server

                // Small delay to let the agent fully initialize
                try await Task.sleep(for: .seconds(1))

                Log.toFile("[AppState] Creating session...")
                let sessionId = try await service.createSession(cwd: serverConfig.cwd)
                self.currentSessionId = sessionId
                self.sessions = [SessionInfo(sessionId: sessionId)]

                startNotificationListener()

                await MainActor.run {
                    self.connectionStatus = .connected
                    self.addSystemMessage("Connected to \(self.serverConfig.name)")
                }
            } catch {
                Log.app.error("Connection error: \(error)")
                Log.toFile("[AppState] Connection error: \(error)")
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
                    for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                        msg.isStreaming = false
                    }
                    self.isPrompting = false
                }
            } catch {
                await MainActor.run {
                    self.lastAssistantMessage().content += "\n[Error: \(error.localizedDescription)]"
                    for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                        msg.isStreaming = false
                    }
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
        switch event {
        case .agentMessage(let text):
            lastAssistantMessage().content = text

        case .agentMessageDelta(let text):
            // If the last assistant message already has tool calls,
            // create a new message so text appears after tool cards
            let msg = lastAssistantMessage()
            if !msg.toolCalls.isEmpty {
                msg.isStreaming = false
                let newMsg = ChatMessage(role: .assistant, isStreaming: true)
                newMsg.content = text
                messages.append(newMsg)
            } else {
                msg.content += text
            }

        case .toolCall(let id, let name, let input):
            // Tool call starting — previous text is done streaming
            let msg = lastAssistantMessage()
            if !msg.content.isEmpty {
                msg.isStreaming = false
            }
            msg.toolCalls.append(
                ToolCallInfo(id: id, name: name, input: input)
            )

        case .toolCallUpdate(let id, let title, let input, let output):
            let msg = lastAssistantMessage()
            if let i = msg.toolCalls.firstIndex(where: { $0.id == id }) {
                if let title { msg.toolCalls[i].name = title }
                if let input { msg.toolCalls[i].input = input }
                if let output { msg.toolCalls[i].output = output }
            }

        case .toolCallComplete(let id, let title, let input, let output, let failed):
            let msg = lastAssistantMessage()
            if let i = msg.toolCalls.firstIndex(where: { $0.id == id }) {
                if let title { msg.toolCalls[i].name = title }
                if let input { msg.toolCalls[i].input = input }
                if let output { msg.toolCalls[i].output = output }
                msg.toolCalls[i].isComplete = true
                msg.toolCalls[i].isFailed = failed
            }

        case .thought(let text):
            lastAssistantMessage().content += "\n> \(text)"

        case .promptComplete:
            // Stop streaming on ALL assistant messages from this turn
            for msg in messages where msg.role == .assistant && msg.isStreaming {
                msg.isStreaming = false
            }
            isPrompting = false
        }
    }

    /// Get or create the current assistant message for appending content.
    private func lastAssistantMessage() -> ChatMessage {
        if let last = messages.last, last.role == .assistant {
            return last
        }
        let msg = ChatMessage(role: .assistant, isStreaming: true)
        messages.append(msg)
        return msg
    }

    private func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }
}