import AppKit
import Carbon.HIToolbox
import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal

/// The answer window: a waiting agent's pane, small, in the corner of the display, while
/// Ultra is behind something else — so a permission prompt is answered from the browser
/// it interrupted rather than by coming back.
///
/// It is the notification's other form (`Preferences.agentAttention`), and it is raised
/// by the same thing: a turn that ended while nobody was looking at Ultra. What it shows
/// is what the sidebar already knows — the panes whose agent is asking, or has finished
/// and not been read (`AgentMonitor.stateByPane`) — one tab each.
///
/// The pane ITSELF, on a visit. The selected tab's pane is lent to a one-pane canvas in
/// this window the way a pane is lent to the Agents overview (`LayoutStore.send(_:toVisit:)`)
/// — the same view, the same process — so it is a terminal in every respect: colours,
/// the cursor, scrolling back, selecting, the mouse, an input method. Its project keeps
/// its place with a stand-in, and it goes home when another tab is chosen or the window
/// goes. The price is the one a resize always has: the program in it redraws for this
/// window's size, and again on the way back.
///
/// It was a mirror first — the bottom of the screen as text, keys handed to the pane's
/// view where it stood — to spare the agent that redraw. But a question is not always
/// its last sixteen lines: the diff above the prompt, the plan being approved, need
/// scrolling to and colour to read. The mirror is still what is shown for a pane that
/// cannot come: one already away on the Agents overview.
///
/// It never TAKES the keyboard. It comes up over an app someone is typing in, and a
/// window that took the keys would send half a sentence to an agent. A click gives it
/// the keyboard, or ⌘⎋ from anywhere; the same key gives it back.
@MainActor
@Observable
final class AnswerPanel {
    static let shared = AnswerPanel()

    /// One waiting pane: a tab.
    struct Entry: Identifiable, Equatable {
        let id: PaneID
        let workspaceID: UUID
        var project: String
        /// The agent's name — "Claude Code".
        var agent: String
        /// What it says it is working on, when it says.
        var title: String?
        var state: AgentState
    }

    /// The size it opens at, until it has been resized; and the smallest it goes.
    static let size = CGSize(width: 640, height: 440)
    static let minSize = CGSize(width: 420, height: 280)
    /// How far from the display's edges it sits.
    static let inset: CGFloat = 16
    /// How often the pane's screen is read while the window is up. Only then: hidden, it
    /// reads nothing.
    static let mirrorInterval: Duration = .milliseconds(200)

    private(set) var entries: [Entry] = []
    private(set) var selected: PaneID?
    /// The bottom of the selected pane's screen, cut down for the window.
    private(set) var lines: [String] = []
    /// Whether the window has the keyboard, which is whether typing reaches the pane.
    private(set) var isKey = false
    /// The pane that is in the window itself, on a visit to `store`. Nil while the
    /// selected pane is shown as text instead, or there is none.
    private(set) var hosted: PaneID?

    /// The window's canvas: one pane, the visitor — or a blank one while nobody visits.
    @ObservationIgnored let store: LayoutStore
    @ObservationIgnored private let placeholder = PaneID()
    /// Ultra Dev's preview: panes shown as if their agents were asking. See `showPreview`.
    @ObservationIgnored private var preview: [PaneID] = []
    @ObservationIgnored private var previewBegan = Date()

