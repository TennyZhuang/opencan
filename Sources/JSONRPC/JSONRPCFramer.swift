import Foundation

/// Buffers incoming bytes and extracts newline-delimited JSON-RPC messages.
actor JSONRPCFramer {
    private var buffer = Data()
    private var foundFirstJSON = false

    /// Feed raw bytes (possibly from PTY). Returns parsed messages.
    func feed(_ data: Data) -> [JSONRPCMessage] {
        buffer.append(data)
        var messages: [JSONRPCMessage] = []

        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }

            // Skip PTY noise: wait for first line starting with '{'
            if !foundFirstJSON {
                if line.hasPrefix("{") {
                    foundFirstJSON = true
                } else {
                    continue
                }
            }

            guard line.hasPrefix("{") else { continue }

            guard let jsonData = line.data(using: .utf8) else { continue }
            do {
                let msg = try JSONRPCMessage.deserialize(from: jsonData)
                messages.append(msg)
            } catch {
                print("[JSONRPCFramer] parse error: \(error) for line: \(line.prefix(200))")
            }
        }

        return messages
    }

    func reset() {
        buffer = Data()
        foundFirstJSON = false
    }
}
