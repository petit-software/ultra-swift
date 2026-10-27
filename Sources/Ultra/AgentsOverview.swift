import AppKit
import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal

/// Every working agent's pane, from every session in every window, on one canvas.
///
/// One for the app. A window shows it in place of its session canvas (`UIState.showsAgents`)
/// and while it is up the panes with an agent in them VISIT it — the live surface is lent
/// by its home canvas (`LayoutStore.send(_:toVisit:)`), the home shows a stand-in, and
/// nothing is built or released on the way. An agent that starts anywhere while the view
/// is up joins on the monitor's next tick; a pane whose agent has gone goes home on the
/// next; closing the view sends every pane home to the place it never left.
///
/// Its store is a real `LayoutStore`, so the Pane menu, ⌘1…9, the arrows and zoom all act
/// on the grid — but a FIXED one (`isFixedArrangement`): the grid is whatever agents there
/// are, computed on every change, never split or converted.
@MainActor
@Observable
final class AgentsOverview {
    static let shared = AgentsOverview()

    /// What the sidebar's row is tagged with, since a `List` selection is a session id and
    /// the overview is not a session.
    static let selectionID = UUID()

    let store: LayoutStore
    /// What the grid shows when no agent is running: a tree cannot be empty, so this one
    /// pane stands in, and is the only pane the store's factory ever builds.
    private let placeholder = PaneID()
    private(set) var isOpen = false
    /// The window's sessions the overview is up in. One window at a time: a pane can only
    /// be in one place, and so can the canvas holding them.
    private(set) weak var list: SessionList?
    /// Visitors in the grid's reading order. A new agent joins at the end rather than
    /// reshuffling the panes someone is looking at, and a pane dragged to another place
    /// stays there: before a rebuild the order is read back from the tree as it stands.
    private var order: [PaneID] = []
    /// The panes the grid was last built for, so a tick that changes nothing rebuilds
    /// nothing: a grid tree is new node ids every time, and would read as a change.
    private var shown: [PaneID] = []
    /// Panes this overview opened itself, and when: an agent pane starts on its first
    /// layout, which the overview's canvas gives it, and until it is running the sample
    /// names no agent. Kept on the grid for a few seconds rather than sent home on the
    /// tick between the split and the start.
    private var opened: [PaneID: Date] = [:]
    private static let openingGrace: TimeInterval = 10
    /// Chat panes on the overview, with the state their strip shows. A chat joins while a
    /// turn is in flight and STAYS until the overview closes or the pane does: a turn
    /// ending is the answer arriving, not the chat leaving, and a pane that vanished as
    /// its answer landed would be the one thing on the grid you could not read.
    private var chats: [PaneID: AgentState] = [:]
    /// Ultra Dev only: stand-in panes shown to see the overview without three agents
    /// running. See `showDemo`.
    private let demo = DemoPanes()
    /// How many stand-ins the demo is showing, observed — `DemoPanes` is not — so the
    /// sidebar's row and the belt's tab count them as they would running agents.
    private(set) var demoAgents = 0

    /// What the sidebar's row and the belt's tab count: the agents running, or the demo's
    /// stand-ins while it is up, so the demo shows the whole design and not just the grid.
    var runningCount: Int { demoAgents > 0 ? demoAgents : AgentMonitor.shared.runningCount }

    /// Whether this is a build the demo may show in: Ultra Dev, or a bare `swift run`.
    nonisolated static var isDevBuild: Bool {
        let id = Bundle.main.bundleIdentifier
        return id == nil || id == "software.petit.ultra.dev"
    }

