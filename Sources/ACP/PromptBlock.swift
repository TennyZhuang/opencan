import Foundation

/// A user prompt content block sent via `session/prompt`.
enum PromptBlock: Sendable, Equatable {
    case text(String)
    case resourceLink(ResourceLink)

    struct ResourceLink: Sendable, Equatable, Hashable {
        let mentionName: String
        let uri: String
        let mimeType: String?
        let size: Int?
        let originalFilename: String?

        var mentionToken: String {
            "@\(mentionName)"
        }

        var jsonValue: JSONValue {
            var obj: [String: JSONValue] = [
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(mentionToken)
            ]
            if let mimeType {
                obj["mimeType"] = .string(mimeType)
            }
            if let size {
                obj["size"] = .int(size)
            }
            return .object(obj)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case .resourceLink(let resourceLink):
            return resourceLink.jsonValue
        }
    }
}
