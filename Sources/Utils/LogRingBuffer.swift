import Foundation

final class LogRingBuffer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tianyizhuang.OpenCAN.log.buffer", attributes: .concurrent)
    private var entries: [LogEntry]
    private let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = max(1, maxSize)
        self.entries = []
        self.entries.reserveCapacity(min(512, self.maxSize))
    }

    func append(_ entry: LogEntry) {
        queue.sync(flags: .barrier) {
            entries.append(entry)
            if entries.count > maxSize {
                let excess = entries.count - maxSize
                entries = Array(entries.dropFirst(excess))
            }
        }
    }

    func allEntries() -> [LogEntry] {
        queue.sync {
            entries
        }
    }

    func entriesSince(_ date: Date) -> [LogEntry] {
        queue.sync {
            entries.filter { $0.timestamp >= date }
        }
    }
}
