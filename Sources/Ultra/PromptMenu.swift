import AppKit
import SwiftUI
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal
import UltraTiles

/// One row of a prompt picker: what it inserts, and how it is shown.
struct PromptMenuItem: Identifiable, Equatable {
    var id: String { insert }
    var symbol: String
    var title: String
    var detail: String?
    /// What lands at the prompt when the row is picked: `@Sources/App.swift`, `/compact`.
    var insert: String
}

/// The picker's state, shared by the presenter that places it and the view that draws it.
@MainActor
@Observable
final class PromptMenuModel {
    let trigger: Character
    var query = ""
    var items: [PromptMenuItem] = []
    var isLoading = true
    var selection: String?
    /// Told the picker's size, every time SwiftUI lays it out, so the presenter can size
    /// its window to it.
    @ObservationIgnored var layoutChanged: ((CGSize) -> Void)?
    /// The outcome: text to type at the prompt, or nil for nothing.
    @ObservationIgnored var finish: ((String?) -> Void)?

    init(trigger: Character) { self.trigger = trigger }

    /// The rows for the query: a prefix match first, then a word that contains it, then a
    /// subsequence — "apsw" finds `App.swift` — and at most forty, since the field is for
    /// narrowing and a list that scrolls past forty has not been narrowed.
    var matches: [PromptMenuItem] {
        guard !query.isEmpty else { return Array(items.prefix(40)) }
        let needle = query.lowercased()
        var ranked: [(Int, Int, PromptMenuItem)] = []
        for (index, item) in items.enumerated() {
            let title = item.title.lowercased()
            let rank: Int
            if title.hasPrefix(needle) || title.split(separator: "/").last.map({ $0.hasPrefix(needle) }) == true {
                rank = 0
            } else if title.contains(needle) {
                rank = 1
            } else if fuzzyMatch(needle, title) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, index, item))
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(40).map(\.2)
    }

    var selected: PromptMenuItem? {
        matches.first { $0.id == selection } ?? matches.first
    }

    func moveSelection(by offset: Int) {
        let rows = matches
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? 0
        selection = rows[max(0, min(rows.count - 1, current + offset))].id
    }

    /// ↩: the selected row, or what was typed, as typed, behind the trigger — a command
    /// the table does not know is still a command.
    func pick() {
        if let selected { finish?(selected.insert) } else { finish?(String(trigger) + query) }
    }

    func cancel() { finish?(nil) }
}

/// The picker that opens when `@` or `/` is typed as the first character of an agent's
/// prompt — see `ShellTerminalView.promptTrigger` — and from Pane ▸ Insert File Reference…
/// and Insert Agent Command….
///
/// `@` lists the Context pane's files first, then the project's files by name; `/` lists
/// the running agent's commands, built in and the project's own. Typing narrows, ↑↓ move,
/// ↩ inserts the row at the prompt — without submitting, as a tile's send does — Esc
/// inserts nothing, and the trigger typed again inserts the trigger itself, so the key is
/// never dead. The terminal has the keyboard back the moment the picker goes.
///
/// A menu, so a window of its own: a borderless panel that is a child of the terminal's
/// window, the way the system's menus and completions are. Nothing in the window can
/// clip it — not the pane's rounded frame, not the window's edge — only the screen's
/// bounds, which it is kept inside. It opens at the caret cell and stays anchored to that
/// cell: the agent redrawing its prompt, or the list growing as its rows arrive, does not
/// move it. It follows its pane when the layout moves the pane, and goes when the pane
/// goes, when the window closes, or when the keyboard goes elsewhere.
@MainActor
final class PromptMenu {
    static let shared = PromptMenu()

    private var panel: PromptMenuPanel?
    private var host: NSHostingView<PromptMenuView>?
    private var model: PromptMenuModel?
    private weak var terminal: ShellTerminalView?
    /// The caret cell the picker opened at, in the terminal's coordinates.
    private var anchor: CGRect = .zero
    /// The picker's own size, as SwiftUI last laid it out.
    private var contentSize: CGSize = .zero
    private var observers: [any NSObjectProtocol] = []

