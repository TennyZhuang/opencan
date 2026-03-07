import Foundation

/// Daemon method name constants.
enum DaemonMethods {
    static let hello = "daemon/hello"
    static let agentProbe = "daemon/agent.probe"
    static let conversationCreate = "daemon/conversation.create"
    static let conversationOpen = "daemon/conversation.open"
    static let conversationDetach = "daemon/conversation.detach"
    static let conversationList = "daemon/conversation.list"
    static let sessionList = "daemon/session.list"
    static let sessionKill = "daemon/session.kill"
    static let logs = "daemon/logs"
}
