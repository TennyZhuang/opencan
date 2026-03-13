import SwiftUI
import MarkdownView

struct MessageRowView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !message.content.isEmpty {
                    if message.role == .assistant {
                        MarkdownView(message.content)
                            .padding(Theme.bubblePadding)
                            .background(Theme.assistantBubble)
                            .overlay(Rectangle().stroke(Color.black, lineWidth: Brutal.border))
                            .contextMenu { copyButton }
                    } else if message.role == .user {
                        Text(message.content)
                            .padding(Theme.bubblePadding)
                            .foregroundStyle(.black)
                            .brutalCard(fill: Brutal.mint.opacity(0.25), shadow: Brutal.shadowSm)
                            .textSelection(.enabled)
                            .contextMenu { copyButton }
                    } else {
                        Text(message.content)
                            .font(Brutal.mono(12))
                            .foregroundStyle(.black.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                            .contextMenu { copyButton }
                    }
                }

                ForEach(message.toolCalls) { toolCall in
                    ToolCallView(toolCall: toolCall)
                }

                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(0.7)
                        Text("Thinking...")
                            .font(Brutal.mono(12))
                            .foregroundStyle(.black.opacity(0.5))
                    }
                }
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}
