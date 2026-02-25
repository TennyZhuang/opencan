import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(toolCall.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }

            if isExpanded {
                if let input = toolCall.input {
                    Text(formatJSON(input))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(15)
                        .textSelection(.enabled)
                }
                if let output = toolCall.output, !output.isEmpty {
                    Divider()
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(toolCall.isFailed ? .red : .secondary)
                        .lineLimit(30)
                        .textSelection(.enabled)
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

    private func formatJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return "\(value)"
        }
        return str
    }
}
