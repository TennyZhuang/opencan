import SwiftUI
import UIKit
import ListViewKit
import MarkdownView

/// A UIKit-backed message list using ListViewKit for stable live updates while streaming.
struct ChatMessageListView: UIViewRepresentable {
    let messages: [ChatMessage]
    let isPrompting: Bool
    let contentVersion: Int
    let forceScrollToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ListViewKit.ListView {
        let listView = ListViewKit.ListView(frame: .zero)
        context.coordinator.install(on: listView)
        return listView
    }

    func updateUIView(_ listView: ListViewKit.ListView, context: Context) {
        let items = messages.map(ChatListItem.init)
        context.coordinator.apply(
            items: items,
            isPrompting: isPrompting,
            contentVersion: contentVersion,
            forceScrollToken: forceScrollToken
        )
    }
}

extension ChatMessageListView {
    final class Coordinator: NSObject, ListViewAdapter, UIScrollViewDelegate {
        enum MessageRowKind: Hashable {
            case message
        }

        private weak var listView: ListViewKit.ListView?
        private var dataSource: ListViewDiffableDataSource<ChatListItem>?
        private var hasLoadedData = false
        private var isNearBottom = true
        private var lastContentVersion = -1
        private var lastForceScrollToken = 0
        private let nearBottomTolerance: CGFloat = 2
        private let sizingController = UIHostingController(
            rootView: ChatListItemView(item: .placeholder)
        )

        func install(on listView: ListViewKit.ListView) {
            self.listView = listView
            dataSource = .init(listView: listView)
            listView.adapter = self
            listView.delegate = self
            listView.showsVerticalScrollIndicator = false
            listView.showsHorizontalScrollIndicator = false
            listView.alwaysBounceVertical = true
            listView.alwaysBounceHorizontal = false
            listView.keyboardDismissMode = .interactive
            listView.contentInsetAdjustmentBehavior = .never
            sizingController.view.backgroundColor = .clear
        }

        func apply(
            items: [ChatListItem],
            isPrompting: Bool,
            contentVersion: Int,
            forceScrollToken: Int
        ) {
            guard let dataSource else { return }

            let shouldAnimate = hasLoadedData
            dataSource.applySnapshot(using: items, animatingDifferences: shouldAnimate)

            let forceScrollRequested = forceScrollToken != lastForceScrollToken
            let contentUpdated = contentVersion != lastContentVersion
            let shouldFollowContent = isPrompting || isNearBottom
            if forceScrollRequested || (contentUpdated && shouldFollowContent) {
                scrollToBottom(animated: forceScrollRequested || !isPrompting)
            }

            hasLoadedData = true
            lastContentVersion = contentVersion
            lastForceScrollToken = forceScrollToken
            updateNearBottomState()
        }

        func listView(
            _ list: ListViewKit.ListView,
            rowKindFor _: ItemType,
            at _: Int
        ) -> ListViewAdapter.RowKind {
            MessageRowKind.message
        }

        func listViewMakeRow(for kind: ListViewAdapter.RowKind) -> ListRowView {
            guard let rowKind = kind as? MessageRowKind else {
                return ListRowView()
            }
            switch rowKind {
            case .message:
                return ChatHostingRowView()
            }
        }

        func listView(
            _ list: ListViewKit.ListView,
            heightFor item: ItemType,
            at _: Int
        ) -> CGFloat {
            guard let item = item as? ChatListItem else {
                return 0
            }

            let fittingWidth = max(list.bounds.width, 1)
            sizingController.rootView = ChatListItemView(item: item)
            let targetSize = CGSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude)
            let size = sizingController.sizeThatFits(in: targetSize)
            return max(1, ceil(size.height))
        }

