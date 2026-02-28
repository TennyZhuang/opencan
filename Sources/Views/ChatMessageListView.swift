import SwiftUI
import UIKit
import ListViewKit
import MarkdownView
import MarkdownParser

/// A FlowDown-style UIKit timeline built on ListViewKit for stable streaming updates.
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
        let entries = ChatListEntry.entries(from: messages)
        context.coordinator.apply(
            entries: entries,
            isPrompting: isPrompting,
            contentVersion: contentVersion,
            forceScrollToken: forceScrollToken
        )
    }
}

extension ChatMessageListView {
    final class Coordinator: NSObject, ListViewAdapter, UIScrollViewDelegate {
        enum MessageRowKind: Hashable {
            case userMessage
            case assistantMessage
            case systemHint
            case toolHint
            case activity
        }

        private struct HeightCacheEntry {
            let fingerprint: Int
            let width: CGFloat
            let height: CGFloat
        }

        private weak var listView: ListViewKit.ListView?
        private var dataSource: ListViewDiffableDataSource<ChatListEntry>?

        private var hasLoadedData = false
        private var isNearBottom = true
        private var lastContentVersion = -1
        private var lastForceScrollToken = 0

        private let nearBottomTolerance: CGFloat = 2
        private var measuredHeights: [String: HeightCacheEntry] = [:]

        private let markdownParser = MarkdownParser()
        private var markdownCache: [String: MarkdownTextView.PreprocessedContent] = [:]

        private let markdownSizingView = MarkdownTextView()
        private let labelForSizing = LTXLabel()

        override init() {
            super.init()
            labelForSizing.isSelectable = false
        }

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
        }

        func apply(
            entries: [ChatListEntry],
            isPrompting: Bool,
            contentVersion: Int,
            forceScrollToken: Int
        ) {
            guard let dataSource else { return }

            // Keep streaming updates stable by avoiding repeated row animations.
            let shouldAnimate = hasLoadedData && !isPrompting
            dataSource.applySnapshot(using: entries, animatingDifferences: shouldAnimate)

            let validIDs = Set(entries.map(\.id))
            measuredHeights = measuredHeights.filter { validIDs.contains($0.key) }

            let assistantBodies: Set<String> = Set(entries.compactMap { entry in
                guard entry.kind == .assistantMessage else { return nil }
                return entry.text
            })
            markdownCache = markdownCache.filter { assistantBodies.contains($0.key) }

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

        // MARK: - ListViewAdapter

        func listView(
            _ list: ListViewKit.ListView,
            rowKindFor item: ItemType,
            at _: Int
        ) -> ListViewAdapter.RowKind {
            guard let entry = item as? ChatListEntry else {
                assertionFailure("Invalid item type")
                return MessageRowKind.assistantMessage
            }

            switch entry.kind {
            case .userMessage:
                return MessageRowKind.userMessage
            case .assistantMessage:
                return MessageRowKind.assistantMessage
            case .systemHint:
                return MessageRowKind.systemHint
            case .toolHint:
                return MessageRowKind.toolHint
            case .activity:
                return MessageRowKind.activity
            }
        }

        func listViewMakeRow(for kind: ListViewAdapter.RowKind) -> ListRowView {
            guard let rowKind = kind as? MessageRowKind else {
                assertionFailure("Invalid row kind")
                return ListRowView()
            }

            switch rowKind {
            case .userMessage:
                return FlowUserMessageRowView()
            case .assistantMessage:
                return FlowAssistantMessageRowView()
            case .systemHint:
                return FlowHintRowView()
            case .toolHint:
                return FlowToolHintRowView()
            case .activity:
                return FlowActivityRowView()
            }
        }

        func listView(
            _ list: ListViewKit.ListView,
            heightFor item: ItemType,
            at _: Int
        ) -> CGFloat {
            guard let entry = item as? ChatListEntry else {
                assertionFailure("Invalid item type")
                return 0
            }

            let listInsets = FlowChatLayout.rowInsets
            let containerWidth = max(0, list.bounds.width - listInsets.left - listInsets.right)
            if containerWidth == 0 {
                return 0
            }

            if let cached = measuredHeights[entry.id],
               cached.fingerprint == entry.fingerprint,
               abs(cached.width - containerWidth) < 0.5 {
                return cached.height
            }

            let height = measuredHeight(for: entry, containerWidth: containerWidth)
            measuredHeights[entry.id] = .init(
                fingerprint: entry.fingerprint,
                width: containerWidth,
                height: height
            )
            return height
        }

        func listView(
            _: ListViewKit.ListView,
            configureRowView rowView: ListRowView,
            for item: ItemType,
            at _: Int
        ) {
            guard let entry = item as? ChatListEntry else {
                assertionFailure("Invalid item type")
                return
            }

            if let rowView = rowView as? FlowUserMessageRowView {
                rowView.text = entry.text
                return
            }

            if let rowView = rowView as? FlowAssistantMessageRowView {
                rowView.update(
                    markdown: markdownPackage(for: entry.text),
                    accessibilityText: entry.text
                )
                return
            }

            if let rowView = rowView as? FlowHintRowView {
                rowView.text = entry.text
                return
            }

            if let rowView = rowView as? FlowToolHintRowView,
               let toolCall = entry.toolCall {
                rowView.toolCall = toolCall
                return
            }

            if let rowView = rowView as? FlowActivityRowView {
                rowView.text = entry.text
            }
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_: UIScrollView) {
            isNearBottom = false
        }

        func scrollViewDidScroll(_: UIScrollView) {
            updateNearBottomState()
        }

        func scrollViewDidEndDragging(_: UIScrollView, willDecelerate _: Bool) {
            updateNearBottomState()
        }

        func scrollViewDidEndDecelerating(_: UIScrollView) {
            updateNearBottomState()
        }

        // MARK: - Private

        private func measuredHeight(for entry: ChatListEntry, containerWidth: CGFloat) -> CGFloat {
            let bottomInset = FlowChatLayout.rowInsets.bottom

            let contentHeight: CGFloat
            switch entry.kind {
            case .userMessage:
                let attributed = NSAttributedString(
                    string: entry.text,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label,
                    ]
                )
                let availableWidth = FlowUserMessageRowView.availableTextWidth(for: containerWidth)
                let textHeight = boundingHeight(with: availableWidth, attributedText: attributed)
                contentHeight = textHeight + FlowUserMessageRowView.textPadding * 2

            case .assistantMessage:
                let package = markdownPackage(for: entry.text)
                markdownSizingView.setMarkdownManually(package)
                contentHeight = ceil(markdownSizingView.boundingSize(for: containerWidth).height)

            case .systemHint:
                contentHeight = ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 16)

            case .toolHint:
                contentHeight = ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + 20)

