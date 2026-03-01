import Foundation

/// A session-scoped uploaded image that can be referenced in chat input via @mention.
struct UploadedImageMention: Identifiable, Hashable, Sendable {
    let sessionId: String
    let mentionName: String
    let remotePath: String
    let uri: String
    let mimeType: String
    let sizeBytes: Int
    let originalFilename: String?
    let createdAt: Date

    var id: String {
        mentionName
    }

    var mentionToken: String {
        "@\(mentionName)"
    }

    var promptResourceLink: PromptBlock.ResourceLink {
        PromptBlock.ResourceLink(
            mentionName: mentionName,
            uri: uri,
            mimeType: mimeType,
            size: sizeBytes,
            originalFilename: originalFilename
        )
    }
}