        func listView(
            _: ListViewKit.ListView,
            configureRowView rowView: ListRowView,
            for item: ItemType,
            at _: Int
        ) {
            guard let row = rowView as? ChatHostingRowView,
                  let item = item as? ChatListItem else {
                return
            }
            row.update(item: item)
        }
        
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            _ = scrollView
            isNearBottom = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            _ = scrollView
            updateNearBottomState()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            _ = scrollView
            _ = willDecelerate
            updateNearBottomState()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            _ = scrollView
            updateNearBottomState()
        }

        private func scrollToBottom(animated: Bool) {
            guard let listView else { return }
            let target = listView.maximumContentOffset
            if animated {
                listView.scroll(to: target)
            } else {
                listView.setContentOffset(target, animated: false)
            }
            isNearBottom = true
        }

        private func updateNearBottomState() {
            guard let listView else {
                isNearBottom = true
                return
            }
            let offset = listView.contentOffset.y
            let maxOffset = listView.maximumContentOffset.y
            isNearBottom = abs(offset - maxOffset) <= nearBottomTolerance
        }
    }
}

struct ChatListItem: Identifiable, Hashable {
    let id: UUID
    let role: ChatMessage.Role
    let content: String
    let toolCalls: [ToolCallInfo]
    let isStreaming: Bool
    private let fingerprint: Int

    @MainActor
    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        toolCalls = message.toolCalls
        isStreaming = message.isStreaming
        fingerprint = Self.makeFingerprint(
            role: role,
            content: content,
            toolCalls: toolCalls,
            isStreaming: isStreaming
        )
    }

    init(
        id: UUID,
        role: ChatMessage.Role,
        content: String,
        toolCalls: [ToolCallInfo],
        isStreaming: Bool
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        self.fingerprint = Self.makeFingerprint(
            role: role,
            content: content,
            toolCalls: toolCalls,
            isStreaming: isStreaming
        )
    }

    static let placeholder = ChatListItem(
        id: UUID(),
        role: .assistant,
        content: "",
        toolCalls: [],
        isStreaming: false
    )

    static func == (lhs: ChatListItem, rhs: ChatListItem) -> Bool {
        lhs.id == rhs.id && lhs.fingerprint == rhs.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fingerprint)
    }

    private static func makeFingerprint(
        role: ChatMessage.Role,
        content: String,
        toolCalls: [ToolCallInfo],
        isStreaming: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(role)
        hasher.combine(content)
        hasher.combine(isStreaming)
        hasher.combine(toolCalls.count)
        for toolCall in toolCalls {
            hasher.combine(toolCall.id)
            hasher.combine(toolCall.name)
            hasher.combine(toolCall.output)
            hasher.combine(toolCall.isComplete)
            hasher.combine(toolCall.isFailed)
            if let input = toolCall.input {
                hasher.combine(ToolCallView.formatJSON(input))
            } else {
                hasher.combine("nil")
            }
        }
        return hasher.finalize()
    }
}

final class ChatHostingRowView: ListRowView {
    private let hostingController = UIHostingController(
        rootView: ChatListItemView(item: .placeholder)
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingController.view.backgroundColor = .clear
        backgroundColor = .clear
        addSubview(hostingController.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostingController.view.frame = bounds
    }

    func update(item: ChatListItem) {
        hostingController.rootView = ChatListItemView(item: item)
    }
}

struct ChatListItemView: View {
    let item: ChatListItem

    var body: some View {
        HStack {
            if item.role == .user { Spacer(minLength: 60) }

            VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 8) {
                if !item.content.isEmpty {
                    if item.role == .assistant {
                        MarkdownView(item.content)
                            .padding(Theme.bubblePadding)
                            .background(Theme.assistantBubble)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                            .contextMenu { copyButton }
                    } else if item.role == .user {
                        Text(item.content)
                            .padding(Theme.bubblePadding)
                            .background(Theme.userBubble)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                            .textSelection(.enabled)
                            .contextMenu { copyButton }
                    } else {
                        Text(item.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                            .contextMenu { copyButton }
                    }
                }

                ForEach(item.toolCalls) { toolCall in
                    ToolCallView(toolCall: toolCall)
                }

                if item.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if item.role != .user { Spacer(minLength: 60) }
        }
        .padding()
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = item.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}