    /// Show the picker for a trigger in a pane. False when it could not be shown — no
    /// such pane, or one with no terminal — in which case the key goes through as typed.
    @discardableResult
    static func present(_ trigger: Character, pane paneID: PaneID, workspace workspaceID: UUID) -> Bool {
        guard let factory = ShellWorkspace.Registry.factories[workspaceID],
              let terminal = factory.shells[paneID], terminal.window != nil else { return false }
        let store = ShellWorkspace.Registry.stores[workspaceID]
        let root = store?.workspaceDirectory.map { URL(fileURLWithPath: $0) }
            ?? ShellWorkspace.Registry.workingDirectory(in: workspaceID, fallback: URL(fileURLWithPath: NSHomeDirectory()))
        let items: @Sendable () async -> [PromptMenuItem]
        switch trigger {
        case "/":
            let agent = terminal.activity?.command ?? terminal.spec.agentCommand ?? ""
            items = { await Self.commandItems(for: agent, in: root) }
        default:
            let context = ShellWorkspace.Registry.tiles[workspaceID].map { tiles in
                tiles.contextPanes().compactMap { tiles.contextModel(for: $0) }
                    .flatMap(\.items).filter { !$0.isMissing }
                    .map { ContextModel.reference(for: $0, relativeTo: root) }
            } ?? []
            items = { await Self.fileItems(context: context, in: root) }
        }
        shared.show(trigger: trigger, in: terminal, items: items)
        return true
    }