            case .activity:
                let textHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
                contentHeight = ceil(max(textHeight, FlowActivityRowView.spinnerSize.height) + 16)
            }

            return contentHeight + bottomInset
        }

        private func markdownPackage(for markdown: String) -> MarkdownTextView.PreprocessedContent {
            if let cached = markdownCache[markdown] {
                return cached
            }

            let result = markdownParser.parse(markdown)
            let package = MarkdownTextView.PreprocessedContent(
                parserResult: result,
                theme: .default
            )
            markdownCache[markdown] = package
            return package
        }

        private func boundingHeight(with width: CGFloat, attributedText: NSAttributedString) -> CGFloat {
            labelForSizing.preferredMaxLayoutWidth = width
            labelForSizing.attributedText = attributedText
            return ceil(labelForSizing.intrinsicContentSize.height)
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

private enum FlowChatLayout {
    static let rowInsets: UIEdgeInsets = .init(top: 0, left: 20, bottom: 16, right: 20)
}

struct ChatListEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case userMessage
        case assistantMessage
        case systemHint
        case toolHint
        case activity
    }

    let id: String
    let kind: Kind
    let text: String
    let toolCall: ToolCallInfo?
    let fingerprint: Int

    @MainActor
    static func entries(from messages: [ChatMessage]) -> [ChatListEntry] {
        var entries: [ChatListEntry] = []

        for message in messages {
            let messageID = message.id.uuidString

            if !message.content.isEmpty {
                let contentKind: Kind
                switch message.role {
                case .user:
                    contentKind = .userMessage
                case .assistant:
                    contentKind = .assistantMessage
                case .system:
                    contentKind = .systemHint
                }

                entries.append(
                    ChatListEntry(
                        id: "\(messageID).content",
                        kind: contentKind,
                        text: message.content,
                        toolCall: nil,
                        fingerprint: makeContentFingerprint(role: message.role, content: message.content)
                    )
                )
            }

            for toolCall in message.toolCalls {
                entries.append(
                    ChatListEntry(
                        id: "\(messageID).tool.\(toolCall.id)",
                        kind: .toolHint,
                        text: "",
                        toolCall: toolCall,
                        fingerprint: makeToolFingerprint(toolCall: toolCall)
                    )
                )
            }

            if message.isStreaming {
                entries.append(
                    ChatListEntry(
                        id: "\(messageID).activity",
                        kind: .activity,
                        text: "Thinking...",
                        toolCall: nil,
                        fingerprint: makeActivityFingerprint(isStreaming: message.isStreaming)
                    )
                )
            }
        }

        return entries
    }

    static func == (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        lhs.id == rhs.id && lhs.fingerprint == rhs.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fingerprint)
    }

    private static func makeContentFingerprint(role: ChatMessage.Role, content: String) -> Int {
        var hasher = Hasher()
        hasher.combine(role)
        hasher.combine(content)
        return hasher.finalize()
    }

    private static func makeToolFingerprint(toolCall: ToolCallInfo) -> Int {
        var hasher = Hasher()
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
        return hasher.finalize()
    }

    private static func makeActivityFingerprint(isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isStreaming)
        return hasher.finalize()
    }
}