    /// Shown by hand (View ▸ Show Answer Window): up whatever Ultra is doing, with every
    /// waiting pane, until it is closed.
    @ObservationIgnored private var isPinned = false
    @ObservationIgnored private var window: AnswerWindow?
    /// Panes closed from the window, by the moment their state began: a pane put away
    /// stays away until it asks again.
    @ObservationIgnored private var dismissed: [PaneID: Date] = [:]
    /// Since when nobody has been looking at Ultra. Only what happened after is shown —
    /// a turn that ended while Ultra was in front was seen there, as a notification for
    /// it would not have been sent.
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var mirror: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        store = LayoutStore(tree: LayoutTree(single: placeholder), metrics: Self.metrics,
                            theme: Preferences.resolvedTheme(), storage: nil) { _ in
            // Only ever the blank pane: the visitor arrives by hand-over.
            PaneContent(view: NSView(), record: PaneRecord(kind: .placeholder, title: "Answer",
                                                           icon: "text.bubble"))
        }
        store.isFixedArrangement = true
        store.workspaceTitle = "Answer"
        // A pane closed here is closed at home, as on the overview.
        store.surfaces.onRelease = { [weak self] paneID in self?.store.visitorClosed(paneID) }
        store.onVisitorLeft = { [weak self] paneID in self?.visitorLeft(paneID) }
        store.setPaneKinds({ [] }) { _, _ in }
        store.surfaces.actions.split = { _, _ in NSSound.beep() }
        let placeholder = placeholder
        let named = store.surfaces.onBuild
        store.surfaces.onBuild = { [weak self] paneID in
            named?(paneID)
            guard let self, paneID == placeholder else { return }
            store.surfaces.existingSurface(for: paneID)?.isPlain = true
        }
        // This canvas resized the shell, so it asks the shell's own factory to commit.
        store.onGeometrySettled = { [weak self] in
            guard let self else { return }
            for home in store.visitors.values {
                ShellWorkspace.Registry.factories[home.session.workspaceID]?.commitResize()
            }
        }
    }

    /// The look's metrics with no padding round the canvas: the window's card is the edge.
    private static var metrics: LayoutMetrics {
        var metrics = LayoutMetrics.fromSettings
        metrics.padding = 0
        metrics.topPadding = 0
        metrics.edgeInset = 0
        return metrics
    }

    var isShown: Bool { window?.isVisible == true }

    /// Idempotent, and called with the monitor's `start`: from then on the window follows
    /// the app coming forward and going back at once, not on the monitor's next second.
    func start() {
        guard observers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     Preferences.didChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
    }

    // MARK: - What it shows

    /// Whether a pane in this state is one to answer: asking, or finished and not read —
    /// and, when `away` is given, only since then.
    static func wantsAnswer(_ state: AgentState, since away: Date?) -> Bool {
        switch state {
        case .needsYou, .done(_, read: false): away.map { state.since >= $0 } ?? true
        default: false
        }
    }

    /// Bring the tabs and the window in line with the agents. From the monitor, once a
    /// second, and whenever the app comes forward or goes back.
    func refresh() {
        let monitor = AgentMonitor.shared
        let watching = monitor.isWatching()
        if watching { awaySince = nil } else if awaySince == nil { awaySince = monitor.now() }
        let enabled = Preferences.notifiesOnAgentCompletion
            && Preferences.agentAttention == .answerWindow

        var next: [Entry] = []
        if !preview.isEmpty {
            for paneID in preview {
                if let entry = entry(for: paneID, state: .needsYou(since: previewBegan)) { next.append(entry) }
            }
        } else if isPinned || (enabled && !watching) {
            for (paneID, state) in monitor.stateByPane
            where Self.wantsAnswer(state, since: isPinned ? nil : awaySince)
                && dismissed[paneID] != state.since {
                if let entry = entry(for: paneID, state: state) { next.append(entry) }
            }
        }
        // The pane being answered stays while the keyboard is in the window: its agent
        // goes back to work on the answer, and a tab that vanished under the hands
        // would take the next question's first keys somewhere else.
        if window?.isKeyWindow == true, let selected, dismissed[selected] == nil,
           !next.contains(where: { $0.id == selected }),
           var held = entries.first(where: { $0.id == selected }), shell(for: selected) != nil {
            held.state = monitor.stateByPane[selected] ?? held.state
            next.append(held)
        }
        // Asking first, then finished; each the longest-waiting first.
        next.sort { first, second in
            let asking = (Self.isAsking(first.state), Self.isAsking(second.state))
            if asking.0 != asking.1 { return asking.0 }
            if first.state.since != second.state.since { return first.state.since < second.state.since }
            return first.id.uuidString < second.id.uuidString
        }
        dismissed = dismissed.filter { monitor.stateByPane[$0.key]?.since == $0.value }
        if next != entries { entries = next }
        if !entries.contains(where: { $0.id == selected }) { select(entries.first?.id) }
        if entries.isEmpty && !isPinned { hide() } else { show() }
        host()
    }

    // MARK: - The pane in the window

    /// Bring the selected pane into the window, and send home whichever was there.
    /// Only while the window is up: a hidden window holds nobody's pane.
    private func host() {
        guard isShown else { return }
        if let hosted, hosted != selected { sendHome(hosted) }
        guard let selected, hosted != selected,
              let entry = entries.first(where: { $0.id == selected }),
              let session = ShellWorkspace.Registry.stores[entry.workspaceID],
              let home = session.holder(of: selected), home !== store,
              // A pane already away — on the Agents overview — stays there, and is
              // shown here as text: a visitor is not its host's to lend on.
              home.home(of: selected) == nil,
              home.send(selected, toVisit: store) else { return }
        store.theme = Preferences.resolvedTheme()
        store.metrics = Self.metrics
        // The window's bar names the pane; a header under it would say it twice.
        store.surfaces.existingSurface(for: selected)?.isPlain = true
        store.rearrange(LayoutTree(single: selected))
        hosted = selected
        store.focus(selected)
        if isKey { store.reclaimKeyboardFocus() }
    }

    private func sendHome(_ paneID: PaneID) {
        store.surfaces.existingSurface(for: paneID)?.isPlain = false
        if store.home(of: paneID)?.takeHome(paneID) != true { visitorLeft(paneID) }
    }

    /// The visitor has gone — sent home, or its project closed it under the window.
    private func visitorLeft(_ paneID: PaneID) {
        if hosted == paneID { hosted = nil }
        if store.tree.contains(paneID) { store.rearrange(LayoutTree(single: placeholder)) }
    }

    private static func isAsking(_ state: AgentState) -> Bool {
        if case .needsYou = state { return true }
        return false
    }

    private func entry(for paneID: PaneID, state: AgentState) -> Entry? {
        guard let workspaceID = ShellWorkspace.Registry.factories
            .first(where: { $0.value.shells[paneID] != nil })?.key else { return nil }
        let terminal = AgentMonitor.shared.terminalsBySession[workspaceID]?.first { $0.id == paneID }
        let agent = terminal?.agentName ?? "Agent"
        return Entry(id: paneID, workspaceID: workspaceID,
                     project: ShellWorkspace.Registry.stores[workspaceID]?.workspaceTitle ?? "Shell",
                     agent: agent,
                     title: terminal.flatMap { $0.title == agent ? nil : $0.title },
                     state: state)
    }

    private func shell(for paneID: PaneID) -> ShellTerminalView? {
        for factory in ShellWorkspace.Registry.factories.values {
            if let shell = factory.shells[paneID] { return shell }
        }
        return nil
    }

    // MARK: - Actions

    func select(_ paneID: PaneID?) {
        guard paneID != selected else { return }
        selected = paneID
        host()
        readScreen()
    }

    /// The next tab, or the one before it, round the ends. ⇧⌘] and ⇧⌘[.
    func step(_ offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == selected }), entries.count > 1 else { return }
        select(entries[(index + offset + entries.count) % entries.count].id)
    }

    /// The bar's arrow, and ⌘↩: Ultra comes forward with the keyboard in this pane.
    func openInUltra() {
        guard let entry = entries.first(where: { $0.id == selected }) else { return }
        dismissed[entry.id] = entry.state.since
        isPinned = false
        hide()
        NSApplication.shared.activate()
        AgentsOverview.shared.reveal(entry.id, in: entry.workspaceID)
    }

    /// The bar's close, and ⌘W: the window goes, and what it was showing stays away
    /// until it asks again. The panes themselves are untouched.
    func close() {
        for entry in entries { dismissed[entry.id] = entry.state.since }
        isPinned = false
        preview = []
        entries = []
        select(nil)
        hide()
    }

    /// Ultra Dev only: the window, up and holding the keyboard, on the shells of the
    /// project in front as if each had an agent asking — to see and use the window
    /// without waiting for one to. Closed like the real thing.
    func showPreview() {
        guard AgentsOverview.isDevBuild else { return }
        let lists = SessionList.all
        let list = lists.first { $0.window?.isMainWindow == true }
            ?? lists.first { $0.window?.isVisible == true } ?? lists.first
        let panes = (list?.selected?.tree.paneIDs ?? []).filter { shell(for: $0) != nil }
        guard !panes.isEmpty else { NSSound.beep(); return }
        preview = Array(panes.prefix(3))
        previewBegan = Date()
        isPinned = true
        dismissed = [:]
        refresh()
        window?.makeKeyAndOrderFront(nil)
    }

    /// View ▸ Show Answer Window: up with every waiting pane and the keyboard, or away.
    func toggle() {
        if isShown { close(); return }
        isPinned = true
        dismissed = [:]
        refresh()
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘⎋, from any app, while the window is up: the keyboard goes to it, or back to
    /// whatever had it.
    func toggleKeyboard() {
        guard let window, window.isVisible else { return }
        if window.isKeyWindow {
            // Out and in again: a window that leaves hands the keyboard back to the
            // app in front, which a window merely told to resign does not.
            window.orderOut(nil)
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - The window

    private func show() {
        let window = window ?? makeWindow()
        guard !window.isVisible else { return }
        // The display the pointer is on: that is where the person is.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: visible.maxX - window.frame.width - Self.inset,
                                          y: visible.maxY - window.frame.height - Self.inset))
        }
        window.orderFrontRegardless()
        AnswerHotKey.register { AnswerPanel.shared.toggleKeyboard() }
        readScreen()
        mirror = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.mirrorInterval)
                self?.readScreen()
            }
        }
    }

    private func hide() {
        mirror?.cancel()
        mirror = nil
        AnswerHotKey.unregister()
        if let hosted { sendHome(hosted) }
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        if isKey { isKey = false }
    }

    /// The text shown for a pane that is not in the window. Nothing is read for one that is.
    private func readScreen() {
        let next = hosted != nil && hosted == selected ? [] : selected.flatMap(shell(for:)).map {
            AnswerScreen.lines(from: $0.screenTail(AnswerScreen.reads))
        } ?? []
        if next != lines { lines = next }
    }

    private func makeWindow() -> AnswerWindow {
        let content = NSHostingView(rootView: AnswerWindowRoot())
        // The window is sized by hand and by its edges, not by what is in it.
        content.sizingOptions = []
        let window = AnswerWindow(content: content)
        window.onKeyChange = { [weak self] isKey in
            guard let self, self.isKey != isKey else { return }
            self.isKey = isKey
            // The keyboard in the window is the keyboard in the pane.
            if isKey { store.reclaimKeyboardFocus() }
        }
        self.window = window
        // Before the menus and before the window's own views: every key the window is
        // given belongs to the pane, and ⌘W reaching File ▸ Close would close a pane in
        // a window that is not even in front.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        return window
    }

    /// One key given to the window. With ⌘ it is the window's own — or the pane's copy,
    /// paste and select all — and never the menu bar's: ⌘W reaching File ▸ Close, or ⌘D
    /// Pane ▸ Split, would act on a window that is not even in front. Without ⌘ it is the
    /// pane's: typed into it as the first responder when the pane is here, handed to its
    /// view where it stands when it is not.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let shell = selected.flatMap(shell(for:))
            switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
            case (UInt16(kVK_Return), _), (UInt16(kVK_ANSI_KeypadEnter), _): openInUltra()
            case (_, "w"), (_, "W"): close()
            case (_, "v"), (_, "V"): shell?.paste(self)
            case (_, "c"), (_, "C"): NSApp.sendAction(#selector(NSText.copy(_:)), to: shell, from: self)
            case (_, "a"), (_, "A"): NSApp.sendAction(#selector(NSText.selectAll(_:)), to: shell, from: self)
            case (_, "]"), (_, "}"): step(1)
            case (_, "["), (_, "{"): step(-1)
            case (_, let key):
                if let number = Int(key), entries.indices.contains(number - 1) {
                    select(entries[number - 1].id)
                }
            }
            return true
        }
        // In the window, the pane hears the key itself.
        if hosted != nil, hosted == selected { return false }
        if let shell = selected.flatMap(shell(for:)), shell.isRunning {
            shell.keyDown(with: event)
        }
        return true
    }
}

