import SwiftUI
import MarkdownUI

struct MessageRowView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !message.content.isEmpty {
                    if message.role == .assistant {
                        Markdown(message.content)
                            .padding(Theme.bubblePadding)
                            .background(Theme.assistantBubble)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    } else if message.role == .user {
                        Text(message.content)
                            .padding(Theme.bubblePadding)
                            .background(Theme.userBubble)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    } else {
                        // System message
                        Text(message.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                ForEach(message.toolCalls) { toolCall in
                    ToolCallView(toolCall: toolCall)
                }

                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }
}
