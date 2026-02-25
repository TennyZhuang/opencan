import Foundation
import SwiftData

@Model
final class Node {
    var name: String
    var host: String
    var port: Int
    var username: String
    var command: String

    var sshKey: SSHKeyPair?
    var jumpServer: Node?

    @Relationship(deleteRule: .cascade, inverse: \Workspace.node)
    var workspaces: [Workspace]?

    init(name: String, host: String, port: Int = 22, username: String, command: String = "claude-agent-acp") {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.command = command
    }
}