class FlowMessageRowView: ListRowView {
    let containerView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        addSubview(containerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = FlowChatLayout.rowInsets
        containerView.frame = CGRect(
            x: insets.left,
            y: 0,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.bottom
        )
        layoutContainer()
    }

    func layoutContainer() {}

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityLabel = nil
    }
}

final class FlowUserMessageRowView: FlowMessageRowView {
    static let contentPadding: CGFloat = 20
    static let textPadding: CGFloat = 12
    static let maximumIdealWidth: CGFloat = 800

    var text: String = "" {
        didSet {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                ]
            )
            textLabel.attributedText = attributed
            accessibilityLabel = text
        }
    }

    private let bubbleView = UIView()
    private let textLabel: LTXLabel = {
        let label = LTXLabel()
        label.isSelectable = true
        label.backgroundColor = .clear
        return label
    }()

    private let backgroundGradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)

        let accentColor = UIColor.systemBlue
        backgroundGradientLayer.colors = [
            accentColor.withAlphaComponent(0.10).cgColor,
            accentColor.withAlphaComponent(0.15).cgColor,
        ]
        backgroundGradientLayer.startPoint = .init(x: 0.6, y: 0)
        backgroundGradientLayer.endPoint = .init(x: 0.4, y: 1)

        bubbleView.layer.cornerRadius = 12
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.layer.insertSublayer(backgroundGradientLayer, at: 0)
        bubbleView.clipsToBounds = true

        containerView.addSubview(bubbleView)
        bubbleView.addSubview(textLabel)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    override func layoutContainer() {
        let textWidth = Self.availableTextWidth(for: containerView.bounds.width)
        textLabel.preferredMaxLayoutWidth = textWidth
        let textSize = textLabel.intrinsicContentSize

        let bubbleWidth = ceil(textSize.width) + Self.textPadding * 2
        let width = min(containerView.bounds.width, bubbleWidth)
        bubbleView.frame = CGRect(
            x: max(0, containerView.bounds.width - width),
            y: 0,
            width: width,
            height: containerView.bounds.height
        )

        backgroundGradientLayer.frame = bubbleView.bounds
        backgroundGradientLayer.cornerRadius = bubbleView.layer.cornerRadius
        textLabel.frame = bubbleView.bounds.insetBy(dx: Self.textPadding, dy: Self.textPadding)
    }

    @inlinable
    static func availableContentWidth(for width: CGFloat) -> CGFloat {
        max(0, min(maximumIdealWidth, width - contentPadding * 2))
    }

    @inlinable
    static func availableTextWidth(for width: CGFloat) -> CGFloat {
        availableContentWidth(for: width) - textPadding * 2
    }
}

final class FlowAssistantMessageRowView: FlowMessageRowView {
    private(set) lazy var markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        containerView.addSubview(markdownView)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    func update(markdown: MarkdownTextView.PreprocessedContent, accessibilityText: String) {
        markdownView.setMarkdown(markdown)
        accessibilityLabel = accessibilityText
    }

    override func layoutContainer() {
        markdownView.frame = containerView.bounds
        markdownView.bindContentOffset(from: superListView)
    }
}

final class FlowHintRowView: FlowMessageRowView {
    var text: String = "" {
        didSet {
            label.text = text
            accessibilityLabel = text
        }
    }

