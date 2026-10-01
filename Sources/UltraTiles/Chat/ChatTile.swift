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
            store.refreshEngineModels()
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
                                    root: context.projectRoot,
                                    sendToShell: { context.injectIntoShell($0) },
                                    openFile: { context.openInEditor(.file($0)) })
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
        HStack(alignment: .center, spacing: 6) {
            TextField(store.canSend ? "Ask \(store.current.provider.title)…" : "See Settings ▸ Chat",
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
            // A touch bigger than the text beside it, and centred on the field: the one
            // control in the pill should sit in it, not hang off its last line.
            TodoRowSlot {
                if store.isStreaming {
                    ThinkingStopButton(stop: store.stop)
                        .transition(ThinkingStopButton.thinkingTransition)
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Token.Colour.accent)
                        .help("Send (Return; ⌥Return for a new line)")
                        .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSend)
                }
            }
            .font(.system(size: 17))
            // The slot's two states swap with the star's own entrance and exit; the send
            // arrow underneath simply appears, since it is faded out while the draft is
            // empty anyway.
            .animation(Token.Motion.thinkingArrive, value: store.isStreaming)
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
            TileFooterButton(symbol: "plus.capsule.fill", help: "New chat (⌥⌘N)") {
                store.newConversation()
                draftFocused = true
            }
            ChromeMenuButton(symbol: "tray.fill", help: "Earlier chats in this project") {
                conversationEntries
            }
            ChromeMenuButton(symbol: "cpu", help: "Provider and model") {
                modelEntries
            }
            // The browser's sun and moon, with the same key: a pane pinned light, or one
            // that follows the app. Also on Pane ▸ Chat, so it is not pointer-only.
            TileFooterButton(symbol: store.isLight ? "moon" : "sun.max",
                             help: store.isLight ? "Follow the App's Appearance (⌃⌘L)"
                                                 : "Show Chat Light (⌃⌘L)") {
                store.toggleLight()
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
        // Grouped by how each is paid for — on this Mac, a plan, a key — because that is
        // the choice a user makes first; the vendor comes second.
        var entries: [ChromeMenuEntry] = []
        for group in ChatProviderID.Group.allCases where !group.providers.isEmpty {
            entries.append(.caption(group.title))
            for provider in group.providers {
                let usable = provider == .apple ? store.appleUnavailable == nil : ChatCredentials.isConfigured(provider)
                let isCurrent = provider == store.current.provider
                if group == .subscription, usable {
                    // An engine's models sit inside its row: a plan has a handful, so
                    // picking one is one gesture, and the tick shows through the row.
                    let models = store.models[provider] ?? [provider.defaultModel]
                    entries.append(.submenu(title: provider.title, entries: Self.modelRows(
                        models, current: isCurrent ? store.current.model : "") { model in
                            store.choose(provider: provider, model: model)
                        }))
                } else {
                    entries.append(.item(title: provider.title, isOn: isCurrent, isEnabled: usable) {
                        store.setProvider(provider)
                        store.refreshModels()
                    })
                }
            }
        }
        // The current provider's list below, for the providers whose row does not hold it.
        if store.current.provider.group != .subscription {
            entries.append(.separator)
            entries.append(.caption("Model"))
            entries += Self.modelRows(store.modelChoices, current: store.current.model) { store.setModel($0) }
        }
        entries.append(.separator)
        entries.append(.item(title: "Refresh Models") {
            store.refreshModels()
            store.refreshEngineModels()
        })
        return entries
    }

    /// The models as menu rows. A list of `vendor/model` ids — OpenRouter's, hundreds long —
    /// becomes one submenu per vendor, so a model is two steps away rather than a scroll
    /// through everything sorted before it. Any other list is the rows themselves.
    static func modelRows(_ models: [String], current: String,
                          choose: @escaping (String) -> Void) -> [ChromeMenuEntry] {
        let row: (String, String) -> ChromeMenuEntry = { title, id in
            .item(title: title, isOn: id == current) { choose(id) }
        }
        let vendored = models.filter { $0.contains("/") }
        guard vendored.count > 1 else { return models.map { row($0, $0) } }

        var vendors: [String] = []
        var byVendor: [String: [String]] = [:]
        for id in vendored {
            let vendor = String(id[..<id.firstIndex(of: "/")!])
            if byVendor[vendor] == nil { vendors.append(vendor) }
            byVendor[vendor, default: []].append(id)
        }
        var rows = models.filter { !$0.contains("/") }.map { row($0, $0) }
        for vendor in vendors.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let items = byVendor[vendor, default: []].map { id in
                row(String(id.dropFirst(vendor.count + 1)), id)
            }
            rows.append(.submenu(title: vendor, entries: items))
        }
        return rows
    }
}

