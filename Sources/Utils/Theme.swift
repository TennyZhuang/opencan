import SwiftUI

enum Theme {
    static let accentColor = Color.blue
    static let userBubble = Color.blue
    #if os(iOS)
    static let assistantBubble = Color(.systemGray5)
    static let toolCallBg = Color(.systemGray6)
    #else
    static let assistantBubble = Color.gray.opacity(0.15)
    static let toolCallBg = Color.gray.opacity(0.1)
    #endif
    static let spacing: CGFloat = 12
    static let bubblePadding: CGFloat = 12
    static let cornerRadius: CGFloat = 16
}
