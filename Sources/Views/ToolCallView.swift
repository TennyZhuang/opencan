import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded = false
    @State private var showFullOutput = false

    private let previewLineLimit = 3

    private var formattedInput: String? {
        toolCall.input.map { Self.formatJSON($0) }
    }

    var body: some View {
        let cachedInput = formattedInput

        VStack(alignment: .leading, spacing: 6) {
            // Header
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(toolCall.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }

            if isExpanded {
                // Input
                if let input = cachedInput {
                    Text(input)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullOutput ? nil : previewLineLimit)
                        .textSelection(.enabled)
                }

                // Output
                if let output = toolCall.output, !output.isEmpty {
                    Divider()
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(toolCall.isFailed ? .red : .secondary)
                        .lineLimit(showFullOutput ? nil : previewLineLimit)
                        .textSelection(.enabled)

                    let inputIsLong = (cachedInput?.components(separatedBy: "\n").count ?? 0) > previewLineLimit
                    if outputIsLong(output) || inputIsLong {
                        Button {
                            withAnimation { showFullOutput.toggle() }
                        } label: {
                            Text(showFullOutput ? "Show less" : "Show more...")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.toolCallBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusIcon: String {
        if toolCall.isFailed { return "xmark.circle.fill" }
        if toolCall.isComplete { return "checkmark.circle.fill" }
        return "gear"
    }

    private var statusColor: Color {
        if toolCall.isFailed { return .red }
        if toolCall.isComplete { return .green }
        return .orange
    }

    private func outputIsLong(_ text: String) -> Bool {
        text.components(separatedBy: "\n").count > previewLineLimit
    }

    static func formatJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return "\(value)"
        }
        return str
    }
}