    private init() {
        let placeholder = placeholder
        let demo = demo
        store = LayoutStore(tree: LayoutTree(single: placeholder),
                            metrics: .fromSettings,
                            theme: Preferences.resolvedTheme(),
                            storage: nil) { paneID in
            // Only the placeholder — and, in Ultra Dev, the demo's stand-ins: every other
            // pane arrives by hand-over, and a factory asked for one would be building a
            // second surface on a live pane's id.
            if demo.ids.contains(paneID) { return demo.factory.makeContent(for: paneID) }
            let view = NSHostingView(rootView: AgentsEmptyState())
            view.focusRingType = .none
            return PaneContent(view: view,
                               record: PaneRecord(kind: .placeholder, title: "Agents",
                                                  icon: "circle.grid.2x2.fill"))
        }
        store.isFixedArrangement = true
        store.workspaceTitle = "Agents"
        // A pane closed here is closed at home — the one way a visit ends in a release.
        store.surfaces.onRelease = { [weak self] paneID in self?.store.visitorClosed(paneID) }
        store.onVisitorLeft = { [weak self] paneID in
            guard let self else { return }
            order.removeAll { $0 == paneID }
            rebuild()
        }
        // No kind menu: converting a pane belongs to its home canvas, where the factories
        // that would build the replacement live.
        store.setPaneKinds({ [] }) { _, _ in }
        store.surfaces.actions.split = { _, _ in NSSound.beep() }
        // The empty state is a note on the canvas, not a pane: no header, no ring.
        let named = store.surfaces.onBuild
        store.surfaces.onBuild = { [weak self] paneID in
            named?(paneID)
            guard let self, paneID == placeholder else { return }
            store.surfaces.existingSurface(for: paneID)?.isPlain = true
        }
        // Shells hear their settled size from their own factory; the overview's canvas
        // resized them, so it asks each visitor's factory to commit.
        store.onGeometrySettled = { [weak self] in
            guard let self else { return }
            let sessions = Set(store.visitors.values.map { $0.session.workspaceID })
            for id in sessions { ShellWorkspace.Registry.factories[id]?.commitResize() }
        }
    }

    // MARK: - Opening and closing

    /// Show the overview in this window. Another window showing it loses it: the panes
    /// stay where they are, on the one canvas, which the new window now shows.
    func open(in list: SessionList) {
        if isOpen, self.list !== list { self.list?.ui?.showsAgents = false }
        self.list = list
        isOpen = true
        // The look settings as they stand now: this store is not in the registry the
        // preference bridge pushes to.
        store.theme = Preferences.resolvedTheme()
        store.metrics = .fromSettings
        list.ui?.showsAgents = true
        // Now, rather than up to a second from now.
        AgentMonitor.shared.sample()
        store.reclaimKeyboardFocus()
    }

    /// Every pane home, the window back on its session.
    func close() {
        guard isOpen else { return }
        isOpen = false
        for (paneID, home) in store.visitors { home.takeHome(paneID) }
        order = []
        opened = [:]
        chats = [:]
        demo.ids = []
        demoAgents = 0
        rebuild()
        list?.ui?.showsAgents = false
        list?.selected?.reclaimKeyboardFocus()
    }

    /// ⌘0: up if it is down, down if it is up in this window — and moved here from
    /// another window if it is up there.
    func toggle(in list: SessionList) {
        if isOpen, self.list === list { close() } else { open(in: list) }
    }

    /// Whether the overview is what this window is showing.
    func isShowing(in list: SessionList) -> Bool { isOpen && self.list === list }

    // MARK: - The grid

    /// One tick of samples, from the monitor: panes with an agent come, panes without go
    /// home, and the grid is rebuilt if the set changed.
    func refresh(_ samples: [UUID: [PaneID: AgentPaneSample]]) {
        guard isOpen, demo.ids.isEmpty else { return }
        var wanted: [PaneID: UUID] = [:]
        for (workspaceID, panes) in samples {
            for (paneID, sample) in panes where sample.agent != nil { wanted[paneID] = workspaceID }
        }
        observeChats(into: &wanted)
        for (paneID, started) in opened where wanted[paneID] != nil || Date().timeIntervalSince(started) > Self.openingGrace {
            opened[paneID] = nil
        }
        for (paneID, home) in store.visitors where wanted[paneID] == nil && opened[paneID] == nil {
            home.takeHome(paneID)
        }
        // By session title then by id, so two agents arriving on one tick land in an
        // order that means something rather than a dictionary's.
        let arriving = wanted.filter { store.home(of: $0.key) == nil }.sorted { a, b in
            let titleA = ShellWorkspace.Registry.stores[a.value]?.workspaceTitle ?? ""
            let titleB = ShellWorkspace.Registry.stores[b.value]?.workspaceTitle ?? ""
            return (titleA, a.key.uuidString) < (titleB, b.key.uuidString)
        }
        for (paneID, workspaceID) in arriving {
            guard let session = ShellWorkspace.Registry.stores[workspaceID],
                  let home = session.holder(of: paneID), home !== store else { continue }
            if home.send(paneID, toVisit: store) { order.append(paneID) }
        }
        rebuild()
        dress()
    }

