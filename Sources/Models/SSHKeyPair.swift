import Foundation
import SwiftData

@Model
final class SSHKeyPair {
    var name: String
    var privateKeyPEM: Data
    var createdAt: Date

    @Relationship(inverse: \Node.sshKey)
    var nodes: [Node]?

    init(name: String, privateKeyPEM: Data) {
        self.name = name
        self.privateKeyPEM = privateKeyPEM
        self.createdAt = Date()
    }
}
