import AppKit
import SwiftUI
import UltraChat
import UltraDesign

/// A conversation with a model, beside the terminal.
///
/// The store is handed in rather than made here, the way an editor's tabs are: it lives
/// in the tile factory so an answer that is still arriving survives the pane being rebuilt.
public struct ChatTile: View {
    @Bindable private var store: ChatStore
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    private let context: TileContext

    public init(context: TileContext, store: ChatStore) {
        self.context = context
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let error = store.error { errorBar(error) }
            if store.current.messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            composer
        }
        .tileFooter { footer }
        .onAppear {
            draftFocused = true
            store.refreshModels()
        }
        // Escape stops an answer that is arriving — the one thing a user wants a key for
        // while text is pouring in.
        .onExitCommand { store.stop() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(store.current.messages) { message in
                    ChatMessageView(message: message,
                                    isArriving: store.isStreaming && message.id == store.current.messages.last?.id,
                                    sendToShell: { context.injectIntoShell($0) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // Pinned to the bottom, so an answer streaming in stays in view rather than
        // running off the bottom of the pane a line at a time.
        .defaultScrollAnchor(.bottom)
        .tileScrollBar()
    }

    @ViewBuilder
    private var emptyState: some View {
        if let reason = store.blockedReason {
            EmptyTileState(icon: "text.bubble", title: reason)
        } else {
            EmptyTileState(icon: "text.bubble",
                           title: "Ask \(store.current.provider.title) about \(context.projectRoot.lastPathComponent)")
        }
    }

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Token.Colour.accentWash)
    }

    // MARK: - Composer

    /// The same pill the Todo pane types into, grown to several lines.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(store.canSend ? "Ask \(store.current.provider.title)…" : "Add a key in Settings ▸ Chat",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.label)
                .lineLimit(1...8)
                .focused($draftFocused)
                .onSubmit(send)
                .disabled(!store.canSend)

            // Send while idle, stop while an answer is arriving — the same slot, so the
            // control under the pointer changes meaning rather than position.
            TodoRowSlot {
                if store.isStreaming {
                    Button(action: store.stop) { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Token.Colour.label)
                        .help("Stop (Esc)")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Token.Colour.accent)
                        .help("Send (Return; ⌥Return for a new line)")
                        .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSend)
                }
            }
            .padding(.bottom, 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Token.Colour.label.opacity(draftFocused ? 0.09 : 0.06))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .contentShape(.rect)
        .onTapGesture { draftFocused = true }
        .animation(Token.Motion.chromeFade, value: draftFocused)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.canSend else { return }
        draft = ""
        store.send(text)
        draftFocused = true
    }

    // MARK: - Footer

    private var footer: some View {
        TileFooter(summary: "\(store.current.provider.title) · \(store.current.model)",
                   summaryHelp: "Which model this conversation is with") {
            TileFooterButton(symbol: "square.and.pencil", help: "New chat (⌥⌘N)") {
                store.newConversation()
                draftFocused = true
            }
            ChromeMenuButton(symbol: "clock", help: "Earlier chats in this project") {
                conversationEntries
            }
            ChromeMenuButton(symbol: "cpu", help: "Provider and model") {
                modelEntries
            }
        }
    }

    private var conversationEntries: [ChromeMenuEntry] {
        var entries: [ChromeMenuEntry] = []
        if store.conversations.isEmpty {
            entries.append(.caption("No chats yet"))
        }
        for conversation in store.conversations.prefix(20) {
            entries.append(.item(title: conversation.displayTitle,
                                 isOn: conversation.id == store.current.id) {
                store.open(conversation.id)
            })
        }
        if !store.current.messages.isEmpty {
            entries.append(.separator)
            entries.append(.item(title: "Delete This Chat", symbol: "minus.circle") {
                store.delete(store.current.id)
            })
        }
        return entries
    }

    private var modelEntries: [ChromeMenuEntry] {
        var entries: [ChromeMenuEntry] = [.caption("Provider")]
        for provider in ChatProviderID.allCases {
            let usable = provider == .apple ? store.appleUnavailable == nil : ChatCredentials.isConfigured(provider)
            entries.append(.item(title: provider.title,
                                 isOn: provider == store.current.provider,
                                 isEnabled: usable) {
                store.setProvider(provider)
                store.refreshModels()
            })
        }
        entries.append(.separator)
        entries.append(.caption("Model"))
        for model in store.modelChoices.prefix(40) {
            entries.append(.item(title: model, isOn: model == store.current.model) {
                store.setModel(model)
            })
        }
        entries.append(.separator)
        entries.append(.item(title: "Refresh Models") { store.refreshModels() })
        return entries
    }
}

/// One turn. The user's on the right in a wash; the model's on the left, full width, with
/// its code blocks cut out so they can be sent to the shell.
private struct ChatMessageView: View {
    let message: ChatMessage
    let isArriving: Bool
    let sendToShell: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(Token.Colour.label)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Token.Colour.accentWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty, isArriving {
                    // Something is on its way. Three dots rather than nothing: a sent
                    // question with no reply under it reads as a send that failed.
                    Text("…")
                        .font(Token.Type_.tileSubtitle)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                } else {
                    ForEach(Array(MarkdownBlocks.split(message.text).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .prose(let text):
                            ProseView(markdown: text)
                        case .code(let language, let code):
                            CodeBlockView(language: language, code: code, sendToShell: sendToShell)
                        }
                    }
                }
                if let note = message.note {
                    Text(note)
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 20)
        }
    }
}

/// Prose, through Foundation's Markdown parser: emphasis, links and inline code, with
/// line breaks kept. Block structure — lists, headings — comes through as plain lines,
/// which reads fine at chat width.
private struct ProseView: View {
    let markdown: String

    var body: some View {
        Text(attributed)
            .font(Token.Type_.tileSubtitle)
            .foregroundStyle(Token.Colour.label)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var text = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }
        // The parser marks `code` spans but SwiftUI draws them in the body font; a flag
        // in backticks that renders like a dash is a flag the reader will mistype.
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = Token.Type_.mono
            text[run.range].backgroundColor = Token.Colour.label.opacity(0.08)
        }
        return text
    }
}

/// A fenced block: monospaced, in a box, with the two things worth doing to code in a
/// terminal app — copy it, or type it at the prompt without running it.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    let sendToShell: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(language ?? "code")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                Spacer(minLength: 4)
                if isHovering {
                    ChromeIconButton(symbol: "doc.on.doc", help: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    ChromeIconButton(symbol: "arrow.right.to.line", help: "Type at the prompt, without running") {
                        sendToShell(code.trimmingCharacters(in: .newlines))
                    }
                }
            }
            .frame(height: 24)
            .padding(.leading, 10)
            .padding(.trailing, 2)

            ScrollView(.horizontal) {
                Text(code)
                    .font(Token.Type_.mono)
                    .foregroundStyle(Token.Colour.label)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Token.Colour.label.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

#Preview("Chat", traits: .fixedLayout(width: 420, height: 520)) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    ChatTile(context: .inert(root: root), store: ChatStore(root: root))
}