    /// Chat panes mid-turn join; the ones already here stay while their pane exists, and
    /// their strip says working or done from the turn.
    private func observeChats(into wanted: inout [PaneID: UUID]) {
        let now = Date()
        var seen: Set<PaneID> = []
        for (workspaceID, tiles) in ShellWorkspace.Registry.tiles {
            for paneID in tiles.chatPanes() {
                guard let chat = tiles.chatStore(for: paneID) else { continue }
                let previous = chats[paneID]
                if chat.isStreaming {
                    if case .working = previous {} else { chats[paneID] = .working(since: now) }
                } else if case .working = previous {
                    chats[paneID] = .done(at: now, read: true)
                }
                guard chats[paneID] != nil else { continue }
                seen.insert(paneID)
                wanted[paneID] = workspaceID
            }
        }
        for paneID in chats.keys where !seen.contains(paneID) { chats[paneID] = nil }
    }

    private func rebuild() {
        // The arrangement as the person left it, then whoever arrived since. Dragging a
        // pane into another cell changes the tree's reading order, and that order is the
        // one worth keeping when the grid is laid out again for a pane coming or going.
        let onScreen = store.tree.paneIDs.filter { store.visitors[$0] != nil }
        order = onScreen + order.filter { !onScreen.contains($0) }
        let panes = order.filter { store.visitors[$0] != nil }
        if panes != shown {
            shown = panes
            store.rearrange(LayoutTree.grid(of: panes, focused: store.tree.focused)
                            ?? LayoutTree(single: placeholder))
        }
        // A visitor that is its home's only pane cannot be closed here.
        store.surfaces.lockedOpen = Set(panes.filter { store.home(of: $0)?.session.tree.paneCount == 1 })
    }

    /// Each visitor's strip: its session's look and name, its agent's state and age.
    private func dress() {
        let monitor = AgentMonitor.shared
        for (paneID, home) in store.visitors {
            guard let container = store.surfaces.existingSurface(for: paneID) else { continue }
            let session = home.session
            let look = SessionLook.appearance(for: session)
            let tint = SessionTint(storedValue: look.tint)
            let state = monitor.stateByPane[paneID] ?? chats[paneID]
            let age = state?.age(at: monitor.minute)
            let key = [session.workspaceID.uuidString, session.workspaceTitle, look.symbol,
                       look.tint, state.map { "\($0)" } ?? "", age ?? ""].joined(separator: "|")
            guard container.visitStrip?.key != key else { continue }
            container.visitStrip = VisitStrip(
                symbol: SessionSymbols.resolved(look.symbol), tint: tint.color,
                title: session.workspaceTitle, detail: age,
                status: state.map { AnyView(AgentStateSymbol(state: $0).help($0.title)) },
                key: key) { [weak self] in self?.openProject(paneID) }
        }
    }

    // MARK: - Adding an agent

    /// The open projects that list an installed agent, by title: what the overview's
    /// New Pane offers. A project, not any pane — an agent belongs to a project's canvas,
    /// and that is where the new pane goes before it comes here to be watched.
    var projectsWithAgents: [(store: LayoutStore, agents: [AgentDefinition])] {
        ShellWorkspace.Registry.stores.values
            .filter { $0.workspaceDirectory != nil }
            .sorted { $0.workspaceTitle.localizedStandardCompare($1.workspaceTitle) == .orderedAscending }
            .map { ($0, ShellWorkspace.availableAgents(in: $0)) }
            .filter { !$0.agents.isEmpty }
    }