    private func show(trigger: Character, in terminal: ShellTerminalView,
                      items: @escaping @Sendable () async -> [PromptMenuItem]) {
        dismiss(inserting: nil)
        guard let window = terminal.window else { return }
        self.terminal = terminal
        anchor = terminal.caretRect
        let model = PromptMenuModel(trigger: trigger)
        self.model = model
        let host = NSHostingView(rootView: PromptMenuView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host
        contentSize = host.intrinsicContentSize
        let panel = PromptMenuPanel()
        panel.contentView = host
        self.panel = panel
        model.layoutChanged = { [weak self] size in
            self?.contentSize = size
            self?.place()
        }
        model.finish = { [weak self] text in self?.dismiss(inserting: text) }
        // Placed before it is shown: a child window is on screen the moment it is added.
        place()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        watch(terminal: terminal, window: window, panel: panel)
        Task { [weak model] in
            let loaded = await items()
            guard let model else { return }
            model.items = loaded
            model.isLoading = false
            model.selection = model.matches.first?.id
        }
    }

    /// What moves or ends the picker. The pane's frame, or any frame above it, changing
    /// is the layout moving the pane: the picker is placed again by its anchor. The
    /// window's every update is a cheap check that the terminal is still in it — a pane
    /// closed under the picker posts no frame change of its own. The panel losing the
    /// keyboard — a click on a pane, another app coming forward — is the picker nobody is
    /// typing into, in the way.
    private func watch(terminal: ShellTerminalView, window: NSWindow, panel: NSPanel) {
        let center = NotificationCenter.default
        var view: NSView? = terminal
        while let current = view {
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                object: current, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
            view = current.superview
        }
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(inserting: nil) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(inserting: nil) }
        })
    }

    /// Below the anchor cell when there is room on the screen, above it otherwise, and
    /// never past the screen's edges. A terminal that has left the window — its pane
    /// closed under the picker — takes the picker with it.
    private func place() {
        guard let panel else { return }
        guard let terminal, let parent = terminal.window,
              panel.parent == nil || panel.parent === parent else { dismiss(inserting: nil); return }
        let caret = parent.convertToScreen(terminal.convert(anchor, to: nil))
        let bounds = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let frame = Self.frame(for: contentSize, at: caret, within: bounds)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Where a picker of `size` goes for a caret cell, in screen coordinates: under the
    /// cell with its left edge on the cell's, above it when the screen has no room
    /// below, and clamped to `bounds` — the screen's visible frame — with a margin.
    static func frame(for size: CGSize, at caret: CGRect, within bounds: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let gap: CGFloat = 4
        let width = min(size.width, bounds.width - 2 * margin)
        let height = min(size.height, bounds.height - 2 * margin)
        let x = max(bounds.minX + margin, min(caret.minX, bounds.maxX - margin - width))
        let below = caret.minY - gap - height
        let y = below >= bounds.minY + margin
            ? below
            : min(bounds.maxY - margin - height, caret.maxY + gap)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Take the picker down, typing `text` at the prompt if there is any, and give the
    /// terminal the keyboard back.
    private func dismiss(inserting text: String?) {
        guard let panel else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        host = nil
        model = nil
        if let terminal {
            if let text, !text.isEmpty {
                // A file reference composes with what follows; a command takes its own arguments.
                terminal.inject(text.hasPrefix("@") ? text + " " : text)
            }
            parent?.makeKey()
            terminal.window?.makeFirstResponder(terminal)
        }
        terminal = nil
    }

    // MARK: Sources

    /// The Context pane's files, then every file in the project by relative path. The
    /// walk is bounded — see `ProjectFiles` — and off the main actor.
    nonisolated static func fileItems(context: [String], in root: URL) async -> [PromptMenuItem] {
        var seen = Set<String>()
        var items: [PromptMenuItem] = []
        for reference in context where seen.insert(reference).inserted {
            items.append(PromptMenuItem(symbol: "paperclip", title: String(reference.dropFirst()),
                                        detail: "Context", insert: reference))
        }
        let paths = await Task.detached { ProjectFiles.list(in: root) }.value
        for path in paths {
            let insert = "@" + path
            guard seen.insert(insert).inserted else { continue }
            items.append(PromptMenuItem(symbol: path.hasSuffix("/") ? "folder" : "doc",
                                        title: path, detail: nil, insert: insert))
        }
        return items
    }

    /// The agent's commands: built in, the project's, the user's.
    nonisolated static func commandItems(for agent: String, in root: URL) async -> [PromptMenuItem] {
        let commands = await Task.detached { AgentCommands.commands(for: agent, in: root) }.value
        return commands.map { command in
            PromptMenuItem(symbol: command.origin == .builtIn ? "slash.circle" : "doc.text",
                           title: command.name,
                           detail: command.detail ?? (command.origin == .project ? "Project" : command.origin == .user ? "Yours" : nil),
                           insert: "/" + command.name)
        }
    }
}

/// The picker's window: borderless, clear behind the glass, with the system's shadow
/// cut to the picker's shape. It takes the keyboard — the field is typed into — but is
/// never the main window, so the terminal's window stays the one the app is about.
@MainActor
private final class PromptMenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The picker: a field with the trigger in front of it, and the rows under it. Drawn
/// like the command palette, smaller, since it is a thing of the pane rather than of the
/// window. No shadow of its own: the window it sits in casts one, cut to its shape.
struct PromptMenuView: View {
    @Bindable var model: PromptMenuModel
    @FocusState private var isFocused: Bool
    @State private var wasFocused = false

    static let rowHeight: CGFloat = 30
    static let width: CGFloat = 380

    private var shape: some InsettableShape { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(model.trigger))
                    .font(Token.Type_.monoSmall.weight(.semibold))
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .frame(width: 16)
                TextField(model.trigger == "/" ? "Command" : "File", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit { model.pick() }
                    .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                    .onKeyPress(.tab) { model.moveSelection(by: 1); return .handled }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.isLoading && model.items.isEmpty {
                row(symbol: "ellipsis", title: "Looking…", detail: nil, isSelected: false, isDim: true)
            } else if model.matches.isEmpty {
                row(symbol: "return", title: "Insert “\(model.trigger)\(model.query)” as typed",
                    detail: nil, isSelected: true, isDim: false)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.matches) { item in
                                row(symbol: item.symbol, title: item.title, detail: item.detail,
                                    isSelected: model.selected?.id == item.id, isDim: false)
                                    .contentShape(.rect)
                                    .onTapGesture { model.selection = item.id; model.pick() }
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .tileScrollBar()
                    .frame(height: min(CGFloat(model.matches.count) * (Self.rowHeight + 1) + 6, 7.5 * Self.rowHeight))
                    .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(width: Self.width)
        .clipShape(shape)
        .paletteGlass(in: shape)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.layoutChanged?($0) }
        .onAppear { isFocused = true }
        .task {
            for _ in 0..<8 where !isFocused {
                isFocused = true
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        .onChange(of: isFocused) { _, focused in
            // The keyboard went elsewhere — a click on another pane — and a picker nobody
            // is typing into is in the way. Only once it HAD the keyboard: the first focus
            // request can land late.
            if focused { wasFocused = true } else if wasFocused { model.cancel() }
        }
        .onChange(of: model.query) { _, query in
            // The trigger again is the trigger itself, typed: `@@` or `//` is one literal.
            if query == String(model.trigger) { model.finish?(String(model.trigger)); return }
            model.selection = model.matches.first?.id
        }
        .onExitCommand { model.cancel() }
    }

    private func row(symbol: String, title: String, detail: String?, isSelected: Bool, isDim: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isDim ? Token.Colour.tertiaryLabel : Token.Colour.secondaryLabel)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isDim ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Token.Colour.label.opacity(isSelected ? 0.12 : 0))
        }
        .padding(.horizontal, isDim || isSelected && model.matches.isEmpty ? 6 : 0)
        .padding(.bottom, isDim || model.matches.isEmpty ? 6 : 0)
    }
}

#Preview("Prompt menu", traits: .fixedLayout(width: 420, height: 320)) {
    let model = PromptMenuModel(trigger: "/")
    model.items = AgentCommands.builtIn(for: "claude").map {
        PromptMenuItem(symbol: "slash.circle", title: $0.name, detail: $0.detail, insert: "/" + $0.name)
    }
    model.isLoading = false
    return PromptMenuView(model: model).shadow(color: .black.opacity(0.3), radius: 18, y: 8).padding()
}