/// The window itself: borderless, floating over every app and Space, and able to hold
/// the keyboard without Ultra becoming the active app.
final class AnswerWindow: NSPanel {
    var onKeyChange: ((Bool) -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: AnswerPanel.size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: true)
        title = "Answer"
        isFloatingPanel = true
        level = .floating
        // It exists FOR when the app is not active.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The surface draws the shape; the window is whatever is not clear.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        contentView = content
        minSize = AnswerPanel.minSize
        // The size it was dragged to is the size it comes back at; where, is decided
        // each time it is shown.
        setFrameAutosaveName("AnswerWindow")
    }

    // A borderless window refuses the keyboard unless it says otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }
}

/// ⌘⎋, heard in every app, for as long as the answer window is up and no longer: the
/// one key path to a window that appears while another app has the keyboard. Carbon's
/// hot keys, since they are the ones that need no permission from anybody.
///
/// Two keys, one hand. It was ⌃⌥⌘A first — chosen to collide with nothing, and nearly
/// unpressable for it. ⌘⎋ is as free in practice, and Escape is the key for getting out
/// of where the keyboard is, which is what this does in both directions. Escape on its
/// own still goes to the pane.
@MainActor
enum AnswerHotKey {
    /// Spelled out: ⎋ is a glyph few people can name, and a hint nobody can read is no hint.
    static let display = "⌘Esc"
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in AnswerHotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        // 'UAns': any four characters, the app's own.
        let id = EventHotKeyID(signature: 0x55416E73, id: 1)
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    static func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

// MARK: - Views

/// The live window's content: the model's values, and redrawn when a preference moves —
/// the accent and the pane's colours are read as they are drawn.
private struct AnswerWindowRoot: View {
    var body: some View {
        let panel = AnswerPanel.shared
        _ = PreferencesModel.shared.revision
        return AnswerWindowView(entries: panel.entries, selected: panel.selected,
                                lines: panel.lines, isKey: panel.isKey,
                                canvas: panel.hosted != nil && panel.hosted == panel.selected
                                    ? panel.store : nil,
                                now: AgentMonitor.shared.minute,
                                select: { panel.select($0) },
                                open: { panel.openInUltra() },
                                close: { panel.close() })
    }
}

/// A bar — a tab per waiting pane, Open in Ultra, Close — over the selected pane's
/// screen, on the window's own surface.
struct AnswerWindowView: View {
    let entries: [AnswerPanel.Entry]
    let selected: PaneID?
    let lines: [String]
    let isKey: Bool
    /// The canvas the selected pane is on, when it is in the window; nil shows `lines`.
    var canvas: LayoutStore?
    let now: Date
    var select: (PaneID) -> Void = { _ in }
    var open: () -> Void = {}
    var close: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    private var entry: AnswerPanel.Entry? { entries.first { $0.id == selected } }
    private var theme: TerminalTheme { .matchingAppearance(scheme == .dark) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Token.Space.windowRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            status
            screen
            hint
        }
        .frame(minWidth: AnswerPanel.minSize.width, maxWidth: .infinity,
               minHeight: AnswerPanel.minSize.height, maxHeight: .infinity)
        .background {
            if Token.Environment_.reduceTransparency {
                Token.Colour.tileBackground
            } else {
                WindowSurface(alwaysActive: true)
            }
        }
        .clipShape(shape)
    }

