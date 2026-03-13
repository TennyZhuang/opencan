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
                        .foregroundStyle(.black)
                    Text(toolCall.name)
                        .font(Brutal.mono(12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2)
                }
                .foregroundStyle(.black)
            }

            if isExpanded {
                // Input
                if let input = cachedInput {
                    Text(input)
                        .font(Brutal.mono(11))
                        .foregroundStyle(.black.opacity(0.6))
                        .lineLimit(showFullOutput ? nil : previewLineLimit)
                        .textSelection(.enabled)
                }

                // Output
                if let output = toolCall.output, !output.isEmpty {
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: 1)
                    Text(output)
                        .font(Brutal.mono(11))
                        .foregroundStyle(toolCall.isFailed ? Color.black : .black.opacity(0.6))
                        .lineLimit(showFullOutput ? nil : previewLineLimit)
                        .textSelection(.enabled)

                    let inputIsLong = (cachedInput?.components(separatedBy: "\n").count ?? 0) > previewLineLimit
                    if outputIsLong(output) || inputIsLong {
                        Button {
                            withAnimation { showFullOutput.toggle() }
                        } label: {
                            Text(showFullOutput ? "Show less" : "Show more...")
                                .font(Brutal.mono(11, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(statusFill)
        .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
    }

    private var statusIcon: String {
        if toolCall.isFailed { return "xmark.circle.fill" }
        if toolCall.isComplete { return "checkmark.circle.fill" }
        return "gear"
    }

    private var statusFill: Color {
        if toolCall.isFailed { return Brutal.pink.opacity(0.15) }
        if toolCall.isComplete { return Brutal.mint.opacity(0.15) }
        return Brutal.cyan.opacity(0.15)
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
