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
                    Image(systemName: toolCall.isComplete ? "checkmark.circle.fill" : "gear")
                        .foregroundStyle(toolCall.isComplete ? .green : .orange)
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
                        .lineLimit(10)
                }
                if let output = toolCall.output {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                }
            }
        }
        .padding(10)
        .background(Theme.toolCallBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
