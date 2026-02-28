import Foundation

/// Daemon method name constants.
enum DaemonMethods {
    static let hello = "daemon/hello"
    static let agentProbe = "daemon/agent.probe"
    static let sessionCreate = "daemon/session.create"
    static let sessionAttach = "daemon/session.attach"
    static let sessionDetach = "daemon/session.detach"
    static let sessionList = "daemon/session.list"
    static let sessionKill = "daemon/session.kill"
}
