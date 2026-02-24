import Foundation

struct ServerConfig: Codable, Identifiable {
    var id: String { "\(jumpHost ?? "direct")→\(host):\(port)" }

    var name: String
    var host: String
    var port: UInt16
    var username: String
    var privateKeyName: String // bundle resource name (no extension)

    // Optional jump host
    var jumpHost: String?
    var jumpPort: UInt16?
    var jumpUsername: String?

    var command: String

    static let demo = ServerConfig(
        name: "cp32 via cp01",
        host: "192.168.2.29",
        port: 22,
        username: "tyzhuang",
        privateKeyName: "id_rsa_zd",
        jumpHost: "42.62.6.84",
        jumpPort: 22,
        jumpUsername: "tyzhuang",
        command: "claude-agent-acp"
    )
}