    /// A project's name is its tab's, until two tabs would say the same thing.
    private func tabTitle(_ id: PaneID) -> String {
        guard let entry = entries.first(where: { $0.id == id }) else { return "" }
        let shared = entries.filter { $0.project == entry.project }.count > 1
        return shared ? "\(entry.project) · \(entry.title ?? entry.agent)" : entry.project
    }

    private var bar: some View {
        HStack(spacing: 4) {
            if let selected {
                ScrollView(.horizontal, showsIndicators: false) {
                    PillTabs(entries.map(\.id),
                             selection: Binding(get: { selected }, set: { select($0) }),
                             size: .small, title: tabTitle)
                }
            } else {
                Text("Answer")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 8)
            ChromeIconButton(symbol: "arrow.up.forward.app", help: "Open in Ultra (⌘↩)",
                             isEnabled: entry != nil, action: open)
            ChromeIconButton(symbol: "xmark", help: "Close (⌘W)", action: close)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    @ViewBuilder
    private var status: some View {
        if let entry {
            HStack(spacing: 6) {
                Circle().fill(dot(entry.state)).frame(width: 7, height: 7)
                Text(entry.agent).foregroundStyle(Token.Colour.label)
                Text(entry.state.title).foregroundStyle(Token.Colour.secondaryLabel)
                if let title = entry.title {
                    Text(title).foregroundStyle(Token.Colour.tertiaryLabel).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(entry.state.age(at: now)).foregroundStyle(Token.Colour.tertiaryLabel)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private func dot(_ state: AgentState) -> Color {
        switch state {
        case .needsYou: Token.Colour.agentNeedsYou
        case .working: Token.Colour.agentWorking
        default: Token.Colour.secondaryLabel
        }
    }

    /// The pane: itself, on the window's canvas — or, when it cannot come, its screen as
    /// text on a card of the pane's colour, the newest line at its foot. The border is
    /// where the keyboard is — the accent while keys reach the pane.
    private var screen: some View {
        let card = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let canvas {
                SplitCanvas(store: canvas, topInset: 0)
                    .clipShape(card)
            } else {
                ScrollView {
                    Text(entry == nil ? "No agent is waiting for you." : lines.joined(separator: "\n"))
                        .font(Token.Type_.terminal(11))
                        .foregroundStyle(entry == nil ? theme.dimForeground : theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .background(theme.background, in: card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            card.strokeBorder(isKey ? Token.Colour.focusBorder : Token.Colour.separator,
                              lineWidth: isKey ? max(1.5, Token.Space.focusRingWidth) : 1)
        }
        .padding(.horizontal, 10)
        .accessibilityLabel("Pane screen")
    }

    private var hint: some View {
        Text(isKey
             ? "Keys go to this pane  ·  \(AnswerHotKey.display) gives the keyboard back"
             : "Click here, or press \(AnswerHotKey.display), to answer")
            .font(.system(size: 10.5))
            .foregroundStyle(Token.Colour.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
    }
}

#Preview("Answer window") {
    let now = Date()
    let panes = [PaneID(), PaneID(), PaneID()]
    let entries = [
        AnswerPanel.Entry(id: panes[0], workspaceID: UUID(), project: "ultra-swift",
                          agent: "Claude Code", title: "Fix the sidebar drag",
                          state: .needsYou(since: now.addingTimeInterval(-140))),
        AnswerPanel.Entry(id: panes[1], workspaceID: UUID(), project: "website",
                          agent: "Codex", title: nil,
                          state: .done(at: now.addingTimeInterval(-30), read: false)),
        AnswerPanel.Entry(id: panes[2], workspaceID: UUID(), project: "notes",
                          agent: "Claude Code", title: nil,
                          state: .needsYou(since: now.addingTimeInterval(-5))),
    ]
    return VStack(spacing: 20) {
        AnswerWindowView(entries: entries, selected: panes[0],
                         lines: ["⏺ I'll remove the build folder.", "", "Bash command", "",
                                 "  rm -rf build", "", "Do you want to proceed?", "❯ 1. Yes",
                                 "  2. Yes, and don't ask again for rm commands in this folder",
                                 "  3. No, and tell Claude what to do differently (esc)"],
                         isKey: true, now: now)
        .frame(width: 460, height: 320)
        AnswerWindowView(entries: [], selected: nil, lines: [], isKey: false, now: now)
            .frame(width: 460, height: 320)
    }
    .padding(30)
}