    private let label: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.alpha = 0.5
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        containerView.addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    override func layoutContainer() {
        label.frame = containerView.bounds.insetBy(dx: 8, dy: 8)
    }
}

final class FlowToolHintRowView: FlowMessageRowView {
    var toolCall: ToolCallInfo = .init(id: "", name: "") {
        didSet {
            updateState()
        }
    }

    private let bubbleView = UIView()
    private let symbolView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let label: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let backgroundGradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundGradientLayer.startPoint = .init(x: 0.6, y: 0)
        backgroundGradientLayer.endPoint = .init(x: 0.4, y: 1)

        bubbleView.layer.cornerRadius = 12
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.layer.insertSublayer(backgroundGradientLayer, at: 0)
        bubbleView.clipsToBounds = true

        containerView.addSubview(bubbleView)
        bubbleView.addSubview(symbolView)
        bubbleView.addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override func layoutContainer() {
        let labelSize = label.intrinsicContentSize
        let symbolSize = max(12, labelSize.height)
        let bubbleWidth = min(
            containerView.bounds.width,
            symbolSize + 8 + labelSize.width + 24
        )

        bubbleView.frame = CGRect(
            x: 0,
            y: 0,
            width: bubbleWidth,
            height: containerView.bounds.height
        )

        symbolView.frame = CGRect(
            x: 12,
            y: (bubbleView.bounds.height - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )

        label.frame = CGRect(
            x: symbolView.frame.maxX + 8,
            y: (bubbleView.bounds.height - labelSize.height) / 2,
            width: max(0, bubbleView.bounds.width - symbolView.frame.maxX - 20),
            height: labelSize.height
        )

        backgroundGradientLayer.frame = bubbleView.bounds
        backgroundGradientLayer.cornerRadius = bubbleView.layer.cornerRadius
    }

    private func updateState() {
        let status = statusText(for: toolCall)
        label.text = status
        accessibilityLabel = status

        let configuration = UIImage.SymbolConfiguration(scale: .small)
        if toolCall.isFailed {
            backgroundGradientLayer.colors = [
                UIColor.systemRed.withAlphaComponent(0.08).cgColor,
                UIColor.systemRed.withAlphaComponent(0.12).cgColor,
            ]
            symbolView.image = UIImage(systemName: "xmark.seal", withConfiguration: configuration)
            symbolView.tintColor = .systemRed
        } else if toolCall.isComplete {
            backgroundGradientLayer.colors = [
                UIColor.systemGreen.withAlphaComponent(0.08).cgColor,
                UIColor.systemGreen.withAlphaComponent(0.12).cgColor,
            ]
            symbolView.image = UIImage(systemName: "checkmark.seal", withConfiguration: configuration)
            symbolView.tintColor = .systemGreen
        } else {
            backgroundGradientLayer.colors = [
                UIColor.systemBlue.withAlphaComponent(0.08).cgColor,
                UIColor.systemBlue.withAlphaComponent(0.12).cgColor,
            ]
            symbolView.image = UIImage(systemName: "hourglass", withConfiguration: configuration)
            symbolView.tintColor = .systemBlue
        }

        setNeedsLayout()
    }

    private func statusText(for toolCall: ToolCallInfo) -> String {
        if toolCall.isFailed {
            return "Tool call for \(toolCall.name) failed."
        }
        if toolCall.isComplete {
            return "Tool call for \(toolCall.name) completed."
        }
        return "Tool call for \(toolCall.name) running"
    }
}

final class FlowActivityRowView: FlowMessageRowView {
    static let spinnerSize = CGSize(width: 20, height: 20)

    var text: String = "Thinking..." {
        didSet {
            label.text = text
            accessibilityLabel = text
        }
    }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        spinner.startAnimating()
        containerView.addSubview(spinner)
        containerView.addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        text = "Thinking..."
    }

    override func layoutContainer() {
        let labelSize = label.intrinsicContentSize

        spinner.frame = CGRect(
            x: 0,
            y: (containerView.bounds.height - Self.spinnerSize.height) / 2,
            width: Self.spinnerSize.width,
            height: Self.spinnerSize.height
        )

        label.frame = CGRect(
            x: spinner.frame.maxX + 8,
            y: (containerView.bounds.height - labelSize.height) / 2,
            width: min(labelSize.width, containerView.bounds.width - spinner.frame.maxX - 8),
            height: labelSize.height
        )
    }
}