    /// Start an agent in a project and bring its pane here at once, focused. The pane is
    /// split off the project's focused pane, as New Agent Pane does there; its shell
    /// starts on the overview's first layout of it.
    func openAgent(_ agent: AgentDefinition, in session: LayoutStore) {
        guard isOpen else {
            ShellWorkspace.openShell(agent: agent, in: session)
            return
        }
        // A session restored into the sidebar and never shown has no bounds to judge a
        // split by. The overview's will do until its own canvas is laid out.
        session.assumeCanvasBounds(store.canvasBounds)
        guard ShellWorkspace.canOpenNewPane(in: session) else { NSSound.beep(); return }
        ShellWorkspace.openShell(agent: agent, in: session)
        let paneID = session.tree.focused
        guard session.send(paneID, toVisit: store) else { return }
        order.append(paneID)
        opened[paneID] = Date()
        rebuild()
        dress()
        store.focus(paneID)
        store.reclaimKeyboardFocus()
    }

    // MARK: - Demo (Ultra Dev)

    /// Ultra Dev only: the overview as it looks with three agents running, without
    /// running any — three placeholder transcripts wearing strips in the three live
    /// states. The tick leaves the grid alone while the demo is up; ⌘0 closes it like
    /// the real thing. For looking at the design; never in a release build.
    func showDemo(in list: SessionList) {
        guard Self.isDevBuild else { return }
        open(in: list)
        let ids = (0..<3).map { _ in PaneID() }
        demo.ids = ids
        demoAgents = ids.count
        order = []
        shown = ids
        store.rearrange(LayoutTree.grid(of: ids)!)
        let now = Date()
        let strips: [(String, SessionTint, String, AgentState)] = [
            ("shippingbox.fill", .orange, "ultra-swift", .working(since: now.addingTimeInterval(-70))),
            ("cart.fill", .green, "checkout-api", .needsYou(since: now.addingTimeInterval(-20))),
            ("paintpalette.fill", .purple, "design-system", .done(at: now.addingTimeInterval(-240), read: false)),
        ]
        for (paneID, strip) in zip(ids, strips) {
            store.surfaces.surface(for: paneID).visitStrip = VisitStrip(
                symbol: strip.0, tint: strip.1.color, title: strip.2, detail: strip.3.age(at: now),
                status: AnyView(AgentStateSymbol(state: strip.3).help(strip.3.title)),
                key: strip.2) { [weak self] in self?.close() }
        }
        store.reclaimKeyboardFocus()
    }

    /// The demo's panes and the factory that draws them. A box, so the store's factory
    /// closure can reach it without capturing an overview that does not exist yet.
    @MainActor
    private final class DemoPanes {
        var ids: [PaneID] = []
        let factory = PlaceholderPaneFactory(theme: Preferences.resolvedTheme())
    }

    // MARK: - Going to a pane

    /// Put the keyboard in a pane, wherever it is: on the overview if it is visiting
    /// there, else in its session, raised — or opened into a window if none shows it.
    /// What a notification's click and the menu bar's list do.
    func reveal(_ paneID: PaneID, in workspaceID: UUID? = nil) {
        if isOpen, store.home(of: paneID) != nil {
            list?.window?.makeKeyAndOrderFront(nil)
            store.focus(paneID)
            store.reclaimKeyboardFocus()
            return
        }
        let session = workspaceID.flatMap { ShellWorkspace.Registry.stores[$0] }
            ?? ShellWorkspace.Registry.stores.values.first { $0.holder(of: paneID) != nil }
        guard let session else { return }
        if !SessionList.raise(workspaceID: session.workspaceID),
           let directory = session.workspaceDirectory {
            (list ?? SessionList.anyShowing)?.open(directory: directory)
        }
        guard let holder = session.holder(of: paneID) else { return }
        if let window = PaneWindows.window(for: holder) { window.makeKeyAndOrderFront(nil) }
        holder.focus(paneID)
        holder.reclaimKeyboardFocus()
    }