/// One turn. The user's on the right in a wash; the model's on the left, full width, with
/// its code blocks cut out so they can be sent to the shell.
private struct ChatMessageView: View {
    let message: ChatMessage
    let isArriving: Bool
    let root: URL
    let sendToShell: (String) -> Void
    let openFile: (URL) -> Void

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
                if message.isEmpty, isArriving {
                    // Something is on its way. Three dots rather than nothing: a sent
                    // question with no reply under it reads as a send that failed.
                    Text("…")
                        .font(Token.Type_.tileSubtitle)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                } else if !message.text.isEmpty {
                    ForEach(Array(MarkdownBlocks.split(message.text).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .prose(let text):
                            ProseView(markdown: text)
                        case .heading(let text):
                            HeadingView(markdown: text)
                        case .list(let items):
                            ListView(items: items)
                        case .code(let language, let code):
                            CodeBlockView(language: language, code: code, sendToShell: sendToShell)
                        }
                    }
                }
                if let calls = message.toolCalls, !calls.isEmpty {
                    // The edits become one table of the files they changed, standing
                    // where the first of them was; every other call stays a row.
                    let firstEdit = ChangedFile.firstEdit(in: calls)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(calls) { call in
                            if (call.changes ?? []).isEmpty {
                                ToolCallRow(call: call)
                            } else if call.id == firstEdit {
                                ChangedFilesTable(files: ChangedFile.rows(in: calls), root: root, open: openFile)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                    // The tools have answered and the model has not yet gone on: the same
                    // three dots, so the wait for the next turn does not read as the end.
                    if isArriving, calls.allSatisfy({ $0.result != nil }) {
                        Text("…")
                            .font(Token.Type_.tileSubtitle)
                            .foregroundStyle(Token.Colour.tertiaryLabel)
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

/// The composer's control while an answer is on its way: a four-pointed star turning, so
/// the wait reads as the model working rather than the pane doing nothing — and, under
/// the pointer, the stop button, so stopping is in the same place as the sign that there
/// is something to stop. The whole thing is the button: a click on the star stops too,
/// and Escape stops without touching it.
///
/// The star does not spin at one speed. It turns half a revolution, slowing to a near
/// stop, rests a beat, and goes again — the rhythm of something working in strokes, not a
/// loading wheel. Half a turn on a four-pointed star lands on the same picture, so the
/// repeat has no seam. It arrives by zooming in from small and leaves by shrinking away;
/// the composer animates the swap (`thinkingTransition`). Someone who asked for less
/// motion gets a slow breath of opacity instead: it still says "working", without
/// anything going round.
struct ThinkingStopButton: View {
    let stop: () -> Void
    @State private var isHovering = false

    /// Half a turn, then a rest. The turn eases in and out so it reads as a stroke; the
    /// rest is long enough to be a rest and short enough that the star is never mistaken
    /// for stopped.
    private static let turn: TimeInterval = 0.9
    private static let rest: TimeInterval = 0.4

    /// How the star comes and goes in the composer's slot. Asymmetric on purpose: in with
    /// a spring, out with a plain ease — see `Token.Motion.thinkingArrive`.
    static var thinkingTransition: AnyTransition {
        if Token.Environment_.reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .scale(scale: 0.3).combined(with: .opacity)
                .animation(Token.Motion.thinkingArrive),
            removal: .scale(scale: 0.3).combined(with: .opacity)
                .animation(Token.Motion.thinkingLeave))
    }

    private struct Pose {
        var angle: Angle = .zero
        var opacity: Double = 1
    }

    var body: some View {
        Button(action: stop) {
            ZStack {
                star.opacity(isHovering ? 0 : 1)
                    .scaleEffect(isHovering ? 0.6 : 1)
                Image(systemName: "stop.circle.fill")
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.6)
            }
            .frame(width: TodoRowSlot<EmptyView>.width, height: TodoRowSlot<EmptyView>.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Token.Colour.label : Token.Colour.secondaryLabel)
        .animation(Token.Motion.chromeFade, value: isHovering)
        .onHover { isHovering = $0 }
        .help("Stop (Esc)")
        .accessibilityLabel("Thinking")
        .accessibilityHint("Stops the answer")
    }

    private var star: some View {
        let reduceMotion = Token.Environment_.reduceMotion
        return KeyframeAnimator(initialValue: Pose(), repeating: true) { pose in
            ThinkingStar()
                .fill(.foreground)
                .frame(width: 17, height: 17)
                .rotationEffect(pose.angle)
                .opacity(pose.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                if reduceMotion {
                    LinearKeyframe(.zero, duration: Self.turn + Self.rest)
                } else {
                    // Zero velocity at both ends: the turn starts from rest and comes to
                    // rest, and the hold that follows is the pause between strokes.
                    CubicKeyframe(.degrees(180), duration: Self.turn,
                                  startVelocity: .zero, endVelocity: .zero)
                    LinearKeyframe(.degrees(180), duration: Self.rest)
                }
            }
            KeyframeTrack(\.opacity) {
                if reduceMotion {
                    CubicKeyframe(0.45, duration: 0.8)
                    CubicKeyframe(1, duration: 0.8)
                } else {
                    LinearKeyframe(1, duration: Self.turn + Self.rest)
                }
            }
        }
    }
}

#Preview("Thinking", traits: .fixedLayout(width: 80, height: 40)) {
    ThinkingStopButton(stop: {}).font(.system(size: 17)).padding()
}

/// One thing the model looked at on the way to its answer: "Read Package.swift". Quiet —
/// it is provenance, not content — and the whole of what is shown; what came back is for
/// the model, and the file is a pane away.
private struct ToolCallRow: View {
    let call: ChatToolCall

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(ProjectFiles.summary(of: call))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch call.name {
        case "read_file", "Read": "doc.text"
        case "list_files": "folder"
        case "command", "Bash": "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "edit": "pencil"
        default: "magnifyingglass"
        }
    }
}

/// Prose, through Foundation's Markdown parser: emphasis, links and inline code, with
/// line breaks kept. Block structure — lists, headings, fences — was cut out before it
/// got here (`MarkdownBlocks`), so one of these is one paragraph.
private struct ProseView: View {
    let markdown: String

    var body: some View {
        Text(ProseView.attributed(markdown))
            .font(Token.Type_.tileSubtitle)
            .foregroundStyle(Token.Colour.label)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ markdown: String) -> AttributedString {
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

/// A heading, as its own line in the title weight — the one place an answer is allowed
/// to be heavier than its prose. The prompt asks the model not to use them, so this is for
/// the answers that do anyway.
private struct HeadingView: View {
    let markdown: String

    var body: some View {
        Text(ProseView.attributed(markdown))
            .font(Token.Type_.tileTitle)
            .foregroundStyle(Token.Colour.label)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

/// A list, drawn as one: a bullet or the item's number in a column of its own, the text
/// beside it and wrapping under itself, each level of nesting stepped in. The marker is
/// quieter than the text, so a list of twelve things is twelve things and not a fence.
private struct ListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.ordinal ?? "•")
                        .font(Token.Type_.tileSubtitle)
                        .foregroundStyle(Token.Colour.secondaryLabel)
                        .frame(minWidth: 14, alignment: .trailing)
                    ProseView(markdown: item.text)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A fenced block: monospaced, in a box, with the two things worth doing to code in a
/// terminal app — copy it, or type it at the prompt without running it. Both float over
/// the header's trailing end on the glass pill every other tile's rows use.
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
            }
            .frame(height: 24)
            .padding(.horizontal, 10)
            // Over the header row, so the pill sits on the row's centre line, in from the
            // box's corner by the same margin the label keeps on the other side.
            .tileHoverControls(isHovering, offset: CGSize(width: -6, height: 0)) {
                HStack(spacing: 7) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy")
                    Button {
                        sendToShell(code.trimmingCharacters(in: .newlines))
                    } label: { Image(systemName: "arrow.right.to.line") }
                        .help("Type at the prompt, without running")
                }
                .font(.system(size: 11))
            }

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

#Preview("Chat — light", traits: .fixedLayout(width: 420, height: 520)) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    ChatTile(context: .inert(root: root), store: ChatStore(root: root, isLight: true))
        .preferredColorScheme(.light)
}
