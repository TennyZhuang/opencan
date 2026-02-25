import Foundation
import SwiftData

@Model
final class Workspace {
    var name: String
    var path: String

    var node: Node?

    @Relationship(deleteRule: .cascade, inverse: \Session.workspace)
    var sessions: [Session]?

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}