    /// The panes whose agent is asking, longest-waiting first, each with its session.
    var waiting: [(paneID: PaneID, session: LayoutStore)] {
        AgentMonitor.shared.stateByPane
            .compactMap { paneID, state -> (PaneID, Date)? in
                if case .needsYou(let since) = state { (paneID, since) } else { nil }
            }
            .sorted { $0.1 < $1.1 }
            .compactMap { paneID, _ in
                ShellWorkspace.Registry.stores.values.first { $0.holder(of: paneID) != nil }
                    .map { (paneID, $0) }
            }
    }

    /// ⌥⌘0: the pane that has waited longest, wherever it is.
    func openWaiting() {
        guard let first = waiting.first else { NSSound.beep(); return }
        reveal(first.paneID, in: first.session.workspaceID)
    }

    // MARK: - Going to a project

    /// Whether the focused pane of `store` is a visitor with somewhere to go.
    func canOpenProject(from store: LayoutStore) -> Bool {
        store === self.store && store.home(of: store.tree.focused) != nil
    }

    /// Take the pane home and go there: the overview closes, the pane's session comes on
    /// screen in whichever window has it — or in this one, taken back if its window has
    /// closed — and the pane has the keyboard.
    func openProject(_ paneID: PaneID) {
        guard let home = store.home(of: paneID) else { return }
        let session = home.session
        let list = list
        close()
        if !SessionList.raise(workspaceID: session.workspaceID),
           let directory = session.workspaceDirectory {
            list?.open(directory: directory)
        }
        if let window = PaneWindows.window(for: home) { window.makeKeyAndOrderFront(nil) }
        home.focus(paneID)
        home.reclaimKeyboardFocus()
    }
}

/// The overview's New Pane: an agent, in one of the open projects. The window bar's `+`
/// and Pane ▸ New Pane both show this while the overview is up, so the keyboard reaches
/// it through the menu.
struct AgentProjectsMenuItems: View {
    var body: some View {
        let projects = AgentsOverview.shared.projectsWithAgents
        if projects.isEmpty {
            Text("None of your open projects has an agent set up yet — add one under Customize")
        }
        ForEach(projects, id: \.store.workspaceID) { entry in
            Section(entry.store.workspaceTitle) {
                ForEach(entry.agents) { agent in
                    Button(agent.name) { AgentsOverview.shared.openAgent(agent, in: entry.store) }
                        .help(agent.command)
                }
            }
        }
    }
}

/// The grid with nothing in it. Says where an agent comes from, since the overview
/// cannot start one: a pane belongs to a project.
struct AgentsEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text("No agents running")
                .font(Token.Type_.tileTitle)
                .foregroundStyle(Token.Colour.secondaryLabel)
            Text("Start one in an open project from the + above, or type an agent at any shell: it appears here while it runs.")
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Agents — empty", traits: .fixedLayout(width: 640, height: 400)) {
    AgentsEmptyState()
        .background(Token.Colour.tileBackground)
}

#Preview("Agents — four visitors", traits: .fixedLayout(width: 900, height: 600)) {
    // Placeholder panes wearing strips, the way visitors do; no store lends anything here.
    let store = LayoutStore.placeholders(.grid2x2)
    let now = Date()
    let strips: [(String, Color, String, AgentState)] = [
        ("shippingbox.fill", .orange, "ultra-swift", .working(since: now.addingTimeInterval(-70))),
        ("cart.fill", .green, "checkout-api", .needsYou(since: now)),
        ("paintpalette.fill", .purple, "design-system", .done(at: now.addingTimeInterval(-240), read: false)),
        ("book.fill", .blue, "docs", .done(at: now.addingTimeInterval(-720), read: true)),
    ]
    for (paneID, strip) in zip(store.tree.paneIDs, strips) {
        store.surfaces.surface(for: paneID).visitStrip = VisitStrip(
            symbol: strip.0, tint: strip.1, title: strip.2, detail: strip.3.age(at: now),
            status: AnyView(AgentStateSymbol(state: strip.3)), key: strip.2, open: {})
    }
    return CanvasSurface(store: store)
}
