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
    var onBackToBottomVisibilityChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBackToBottomVisibilityChanged: onBackToBottomVisibilityChanged)
    }

    func makeUIView(context: Context) -> ListViewKit.ListView {
        let listView = ListViewKit.ListView(frame: .zero)
        listView.backgroundColor = BrutalUIKit.cream
        context.coordinator.install(on: listView)
        return listView
    }

    func updateUIView(_ listView: ListViewKit.ListView, context: Context) {
        let entries = ChatListEntry.entries(from: messages)
        context.coordinator.onBackToBottomVisibilityChanged = onBackToBottomVisibilityChanged
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
        var onBackToBottomVisibilityChanged: (Bool) -> Void

        private var hasLoadedData = false
        private var isNearBottom = true
        private var showsBackToBottomButton = false
        private var lastContentVersion = -1
        private var lastForceScrollToken = 0

        private let nearBottomTolerance: CGFloat = 2
        private let backToBottomVisibilityThreshold: CGFloat = 200
        private var measuredHeights: [String: HeightCacheEntry] = [:]

        private let markdownParser = MarkdownParser()
        private var markdownCache: [String: MarkdownTextView.PreprocessedContent] = [:]

        private let markdownSizingView = MarkdownTextView()
        private let labelForSizing = LTXLabel()

        init(onBackToBottomVisibilityChanged: @escaping (Bool) -> Void) {
            self.onBackToBottomVisibilityChanged = onBackToBottomVisibilityChanged
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

            if let flowRow = rowView as? FlowMessageRowView {
                flowRow.menuProvider = { [weak self] in
                    self?.contextMenu(for: entry)
                }
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
                // text padding + border (2px top + 2px bottom) + shadow offset (2px)
                contentHeight = textHeight + FlowUserMessageRowView.textPadding * 2 + BrutalUIKit.borderWidth * 2 + BrutalUIKit.shadowSm

            case .assistantMessage:
                let package = markdownPackage(for: entry.text)
                markdownSizingView.setMarkdownManually(package)
                contentHeight = ceil(markdownSizingView.boundingSize(for: containerWidth).height)

            case .systemHint:
                contentHeight = ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 16)

            case .toolHint:
                // text padding + border + shadow
                contentHeight = ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + 20 + BrutalUIKit.borderWidth * 2 + BrutalUIKit.shadowSm)

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

        private func contextMenu(for entry: ChatListEntry) -> UIMenu? {
            var actions: [UIAction] = []

            switch entry.kind {
            case .assistantMessage, .userMessage, .systemHint:
                guard !entry.text.isEmpty else { return nil }
                let text = entry.text
                actions.append(
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = text
                    }
                )
                actions.append(
                    UIAction(title: "View Raw", image: UIImage(systemName: "eye")) { [weak self] _ in
                        self?.presentRawText(text)
                    }
                )

            case .toolHint:
                guard let toolCall = entry.toolCall else { return nil }
                let raw = Self.toolCallRawText(toolCall)
                actions.append(
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = raw
                    }
                )
                actions.append(
                    UIAction(title: "View Raw", image: UIImage(systemName: "eye")) { [weak self] _ in
                        self?.presentRawText(raw)
                    }
                )

            case .activity:
                return nil
            }

            return actions.isEmpty ? nil : UIMenu(children: actions)
        }

        private func presentRawText(_ text: String) {
            guard let listView,
                  let presenter = listView.closestViewController else {
                return
            }

            let viewer = RawTextViewController(text: text)
            let nav = UINavigationController(rootViewController: viewer)
            nav.modalPresentationStyle = .formSheet
            presenter.present(nav, animated: true)
        }

        private static func toolCallRawText(_ toolCall: ToolCallInfo) -> String {
            var lines: [String] = []
            lines.append("Tool: \(toolCall.name)")
            if let input = toolCall.input {
                lines.append("")
                lines.append("Input:")
                lines.append(ToolCallView.formatJSON(input))
            }
            if let output = toolCall.output, !output.isEmpty {
                lines.append("")
                lines.append("Output:")
                lines.append(output)
            }
            lines.append("")
            if toolCall.isFailed {
                lines.append("Status: failed")
            } else if toolCall.isComplete {
                lines.append("Status: completed")
            } else {
                lines.append("Status: running")
            }
            return lines.joined(separator: "\n")
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
            setBackToBottomButtonVisible(false)
        }

        private func updateNearBottomState() {
            guard let listView else {
                isNearBottom = true
                setBackToBottomButtonVisible(false)
                return
            }

            let offset = listView.contentOffset.y
            let maxOffset = listView.maximumContentOffset.y
            isNearBottom = abs(offset - maxOffset) <= nearBottomTolerance
            let distanceFromBottom = max(0, maxOffset - offset)
            setBackToBottomButtonVisible(
                shouldShowBackToBottomButton(
                    distanceFromBottom: distanceFromBottom,
                    threshold: backToBottomVisibilityThreshold
                )
            )
        }

        private func setBackToBottomButtonVisible(_ isVisible: Bool) {
            guard showsBackToBottomButton != isVisible else { return }
            showsBackToBottomButton = isVisible
            DispatchQueue.main.async { [weak self] in
                self?.onBackToBottomVisibilityChanged(isVisible)
            }
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

class FlowMessageRowView: ListRowView, UIContextMenuInteractionDelegate {
    let containerView = UIView()
    var menuProvider: (() -> UIMenu?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        backgroundColor = BrutalUIKit.cream
        addSubview(containerView)
        containerView.isUserInteractionEnabled = true
        containerView.addInteraction(UIContextMenuInteraction(delegate: self))
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
        menuProvider = nil
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menu
        }
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
                    .foregroundColor: UIColor.black,
                ]
            )
            textLabel.attributedText = attributed
            accessibilityLabel = text
        }
    }

    private let shadowView = UIView()
    private let bubbleView = UIView()
    private let textLabel: LTXLabel = {
        let label = LTXLabel()
        label.isSelectable = true
        label.backgroundColor = .clear
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Shadow layer (black offset rectangle)
        shadowView.backgroundColor = .black

        // Bubble (mint fill + black border)
        bubbleView.backgroundColor = .white
        bubbleView.layer.borderColor = UIColor.black.cgColor
        bubbleView.layer.borderWidth = BrutalUIKit.borderWidth
        bubbleView.clipsToBounds = true

        containerView.addSubview(shadowView)
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
        let bubbleHeight = containerView.bounds.height - BrutalUIKit.shadowSm

        let bubbleX = max(0, containerView.bounds.width - width)
        bubbleView.frame = CGRect(x: bubbleX, y: 0, width: width, height: bubbleHeight)
        shadowView.frame = bubbleView.frame.offsetBy(dx: BrutalUIKit.shadowSm, dy: BrutalUIKit.shadowSm)
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
        label.textColor = .black
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

    private let shadowView = UIView()
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
        label.textColor = .black
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        shadowView.backgroundColor = .black

        bubbleView.layer.borderColor = UIColor.black.cgColor
        bubbleView.layer.borderWidth = BrutalUIKit.borderWidth
        bubbleView.clipsToBounds = true

        containerView.addSubview(shadowView)
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
        let bubbleHeight = containerView.bounds.height - BrutalUIKit.shadowSm

        bubbleView.frame = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        shadowView.frame = bubbleView.frame.offsetBy(dx: BrutalUIKit.shadowSm, dy: BrutalUIKit.shadowSm)

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
    }

    private func updateState() {
        let status = statusText(for: toolCall)
        label.text = status
        accessibilityLabel = status

        let configuration = UIImage.SymbolConfiguration(scale: .small)
        if toolCall.isFailed {
            bubbleView.backgroundColor = BrutalUIKit.pinkTint
            symbolView.image = UIImage(systemName: "xmark.seal", withConfiguration: configuration)
            symbolView.tintColor = .black
        } else if toolCall.isComplete {
            bubbleView.backgroundColor = BrutalUIKit.mintTint
            symbolView.image = UIImage(systemName: "checkmark.seal", withConfiguration: configuration)
            symbolView.tintColor = .black
        } else {
            bubbleView.backgroundColor = BrutalUIKit.cyanTint
            symbolView.image = UIImage(systemName: "hourglass", withConfiguration: configuration)
            symbolView.tintColor = .black
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
        label.textColor = .black.withAlphaComponent(0.6)
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        spinner.color = .black
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

final class RawTextViewController: UIViewController {
    private let content: String
    private let textView = UITextView()

    init(text: String) {
        content = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = BrutalUIKit.cream
        title = "Raw Content"

        textView.text = content
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.textContainerInset = .init(top: 16, left: 16, bottom: 16, right: 16)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.frame = view.bounds
        view.addSubview(textView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Copy",
            style: .plain,
            target: self,
            action: #selector(copyText)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
    }

    @objc
    private func copyText() {
        UIPasteboard.general.string = content
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }
}

private extension UIView {
    var closestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}
