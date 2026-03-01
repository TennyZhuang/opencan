import Foundation

struct LogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String
    let component: String
    let message: String
    let traceId: String?
    let sessionId: String?
    let extra: [String: String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: String,
        component: String,
        message: String,
        traceId: String? = nil,
        sessionId: String? = nil,
        extra: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
        self.traceId = traceId
        self.sessionId = sessionId
        self.extra = extra
    }
}
