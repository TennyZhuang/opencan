import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct InputBarView: View {
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        let isUploadingImage = appState.isUploadingImage
        let suggestions = mentionSuggestions
        VStack(spacing: 8) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { mention in
                            Button(mention.mentionToken) {
                                applyMentionToken(mention.mentionToken)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(isUploadingImage ? .gray : Theme.accentColor)
                }
                .disabled(appState.isPrompting || isUploadingImage)

                TextField("Message...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .onSubmit { send() }

                if isUploadingImage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Theme.accentColor : .gray)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await handlePickedImage(item)
                selectedPhotoItem = nil
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.isPrompting
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        appState.sendMessage(trimmed)
    }

    private func insertMentionToken(_ token: String) {
        let separator = text.isEmpty ? "" : " "
        text += "\(separator)\(token)"
        isFocused = true
    }

    private func applyMentionToken(_ token: String) {
        if let activeRange = activeMentionRange {
            text.replaceSubrange(activeRange, with: token)
            if !text.hasSuffix(" ") {
                text += " "
            }
        } else {
            insertMentionToken(token)
        }
        isFocused = true
    }

    private var mentionSuggestions: [UploadedImageMention] {
        let mentions = appState.availableImageMentions
        guard !mentions.isEmpty else { return [] }

        guard let activeToken = activeMentionToken else {
            return []
        }

        let prefix = String(activeToken.dropFirst()).lowercased()
        if prefix.isEmpty {
            return mentions
        }
        return mentions.filter { mention in
            mention.mentionName.lowercased().hasPrefix(prefix)
        }
    }

    private var activeMentionToken: String? {
        guard let range = activeMentionRange else { return nil }
        return String(text[range])
    }

    private var activeMentionRange: Range<String.Index>? {
        guard !text.isEmpty else { return nil }

        var idx = text.endIndex
        let trailingWhitespace = CharacterSet.whitespacesAndNewlines
        while idx > text.startIndex {
            let previous = text.index(before: idx)
            let scalar = text[previous].unicodeScalars.first
            if let scalar, trailingWhitespace.contains(scalar) {
                idx = previous
            } else {
                break
            }
        }

        guard idx > text.startIndex else { return nil }
        var start = idx
        while start > text.startIndex {
            let previous = text.index(before: start)
            let scalar = text[previous].unicodeScalars.first
            if let scalar, trailingWhitespace.contains(scalar) {
                break
            }
            start = previous
        }

        let token = text[start..<idx]
        guard token.hasPrefix("@") else { return nil }
        guard token.count > 1 else { return start..<idx }
        let allowed = CharacterSet(charactersIn: "@ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        for scalar in token.unicodeScalars {
            if !allowed.contains(scalar) {
                return nil
            }
        }
        return start..<idx
    }

    private func handlePickedImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            return
        }

        let imageType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
        let mimeType = imageType?.preferredMIMEType ?? "image/jpeg"
        let fileExtension = imageType?.preferredFilenameExtension ?? "jpg"
        if let mention = await appState.uploadImageMention(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        ) {
            applyMentionToken(mention.mentionToken)
        }
    }
}
