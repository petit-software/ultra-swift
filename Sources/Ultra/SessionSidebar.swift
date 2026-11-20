import AppKit
import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal

/// The window's sessions, as the sidebar column of a `NavigationSplitView`.
///
/// This is where macOS window tabs used to be. A tab bar hides itself at one tab, has room
/// for a name only until there are about four, and lives in the one strip the traffic lights
/// already own. A sidebar has none of those problems: visible at one session, good for a
/// dozen, and each row has room to say which project it is.
///
/// Deliberately just the LIST and the bar under it. The column, its width, its collapse
/// behaviour, the traffic lights sitting over it, the material behind it and the toggle
/// button in the toolbar are all `NavigationSplitView`'s — an earlier version hand-rolled
/// every one of those out of an `HStack` and a spacer, which is how you end up maintaining a
/// worse copy of AppKit.
struct SessionSidebar: View {
    @Bindable var sessions: SessionList
    /// The window's UI state, for two flags: whether the selected row's customise sheet is
    /// open, and whether the new-project sheet is up. Both live up there because File ▸
    /// Session ▸ Customize Session… and File ▸ New Project… have to be able to open them
    /// without going through the sidebar at all.
    @Bindable var ui: UIState
    /// The folder picker lives in the app's command layer, so the bar asks for it rather
    /// than opening its own — two `NSOpenPanel`s configured separately drift apart.
    let openFolder: () -> Void
    /// The window's controls for the head of the column: drawn in its top right corner,
    /// level with the traffic lights. The window's, not the sidebar's — it only gives
    /// them their place — so they are handed in (`RootView.windowBarMenus`).
    var headControls = AnyView(EmptyView())
    /// Bumped when a project's look or the aurora setting changes — see `Aurora`.
    @State private var lookRevision = 0

    private var auroraColour: NSColor? {
        _ = lookRevision
        return Aurora.colour(sessions: sessions, ui: ui)
    }

    private var selection: Binding<UUID?> {
        Binding(get: { ui.showsAgents ? AgentsOverview.selectionID : sessions.selectedID },
                set: { id in
                    guard let id else { return }
                    // The row above the sessions: not a session, so not `select`.
                    if id == AgentsOverview.selectionID {
                        AgentsOverview.shared.open(in: sessions)
                        return
                    }
                    // Clicking a row leaves AppKit's first responder on the LIST. Nothing
                    // about that changes the model, so the canvas has no reason to re-assert
                    // itself and the shell you just switched to could not be typed into —
                    // which is why `select` itself asks for the keyboard back, for this
                    // route and for the four others that never came through here.
                    sessions.select(id)
                })
    }

    var body: some View {
        // NO background of its own: the list sits on the window's surface, as the panes'
        // gutters do. On macOS 26 the column is a sheet of glass holding its content, and
        // that glass reads as a second surface beside the canvas. It cannot be taken off —
        // it IS the column — so the window's material is laid inside it, the same view
        // `RootView` puts behind the canvas. The divider and the shadow the split view
        // lays down the column's edge are taken off too (`SidebarColumnChrome`), so
        // nothing parts the sidebar's side of the window from the canvas's.
        ZStack {
            if Token.Environment_.reduceTransparency {
                Token.Colour.tileBackground.ignoresSafeArea()
            } else {
                // The LEFT corners only: those are the window's. With the project's
                // colour, since this surface covers the window's own: the aurora is placed
                // by the window, so the part of its arc that falls here is drawn here.
                WindowSurface(corners: [.layerMinXMinYCorner, .layerMinXMaxYCorner],
                              aurora: auroraColour)
                    .ignoresSafeArea()
            }
            list
                // Under the list, which is where every source list on this platform puts
                // "add" — Finder's sidebar, Mail's mailboxes, Xcode's navigator. It was a
                // toolbar item, up in the strip the traffic lights own and a long way from
                // the list it adds to.
                .overlay(alignment: .bottom) {
                    SessionSidebarBar(sessions: sessions, ui: ui, openFolder: openFolder)
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionAppearanceStore.didChange)) { _ in
            lookRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: Preferences.didChange)) { _ in
            lookRevision &+= 1
        }
        // One kind of thing in one group, so a header would be a word explaining a list that
        // explains itself. The editor's sidebar has two sections because it holds two kinds.
        // In the title band, over the column's top right corner — the selected row's
        // capsule ends as far in from the edge.
        .overlay(alignment: .topTrailing) {
            headControls
                .padding(.trailing, Self.capsuleInset)
                .ignoresSafeArea()
        }
        // In an overlay because a `background` on the column's root is never built.
        .overlay { SidebarColumnChrome().accessibilityHidden(true) }
    }

    /// The space between the Agents row and the first project.
    private static let agentsGap: CGFloat = 6
    /// The content height every list row is at least stretched to; see the Agents row.
    @Environment(\.defaultMinListRowHeight) private var minRowHeight
    /// A row's height: the list's minimum and 1pt more above and below what is in it. A
    /// row's content is shorter than the minimum and is stretched to it, so padding the
    /// content alone changed nothing; the minimum itself is what has to grow.
    private var rowHeight: CGFloat { minRowHeight + 2 }

    // MARK: Dragging
    //
    // The belt's drag, turned on its side, and for the belt's reasons: the sidebar owns
    // the whole of it — where the row is, where it would land (`TabStripReorder`, counting
    // down instead of along), and whether it lands at all. It was the list's own `onMove`,
    // which reorders and nothing else: it draws its own image, says nothing about a row
    // let go anywhere but on the list, and so could not tell a row dragged out to become
    // a window from one dropped nowhere.
    //
    // The press is NOT a SwiftUI gesture. A `DragGesture` on a list row never fires: the
    // list is an `NSTableView`, whose own mouse-down runs a tracking loop that takes every
    // move until the button comes up. So the press is taken before the table sees it, by
    // `SidebarRowPress`, which reports a click, a pick-up, every move and the release.

    /// Each session row's frame as last laid out, in the window.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The project whose right-click menu is up.
    @State private var menuRowID: UUID?
    /// The list's frame, in the window: what the rows are drawn against while dragging,
    /// and the edge past which a row has left.
    @State private var listFrame: CGRect = .zero
    @State private var drag: RowDrag?
    /// Escape cancelled a drag the pointer is still holding; the rest of it is ignored.
    @State private var dragCancelled = false
    @State private var escapeMonitor: EventMonitor?

    /// How far outside the list a release still counts as on it.
    private static let releaseMargin: CGFloat = 24
    /// The capsule's inset from the column's sides, as `SelectedProjectWash` has it.
    private static let capsuleInset: CGFloat = 10

    /// The rows as a strip running down: each as tall as it is — a project listing its
    /// terminals is taller than one that is not — with the list's own gap between. Nil
    /// until every row is measured, and with one session, which has nowhere to go.
    private var strip: TabStripReorder? {
        let frames = sessions.sessions.compactMap { rowFrames[$0.workspaceID] }
        guard frames.count == sessions.sessions.count, frames.count > 1 else { return nil }
        return TabStripReorder(widths: frames.map(\.height),
                               spacing: max(0, frames[1].minY - frames[0].maxY),
                               leading: frames[0].minY)
    }

    private func draggedMinY(_ drag: RowDrag) -> CGFloat {
        drag.strip.clampedMinX(drag.pointer.y - drag.grab, dragging: drag.from)
    }

    /// Where the dragged row would land. Its own place while it is leaving for a window.
    private func destination(_ drag: RowDrag) -> Int {
        drag.isLeaving ? drag.from
            : drag.strip.destination(dragging: drag.from, minX: draggedMinY(drag))
    }

    /// Put the dragged row at `index` in the list itself, now. The rows make room by
    /// BEING reordered, as the drag goes, not by being drawn somewhere else: a list row
    /// drawn outside its own cell is clipped by it, so rows slid aside with an offset —
    /// the belt's way — simply vanished here. The dragged row is in the list all along,
    /// emptied, and is the gap; put back where it started if the drag comes to nothing.
    private func settle(at index: Int) {
        guard let current = drag?.current, current != index else { return }
        withAnimation(Token.Motion.structuralRespectingPreferences) {
            sessions.move(fromOffsets: [current],
                          toOffset: TabStripReorder.moveOffset(from: current, to: index))
        }
        drag?.current = index
    }

    /// Whether a point, in the window, is still over the sidebar. From the list's frame;
    /// before that has been measured, from the row's own, which spans the column.
    private func isOnList(_ point: CGPoint, row id: UUID) -> Bool {
        if listFrame.width > 0 {
            return listFrame.insetBy(dx: -Self.releaseMargin, dy: -Self.releaseMargin).contains(point)
        }
        guard let row = rowFrames[id] else { return true }
        return point.x > row.minX - 2 * Self.releaseMargin && point.x < row.maxX + 2 * Self.releaseMargin
    }

    /// A row has been picked up: `SidebarRowPress` saw the press travel. False when
    /// there is nothing to drag it among — the rows are not measured, or there is one.
    private func beginDrag(_ index: Int, at point: CGPoint) -> Bool {
        guard drag == nil, sessions.sessions.indices.contains(index), var strip else { return false }
        // Picked up, a project is its own row and nothing more: what is listed under it
        // folds away until it is put down, so the place it leaves, the place it will land
        // in and the pill under the pointer are all one row tall. The strip is the rows as
        // they stand with that done, taken once — rows slide while the drag runs, and a
        // strip measured from where they have slid to chases itself.
        var heights = strip.widths
        heights[index] = min(heights[index], rowHeight)
        strip = TabStripReorder(widths: heights, spacing: strip.spacing, leading: strip.leading)
        let top = strip.minX(of: index)
        drag = RowDrag(id: sessions.sessions[index].workspaceID, from: index, current: index,
                       strip: strip,
                       grab: min(max(point.y - top, 0), rowHeight), pointer: point)
        beginEscapeMonitor()
        return true
    }

    private func pointerMoved(to point: CGPoint) {
        guard let id = drag?.id else { return }
        drag?.pointer = point
        // Only a row that could be a window leaves: a window's one session stays put.
        let leaving = !isOnList(point, row: id) && sessions.canMoveToNewWindow(id)
        if drag?.isLeaving != leaving { drag?.isLeaving = leaving }
        if let drag { settle(at: destination(drag)) }
        // Out of the sidebar it is what a tab off the belt is: the pill with the window
        // glyph, under the pointer, anywhere on screen.
        if leaving, let store = sessions.sessions.first(where: { $0.workspaceID == id }) {
            let look = SessionLook.appearance(for: store)
            SessionDragGhost.shared.show(title: store.workspaceTitle,
                                         symbol: SessionSymbols.resolved(look.symbol),
                                         tint: SessionTint(storedValue: look.tint).color,
                                         at: NSEvent.mouseLocation)
        } else {
            SessionDragGhost.shared.hide()
        }
    }

    /// Let go on the list: the row lands, or — back where it started — is selected. Let
    /// go anywhere else: the session opens in a window of its own, there; a window's only
    /// session goes back instead.
    private func pointerReleased() {
        guard let drag else { return }
        if drag.isLeaving {
            finishDrag(commit: false)
            sessions.moveToNewWindow(drag.id, at: NSEvent.mouseLocation)
            return
        }
        finishDrag(commit: isOnList(drag.pointer, row: drag.id))
    }

    /// Put down where it has got to, or — the drag called off — back where it started.
    /// One let go where it started is SELECTED: the press travelled, but moved nothing.
    private func finishDrag(commit: Bool) {
        endEscapeMonitor()
        SessionDragGhost.shared.hide()
        guard let drag else { return }
        let to = commit ? destination(drag) : drag.from
        settle(at: to)
        self.drag = nil
        if commit, to == drag.from { sessions.select(drag.id) }
    }

    /// Escape puts the row back. A local monitor, because the keyboard is in a terminal.
    private func beginEscapeMonitor() {
        endEscapeMonitor()
        escapeMonitor = EventMonitor { [self] in
            dragCancelled = true
            finishDrag(commit: false)
        }
    }

    private func endEscapeMonitor() {
        escapeMonitor?.stop()
        escapeMonitor = nil
    }

    /// What is drawn over the list while a row is dragged: the empty place it would land
    /// in, and the project as a pill under the pointer — its icon and name, nothing
    /// else — until it leaves the sidebar, where `SessionDragGhost` takes over. Over the
    /// LIST rather than in the row, so no row below the dragged one is drawn on top of
    /// it, and placed from the list's frame as it is at this moment, not a remembered one.
    @ViewBuilder private var dragOverlay: some View {
        if let drag, let store = sessions.sessions.first(where: { $0.workspaceID == drag.id }) {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                // A row's capsule is its cell less a point above and below, and the cell
                // is the row and the list's gap round it.
                let gap = drag.strip.spacing
                let height = max(0, drag.strip.widths[drag.from] + gap - 2)
                let home = drag.strip.minX(of: drag.from) - gap / 2 + 1
                let to = drag.current
                let width = max(0, proxy.size.width - Self.capsuleInset * 2)
                ZStack(alignment: .topLeading) {
                    Capsule(style: .continuous)
                        .fill(Token.Colour.label.opacity(0.1))
                        .frame(width: width, height: height)
                        .offset(x: Self.capsuleInset,
                                y: home + drag.strip.slotOffset(dragging: drag.from, to: to) - origin.y)
                        .animation(Token.Motion.structuralRespectingPreferences, value: to)
                    if !drag.isLeaving {
                        SessionRowGhost(store: store)
                            .padding(.leading, max(0, (rowFrames[drag.id]?.minX ?? origin.x)
                                                      - origin.x - Self.capsuleInset))
                            .frame(width: width, height: height, alignment: .leading)
                            .background(.regularMaterial, in: .capsule)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                            .offset(x: Self.capsuleInset, y: draggedMinY(drag) - gap / 2 + 1 - origin.y)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The terminals a project has to list under its row, or nil: it has no agent — or
    /// it has gone inactive, and a project nobody is working in is its own row and no
    /// more. The next turn makes it active, and they are listed again.
    private func sessionsToList(for store: LayoutStore) -> [AgentMonitor.SessionTerminal]? {
        if case .inactive = AgentMonitor.shared.stateBySession[store.workspaceID] { return nil }
        return AgentMonitor.shared.terminalsBySession[store.workspaceID]
    }

    /// A row's right-click menu. Every item is a view of a menu command — a context menu
    /// is never the only way to reach something.
    private func menuItems(_ index: Int) -> [SidebarMenuItem] {
        guard sessions.sessions.indices.contains(index) else { return [] }
        let store = sessions.sessions[index]
        let id = store.workspaceID
        // Customize is live on a scratch session as well — it is how one is renamed. It
        // selects too, so the session being customised is the one behind the sheet.
        var items = [SidebarMenuItem("Customize") {
            sessions.select(id)
            ui.customizingSessionID = id
        }]
        // Whether this project's agents and shells are listed under its row. File ▸
        // Session has the same item, and the palette. Only on a project with some to
        // list: an item that shows or hides nothing is not an item.
        if sessionsToList(for: store) != nil {
            items.append(SidebarMenuItem(SessionTerminalVisibility.shared.title(for: store)) {
                // Not animated — see the chevron's click, below.
                SessionTerminalVisibility.shared.toggle(for: store)
            })
        }
        // What dragging the row out of the sidebar does.
        if sessions.canMoveToNewWindow(id) {
            items.append(SidebarMenuItem("Move to New Window") { sessions.moveToNewWindow(id) })
        }
        if sessions.canCloseSelected {
            items.append(.separator)
            items.append(SidebarMenuItem("Close Session") { ui.closingSessionID = id })
        }
        return items
    }

    private var list: some View {
        List(selection: selection) {
            // Above every session: the one view that is about all of them.
            //
            // A gap under it parts it from the projects: the kinds differ, and a list that
            // runs them together reads the overview as the first project. Space rather than
            // a hairline — the line read as one more thing to look at between two rows that
            // space alone parts. Padding on this row rather than an empty row of its own:
            // a list row is never shorter than the list's minimum row height, so an empty
            // one opened a whole row's worth of nothing.
            AgentsRow(isSelected: ui.showsAgents)
                // Filled to a row's minimum BEFORE the gap goes under it. A list never
                // makes a row shorter than `defaultMinListRowHeight` of content, and the
                // session rows, shorter than that, are stretched to it — but the gap
                // counted as this row's content, so this row was never stretched at all,
                // and its capsule, drawn from the cell's edges, came out shorter than a
                // session's by the gap. Measured: 25pt against 30pt.
                .frame(minHeight: rowHeight)
                .padding(.bottom, Self.agentsGap)
                .tag(AgentsOverview.selectionID)
                .listRowBackground(
                    SelectedProjectWash(isSelected: ui.showsAgents)
                        .padding(.bottom, Self.agentsGap))
            ForEach(sessions.sessions, id: \.workspaceID) { store in
                let isDragged = drag?.id == store.workspaceID
                // The row, and under it the project's terminals when an agent is in one
                // of them. One list row for both, so a project is dragged, slid aside and
                // selected as one thing.
                // Whether its terminals are listed under it right now: what folding changes.
                let listsTerminals = !isDragged && SessionTerminalVisibility.shared.isShown(for: store)
                    && sessionsToList(for: store) != nil
                VStack(alignment: .leading, spacing: 0) {
                    SessionRow(store: store,
                               ui: ui,
                               // Not while the overview is up: the row stays the one the
                               // overview was opened from, but nothing on it is selected.
                               isSelected: !ui.showsAgents && sessions.selectedID == store.workspaceID,
                               hasSessions: sessionsToList(for: store) != nil,
                               canClose: sessions.canCloseSelected,
                               select: { sessions.select(store.workspaceID) },
                               rename: { sessions.rename(store.workspaceID, to: $0) },
                               close: { ui.closingSessionID = store.workspaceID },
                               moveToWindow: sessions.canMoveToNewWindow(store.workspaceID)
                                   ? { sessions.moveToNewWindow(store.workspaceID) } : nil)
                        .frame(minHeight: rowHeight)
                        // Folding moves nothing in the project's own row, so nothing in it
                        // is animated by a fold. The table gives the cell its new height
                        // at once while the stack's height is still on its way there, and
                        // a stack shorter or taller than its cell is centred in it: the
                        // name rode down to the middle of the opening cell and back up,
                        // with the icon — never animated — left at the top without it.
                        .transaction(value: listsTerminals) { $0.animation = nil }
                    // Not while the project is being dragged: picked up, it is one row.
                    if listsTerminals, let terminals = sessionsToList(for: store) {
                        SessionTerminalRows(terminals: terminals) {
                            sessions.reveal($0, in: store.workspaceID)
                        }
                    }
                }
                    // Held at the top of the cell. A cell changing height centres what is
                    // in it on the way, and the project's name slid down into the pill
                    // and back each time its sessions were hidden or shown.
                    .frame(maxHeight: .infinity, alignment: .top)
                    // The whole of the row's height, so it can be picked up anywhere on it.
                    .contentShape(.rect)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        rowFrames[store.workspaceID] = $0
                    }
                    // The dragged row's place is empty: it is drawn over the list, under
                    // the pointer (`dragOverlay`), and its emptied row is the gap.
                    .opacity(isDragged ? 0 : 1)
                    // Picked up and put down through `SidebarRowPress`, under the list.
                    // The keyboard paths are View ▸ Move Session Up / Down (⇧⌥⌘[ and
                    // ⇧⌥⌘]) and File ▸ Session ▸ Move Session to New Window.
                    .tag(store.workspaceID)
                    // The selection, drawn here as a capsule — see `.tint(.clear)` below.
                    // It goes with the row being dragged.
                    .listRowBackground(
                        SelectedProjectWash(isSelected: !ui.showsAgents && !isDragged
                                             && sessions.selectedID == store.workspaceID)
                            // The row a right-click's menu is about, ringed at the
                            // pill's own corners.
                            .overlay {
                                if menuRowID == store.workspaceID { SelectedProjectWash.menuRing }
                            })
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
        .background {
            SidebarRowPress(origin: listFrame.origin, rowHeight: rowHeight,
                            count: sessions.sessions.count,
                            clicked: { index, point in
                                guard sessions.sessions.indices.contains(index) else { return }
                                let store = sessions.sessions[index]
                                // On the icon of a project with sessions to list, the
                                // click is the chevron's: it folds them away or back.
                                if let row = rowFrames[store.workspaceID],
                                   point.x >= row.minX - 2, point.x <= row.minX + SessionRow.iconWidth + 2,
                                   sessionsToList(for: store) != nil {
                                    // NOT animated. The table grows the cell on its own
                                    // curve while SwiftUI grows what is in it on another,
                                    // and the list centres the one in the other: for as
                                    // long as the two disagreed the project's name rode
                                    // down the opening cell and back. The cell opens at
                                    // once, the name stays where it is, and the sessions
                                    // fade in inside it (`SessionTerminalRows`).
                                    SessionTerminalVisibility.shared.toggle(for: store)
                                } else {
                                    sessions.select(store.workspaceID)
                                }
                            },
                            menu: menuItems,
                            menuShown: { index in
                                menuRowID = index.flatMap {
                                    sessions.sessions.indices.contains($0) ? sessions.sessions[$0].workspaceID : nil
                                }
                            },
                            began: beginDrag, moved: pointerMoved, released: pointerReleased)
        }
        .overlay(alignment: .topLeading) { dragOverlay }
        .onDisappear {
            endEscapeMonitor()
            SessionDragGhost.shared.hide()
        }
        // A sidebar list draws its selection in the TINT colour, as a rounded rectangle
        // whose radius there is no way to set. Clear, so the list's own goes unseen, and the
        // row's background above draws it instead: fully rounded, in the neutral wash —
        // see `Token.Colour.selectionWash` for why a coloured one fights the row's own icon.
        .tint(.clear)
        // Every row, the sessions' included: see `rowHeight`.
        .environment(\.defaultMinListRowHeight, rowHeight)
        // The footer floats OVER the list, and the list's content — not the list itself —
        // is inset to clear it. `safeAreaInset` was the obvious spelling and it is the wrong
        // one, for the reason written out on `View.tileFooter`: it shrinks the container, so
        // rows stop dead at the footer's top edge, nothing ever passes underneath, and the
        // ramp has nothing to fade against. Which made the footer read as a bar bolted on —
        // which is what the divider was there to justify.
        .contentMargins(.bottom, Token.Space.tileHeaderHeight, for: .scrollContent)
        // The list draws nothing of its own behind the rows: the surface is the ZStack's.
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Sessions")
    }
}

/// Whether a project's active sessions — its agents and shells — are listed under its
/// row in the sidebar. Shown unless hidden, per project: the folder is remembered, so a
/// project hidden once stays hidden in every window and at the next launch. A session on
/// no folder is remembered for as long as it runs.
@MainActor
@Observable
final class SessionTerminalVisibility {
    static let shared = SessionTerminalVisibility()

    private static let key = "sidebar.hidesActiveSessions"
    private var hidden: Set<String>

    private init() {
        hidden = Set(Preferences.store.stringArray(forKey: Self.key) ?? [])
    }

    private func name(of store: LayoutStore) -> String {
        store.workspaceDirectory.map(WorkspaceDocument.canonical) ?? store.workspaceID.uuidString
    }

    func isShown(for store: LayoutStore) -> Bool { !hidden.contains(name(of: store)) }

    /// The menu item's title: what choosing it will do.
    func title(for store: LayoutStore) -> String {
        isShown(for: store) ? "Hide Active Sessions" : "Show Active Sessions"
    }

    func toggle(for store: LayoutStore) {
        let name = name(of: store)
        if hidden.remove(name) == nil { hidden.insert(name) }
        // Folders only: a scratch session's id means nothing to the next launch.
        Preferences.store.set(hidden.filter { $0.hasPrefix("/") }.sorted(), forKey: Self.key)
    }
}

/// A project's terminal panes, listed under its row: each agent by its mark and name with
/// its own state beside it, each plain shell by a terminal and its title. Shown only for
/// a project with an agent in it (`AgentMonitor.terminalsBySession`).
///
/// A click goes to the pane. From the keys: the project by ⌥⌘] and ⌥⌘[, the pane by
/// ⌘1…⌘9 — these rows are a view of panes the canvas already reaches.
private struct SessionTerminalRows: View {
    let terminals: [AgentMonitor.SessionTerminal]
    let open: (PaneID) -> Void
    /// False for the first frame: the rows fade in where they stand, in a cell that has
    /// already opened for them. Nothing else about unfolding a project moves.
    @State private var isShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(terminals) { terminal in
                SessionTerminalRow(terminal: terminal) { open(terminal.id) }
            }
        }
        .padding(.bottom, 4)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(Token.Environment_.reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isShown = true
            }
        }
    }
}

private struct SessionTerminalRow: View {
    let terminal: AgentMonitor.SessionTerminal
    let open: () -> Void
    @State private var isHovering = false

    private var state: AgentState? {
        terminal.agent == nil ? nil : AgentMonitor.shared.stateByPane[terminal.id]
    }

    /// The agent's name, the title it carries and its state: the name first, since the
    /// row itself shows only the agent's mark.
    private func described(by separator: String) -> String {
        var parts: [String] = []
        if let name = terminal.agentName, name != terminal.title { parts.append(name) }
        parts.append(terminal.title)
        if let state { parts.append(state.title) }
        return parts.joined(separator: separator)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                // Under the project's icon, in the same 20-wide slot.
                AgentGlyph(agent: terminal.agent, size: 13)
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .frame(width: 20)
                Text(terminal.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovering ? Token.Colour.label : Token.Colour.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // The slot the project's row keeps for its badge, so the column lines up.
                ZStack {
                    if let state { AgentStateSymbol(state: state) }
                }
                .frame(width: 16, height: 16)
            }
            .frame(height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(described(by: " — "))
        .accessibilityLabel(described(by: ", "))
    }
}

/// Whether the pointer is inside the view this is the background of — asked of the
/// window each time, not remembered from the last enter or exit. A SwiftUI hover in a
/// list cell ends for a frame whenever the cell is resized under a still pointer; here
/// an exit, or a rebuilt tracking area, only counts if the pointer has really left.
private struct PointerInside: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.changed = changed }

    private final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var isInside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
            // Not from inside a layout pass: this may be SwiftUI's own update.
            Task { @MainActor [weak self] in self?.settle() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { settle() }
        }

        override func mouseEntered(with event: NSEvent) { settle() }
        override func mouseExited(with event: NSEvent) { settle() }

        private func settle() {
            let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) }
                ?? false
            guard inside != isInside else { return }
            isInside = inside
            changed?(inside)
        }
    }
}

/// A press on a session's row in the sidebar, taken before the list gets it.
///
/// The list is an `NSTableView`, and a table's mouse-down keeps every event until the
/// button comes up — a SwiftUI drag gesture on a row is never told the pointer moved. So
/// this watches the app's events from a view under the list: a press on a session's own
/// row (not the terminals listed under it, and not its close button, which keep their
/// clicks) is held back from the table, and what follows is reported — a click if the
/// pointer went nowhere, otherwise a pick-up, each move and the release.
///
/// Points are reported in SwiftUI's global space, the one the sidebar measures its rows
/// in: this view lies exactly under the list, whose global origin it is handed.
struct SidebarRowPress: NSViewRepresentable {
    /// The list's origin in SwiftUI's global space.
    let origin: CGPoint
    /// How much of a row's top is the project's own row.
    let rowHeight: CGFloat
    /// How many sessions the list has; the table's first row is Agents.
    let count: Int
    /// A click on a row, and where: the row's leading icon answers one for itself.
    let clicked: (Int, CGPoint) -> Void
    /// A row's right-click menu, and the row it is up for — nil once it has closed. The
    /// menu is put up from here, not by the list: a table rings the row it is about in
    /// its own shape, which is not the row's.
    let menu: (Int) -> [SidebarMenuItem]
    let menuShown: (Int?) -> Void
    let began: (Int, CGPoint) -> Bool
    let moved: (CGPoint) -> Void
    let released: () -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.press = self
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.press = self }

    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? Probe)?.stop() }

    private final class Probe: NSView {
        var press: SidebarRowPress?
        private var monitor: Any?
        /// The row pressed and where, on screen, until the button comes up.
        private var held: (index: Int, start: CGPoint)?
        private var isDragging = false
        /// How far the pointer travels before a press is a drag.
        private static let travel: CGFloat = 4
        /// The trailing end of a row, where its close button is.
        private static let trailingControls: CGFloat = 40

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                    // A flag back, not the event: an event is not something to carry
                    // across an isolation boundary, even one that is not really crossed.
                    let swallowed = MainActor.assumeIsolated { self?.handle(event) == nil && self != nil }
                    return swallowed ? nil : event
                }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            held = nil
            isDragging = false
        }

        /// The table the list is: the nearest one in a view this probe is inside of.
        private var table: NSTableView? {
            var view = superview
            while let current = view {
                if let table = Self.table(in: current) { return table }
                view = current.superview
            }
            return nil
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = table(in: subview) { return table }
            }
            return nil
        }

        /// An event's pointer in SwiftUI's global space.
        private func global(_ event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            let origin = press?.origin ?? .zero
            return CGPoint(x: origin.x + local.x, y: origin.y + local.y)
        }

        private func screen(_ event: NSEvent) -> CGPoint {
            event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        }

        /// Put up the menu of the project's row under a right-click. False if the press
        /// was not on one, and the event goes on to whatever it was for.
        private func showMenu(for event: NSEvent) -> Bool {
            guard let press, event.window === window, let table else { return false }
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.visibleRect.contains(point) else { return false }
            let row = table.row(at: point)
            guard row >= 1, row - 1 < press.count else { return false }
            let cell = table.rect(ofRow: row)
            let depth = table.isFlipped ? point.y - cell.minY : cell.maxY - point.y
            guard depth <= press.rowHeight + 4 else { return false }
            let items = press.menu(row - 1)
            guard !items.isEmpty else { return false }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let targets = items.map { MenuTarget($0.action) }
            for (item, target) in zip(items, targets) {
                guard item.action != nil else { menu.addItem(.separator()); continue }
                let entry = NSMenuItem(title: item.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                entry.target = target
                menu.addItem(entry)
            }
            press.menuShown(row - 1)
            // Returns when the menu has closed, its item's action already sent.
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
            self.press?.menuShown(nil)
            return true
        }

        /// Nil swallows the event: it was this probe's.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let press else { return event }
            switch event.type {
            case .rightMouseDown:
                return showMenu(for: event) ? nil : event
            case .leftMouseDown:
                held = nil
                isDragging = false
                // A control-click is a right-click.
                if event.modifierFlags.contains(.control) { return showMenu(for: event) ? nil : event }
                guard event.window === window, event.clickCount == 1, let table else { return event }
                let point = table.convert(event.locationInWindow, from: nil)
                guard table.visibleRect.contains(point) else { return event }
                let row = table.row(at: point)
                // Row 0 is the Agents overview: not a session, and the list's own.
                guard row >= 1, row - 1 < press.count else { return event }
                let cell = table.rect(ofRow: row)
                // The project's own row only. The terminals under it are buttons, and so
                // is the close at the row's end: both keep their press.
                let depth = table.isFlipped ? point.y - cell.minY : cell.maxY - point.y
                guard depth <= press.rowHeight + 4, point.x < cell.maxX - Self.trailingControls else {
                    return event
                }
                held = (row - 1, screen(event))
                return nil
            case .leftMouseDragged:
                guard let held else { return event }
                if !isDragging {
                    let now = screen(event)
                    guard hypot(now.x - held.start.x, now.y - held.start.y) >= Self.travel else { return nil }
                    // Nothing to drag among: the press stays a click.
                    guard press.began(held.index, global(event)) else { return nil }
                    isDragging = true
                }
                press.moved(global(event))
                return nil
            case .leftMouseUp:
                guard let held else { return event }
                self.held = nil
                if isDragging {
                    isDragging = false
                    press.moved(global(event))
                    press.released()
                } else {
                    press.clicked(held.index, global(event))
                }
                return nil
            default:
                return event
            }
        }
    }
}

/// What a menu item of the sidebar's calls: a closure, behind a selector.
private final class MenuTarget: NSObject {
    private let run: (() -> Void)?
    init(_ run: (() -> Void)?) { self.run = run }
    @MainActor @objc func fire() { run?() }
}

/// A row on its way down the sidebar.
private struct RowDrag: Equatable {
    let id: UUID
    /// Its index when the drag began.
    let from: Int
    /// Its index in the list now: the list is reordered as the drag goes.
    var current: Int
    /// The rows as they stood when it was picked up.
    let strip: TabStripReorder
    /// Where the pointer took hold of it, from its top edge.
    let grab: CGFloat
    /// The pointer, in the window.
    var pointer: CGPoint
    /// Whether the pointer has carried the row out of the sidebar, where letting go
    /// makes a window of it.
    var isLeaving = false
}

/// A session row's icon and name, as the row draws them: what is under the pointer while
/// the row is dragged down the list.
private struct SessionRowGhost: View {
    let store: LayoutStore

    var body: some View {
        let look = SessionLook.appearance(for: store)
        HStack(spacing: 6) {
            Image(systemName: SessionSymbols.resolved(look.symbol))
                .font(Token.Type_.tileTitle)
                .foregroundStyle(SessionTint(storedValue: look.tint).color)
                .frame(width: 20)
            Text(store.workspaceTitle)
                .font(Token.Type_.tileTitle)
                .foregroundStyle(Token.Colour.label)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
    }
}

/// A selected row's capsule — a project's, or the Agents row's: Liquid Glass, the same
/// the belt's selected tab wears, so every place that says "this one" says it the same
/// way. The sidebar has no surface of its own now, so the capsule is glass on the
/// window, not glass on glass. Under Reduce Transparency, the neutral wash
/// (`Token.Colour.selectionWash`).
private struct SelectedProjectWash: View {
    let isSelected: Bool

    /// Half a row's height: a capsule on a row of one line, and the same corners on a
    /// project that lists its terminals under it — where a capsule's would be a lozenge.
    static let radius: CGFloat = 15

    var body: some View {
        Group {
            if Token.Environment_.reduceTransparency {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Token.Colour.selectionWash)
            } else {
                Color.clear.glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.radius))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .opacity(isSelected ? 1 : 0)
    }

    /// The ring round a row while its right-click menu is up: the system's colour for
    /// it, on the pill's shape. The table's own ring has the table's corners.
    static var menuRing: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
    }
}

/// One item of a sidebar row's right-click menu, or the line between two groups.
struct SidebarMenuItem {
    let title: String
    let action: (() -> Void)?

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    private init() {
        title = ""
        action = nil
    }

    static var separator: SidebarMenuItem { SidebarMenuItem() }
}

/// Takes off the sidebar column what AppKit draws for it, leaving the list.
///
/// Two things, neither of which SwiftUI has a say over, so each is found from a probe
/// inside the column:
///
/// - The list's own selection. A sidebar `List` draws it as a rounded rectangle there is no
///   way to reshape, and `.tint(.clear)` hides it only while the list has the keyboard —
///   the rest of the time it draws in grey, behind the capsule. The list is an
///   `NSTableView`, and a table can be told to draw no selection at all; selection itself,
///   the arrow keys and the binding are untouched.
/// - The divider and the shadow the split view lays down the column's trailing edge: a
///   line between two halves of what is one window. Transparent, not hidden — the divider
///   is still dragged to resize the column.
///
/// Re-applied on every update and on being moved into a window, since collapsing and
/// reopening the column can build any of them again.
private struct SidebarColumnChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Next turn: the list is built after this probe is in the window.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply() {
            // Up to the column — the view the split view holds — then down to the table.
            var column: NSView? = self
            while let view = column, !(view.superview is NSSplitView) { column = view.superview }
            guard let column else { return }
            Self.unhighlight(in: column)
            for sibling in column.superview?.subviews ?? [] {
                let name = String(describing: type(of: sibling))
                guard name == "NSSplitDividerView" || name == "_NSSplitViewShadowView" else { continue }
                if sibling.alphaValue != 0 { sibling.alphaValue = 0 }
            }
        }

        private static func unhighlight(in view: NSView) {
            if let table = view as? NSTableView {
                if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                return
            }
            for subview in view.subviews { unhighlight(in: subview) }
        }
    }
}

/// The bar under the list: the two ways a project gets into this window.
///
/// TWO controls, and only two. `+` makes a project that does not exist yet — an empty
/// folder, or a clone — and the folder opens one that does. They were one button for a
/// while, and the one button could only do the second thing: a `+` that opens a file picker
/// is not "new", it is "open" wearing the wrong icon, and there was nowhere at all to start
/// a project from scratch.
///
/// A bottom bar is the easiest place in an app to accumulate buttons nobody presses.
/// Everything else a session can do is on the row itself.
private struct SessionSidebarBar: View {
    @Bindable var sessions: SessionList
    @Bindable var ui: UIState
    let openFolder: () -> Void

    var body: some View {
        // One in each corner. Side by side they read as a pair of related verbs — "add" and
        // "add, but differently" — and the eye has to stop at both to work out which is
        // which. Pushed apart, each is the only thing at its end of the bar: new on the
        // leading edge where a source list puts "add", open on the trailing edge.
        HStack(spacing: 0) {
            NewProjectButton(ui: ui)
            Spacer(minLength: 0)
            OpenProjectButton(sessions: sessions, openFolder: openFolder)
        }
        .padding(.horizontal, 6)
        // The same height as a tile's footer and a pane's header, so every horizontal strip
        // in the window sits on one rhythm.
        .frame(height: Token.Space.tileHeaderHeight)
        // The SAME ramp a tile footer wears (`TileFooter`): solid at the bottom edge, gone
        // by the top, with rows passing under it and fading out.
        //
        // It replaces a `Divider`. A hard line plus a flat fill is a bar bolted to the
        // bottom of the sidebar — a second surface inside the first — and the line was only
        // needed because the fill ended abruptly. A ramp has no edge to justify.
        .background { EdgeBlur(edge: .bottom) }
    }
}

/// What a session's row and tab wear, found by the session.
///
/// A project's look is filed under its folder (`SessionAppearanceStore`), so it is the same
/// in every window and every launch. A scratch session — `SessionList.openShell` — has no
/// folder, and used to have no look either: Customize was dimmed on it, since a choice
/// with nowhere to be saved would be forgotten the moment the sheet closed. Now the choice
/// is kept HERE, by workspace id, for as long as the session runs. That is as long as the
/// session itself lasts, so nothing is lost that the session would not have lost anyway,
/// and Customize can stay live for the thing a scratch session most needs it for: a name.
@MainActor
enum SessionLook {
    private static var transient: [UUID: SessionAppearance] = [:]

    static func appearance(for store: LayoutStore) -> SessionAppearance {
        if let directory = store.workspaceDirectory {
            return SessionAppearanceStore.appearance(forDirectory: directory)
        }
        return transient[store.workspaceID] ?? .default
    }

    static func set(_ appearance: SessionAppearance, for store: LayoutStore) {
        if let directory = store.workspaceDirectory {
            SessionAppearanceStore.set(appearance, forDirectory: directory)
        } else {
            transient[store.workspaceID] = appearance.isDefault ? nil : appearance
        }
    }
}

/// The two ways a project gets into this window, as the controls the sidebar's bar and the
/// session tab belt both carry: `+` for a project that does not exist yet, the folder for
/// one that does. One definition, so the two places cannot drift apart.
///
/// NEW is a plain button, not a menu: the choice between an empty folder and a clone
/// belongs in the sheet, where both are visible at once and the fields under them explain
/// what each one needs.
struct NewProjectButton: View {
    @Bindable var ui: UIState
    var size: ProjectControlSize = .bar

    var body: some View {
        Button { ui.isCreatingProject = true } label: {
            ProjectBarLabel(symbol: "plus.capsule.fill", size: size)
        }
        .buttonStyle(.plain)
        .help("New project — an empty folder or a clone (⇧⌘N)")
        .accessibilityLabel("New project")
    }
}

/// OPEN. Clicking opens a folder; holding drops the recents. The plain menu made the common
/// case — "a project I have not opened before" — two clicks and a read.
struct OpenProjectButton: View {
    @Bindable var sessions: SessionList
    var size: ProjectControlSize = .bar
    let openFolder: () -> Void

    var body: some View {
        Menu {
            ForEach(RecentProjects.list, id: \.self) { path in
                Button(ShellPaneFactory.abbreviate(path)) { sessions.open(directory: path) }
            }
            if !RecentProjects.list.isEmpty { Divider() }
            Button("Open Folder…") { openFolder() }
        } label: {
            ProjectBarLabel(symbol: "folder.fill", size: size)
        } primaryAction: {
            openFolder()
            // Whether or not a folder was chosen: the button took first responder the
            // moment it was pressed, and a cancelled panel leaves it there.
            sessions.selected?.reclaimKeyboardFocus()
        }
        // A button menu in the plain button style, so the label is drawn as it is written.
        // `.borderlessButton` hands it to an AppKit control that draws the glyph at the
        // system's size in a box of its own — whatever font and frame the label asks for —
        // which left the folder a size under the `+` beside it, and deaf to `size`.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Belt and braces with the `foregroundStyle` in the label: the tint is what a menu
        // style reaches for first when it draws a label.
        .tint(Token.Colour.secondaryLabel)
        .help("Open an existing project in this window (⌘T)")
        .accessibilityLabel("Open project")
    }
}

/// The label is the whole hit target, padded rather than framed, so the press area matches
/// what a bottom-bar button looks like instead of being a 12pt glyph you have to aim at.
/// Shared by both controls so the two cannot end up different sizes.
///
/// The size and the box come from `ChromeIconLabel` — the control a pane header and a tile
/// footer wear — rather than from numbers of their own. They WERE their own numbers (14pt in
/// a 26×22 box) and the sidebar's bar came out a size smaller than every other strip in the
/// window, which is the one thing a bar at the foot of a column must not be: the icons
/// across the bottom of the window are all the same control.
///
/// That is the sidebar's bar. The session tab belt asks for `.belt` — see
/// `ProjectControlSize`.
struct ProjectBarLabel: View {
    let symbol: String
    var size: ProjectControlSize = .bar

    var body: some View {
        Image(systemName: symbol)
            // Bold rather than semibold — the one thing here that is NOT the header's. These
            // sit on a blurred ramp with rows fading underneath them, which eats a weight:
            // semibold read as thin here in a way it does not on a pane's solid surface.
            .font(.system(size: size.glyph, weight: .bold))
            // Stated, not inherited. One of these is a `Button` and the other is a `Menu`,
            // and a borderless menu draws its label in the CONTROL tint while a plain button
            // takes the foreground it is given — so the pair rendered in two different
            // colours despite sharing this label.
            .foregroundStyle(Token.Colour.secondaryLabel)
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
    }
}

/// How large the two project controls are drawn, which depends on the strip they are in.
@MainActor
enum ProjectControlSize {
    /// The sidebar's bar: a pane header's control, for the reason on `ProjectBarLabel`.
    case bar
    /// The session tab belt. Its tabs are a size up from a pane header's controls, and a
    /// header-sized pair at the end of them read as an afterthought — two small glyphs,
    /// touching, beside a row of things each twice their height.
    case belt

    /// The belt's is 17: two points over a header's, and two under the 19 it was, which
    /// had the pair outweighing the tabs' own icons. The box is unchanged, so the press
    /// area is as easy to hit as it was.
    var glyph: CGFloat {
        switch self {
        case .bar: ChromeIconLabel.size
        case .belt: 17
        }
    }

    var width: CGFloat {
        switch self {
        case .bar: ChromeIconLabel.width
        case .belt: 34
        }
    }

    /// The belt's is a tab's height, so the pair sits on the tabs' line.
    var height: CGFloat {
        switch self {
        case .bar: ChromeIconLabel.height
        case .belt: 36
        }
    }
}

/// The row above the sessions: the Agents overview, with how many agents are running.
/// A number and nothing else — the states are each session's row's to show, and a glyph
/// here said one more time what the rows under it already say. Never hidden: a row that
/// comes and goes is a view nobody learns the key for. Dimmed with nothing running.
private struct AgentsRow: View {
    let isSelected: Bool

    private var running: Int { AgentsOverview.shared.runningCount }

    var body: some View {
        HStack(spacing: 6) {
            // Grey, in every state: the session rows' icons are their tints, and the one
            // row that is not a session wears no tint — it is the view of them all.
            Image(systemName: "circle.grid.2x2.fill")
                .font(Token.Type_.tileTitle)
                .foregroundStyle(running > 0 ? Token.Colour.secondaryLabel : Token.Colour.tertiaryLabel)
                .frame(width: 20)
            Text("Agents")
                .font(Token.Type_.tileTitle)
                .foregroundStyle(running > 0 ? Token.Colour.label : Token.Colour.tertiaryLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
            // In the slot the session rows keep for their badge, so the column lines up.
            ZStack {
                if running > 0 {
                    AgentCount(running)
                        .font(Token.Type_.tileTitle)
                        .foregroundStyle(Token.Colour.secondaryLabel)
                }
            }
            .frame(minWidth: 16, minHeight: 16, maxHeight: 16, alignment: .trailing)
        }
        .contentShape(.rect)
        .help("Every working agent's pane, from every project (⌘0)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running > 0 ? "Agents, \(running) running" : "Agents, none running")
    }
}

/// How many agents are running, as the sidebar's row and the belt's tab show it: the
/// number in a filled circle, the badge shape the session rows' own states wear. SF
/// Symbols numbers its circles up to 50; past that, the bare number.
struct AgentCount: View {
    let count: Int

    init(_ count: Int) { self.count = count }

    var body: some View {
        if (0...50).contains(count) {
            Image(systemName: "\(count).circle.fill")
        } else {
            Text("\(count)")
                .monospacedDigit()
                .fixedSize()
        }
    }
}

private struct SessionRow: View {
    let store: LayoutStore
    @Bindable var ui: UIState
    let isSelected: Bool
    /// Whether the project has agents and shells to list under this row.
    let hasSessions: Bool
    /// Whether they are listed: there are some, and the project is not hiding them.
    private var listsSessions: Bool {
        hasSessions && SessionTerminalVisibility.shared.isShown(for: store)
    }
    /// The leading slot's width: the icon's, and the chevron's that takes its place.
    static let iconWidth: CGFloat = 20
    @State private var isOverIcon = false
    let canClose: Bool
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    /// Into a window of its own, or nil on a window's only session.
    var moveToWindow: (() -> Void)? = nil
    @State private var isHovering = false
    /// Read straight off the monitor, which is `@Observable`, so a row redraws when its own
    /// session's state changes and not when another's does. There is no per-row timer here
    /// and there must never be: one poll for the whole app is the rule `AgentMonitor` was
    /// written to hold. The age beside it reads the monitor's `minute`, which moves once a
    /// minute.
    private var state: AgentState? {
        AgentMonitor.shared.stateBySession[store.workspaceID]
    }
    private var isInactive: Bool {
        if case .inactive = state { return true }
        return false
    }
    /// The state as the row's badge and age show it: nothing while the project works and
    /// its sessions are listed underneath, each turning an arc of its own — a second one
    /// on the project is the same news twice. Needs-you and done still reach the row.
    private var badge: AgentState? {
        if listsSessions, case .working = state { return nil }
        return state
    }
    /// Seeded from disk at the row's first appearance, so a customised session is already
    /// wearing its icon on the frame it is drawn in rather than flashing the default first.
    /// SwiftUI keeps this per row IDENTITY, and a row's identity is its session.
    @State private var appearance: SessionAppearance

    init(store: LayoutStore, ui: UIState, isSelected: Bool, hasSessions: Bool = false, canClose: Bool,
         select: @escaping () -> Void, rename: @escaping (String) -> Void,
         close: @escaping () -> Void, moveToWindow: (() -> Void)? = nil) {
        self.store = store
        self.ui = ui
        self.isSelected = isSelected
        self.hasSessions = hasSessions
        self.canClose = canClose
        self.select = select
        self.rename = rename
        self.close = close
        self.moveToWindow = moveToWindow
        _appearance = State(initialValue: SessionLook.appearance(for: store))
    }

    private var tint: SessionTint { SessionTint(storedValue: appearance.tint) }

    /// The project folder's own name — what an emptied field falls back to, and what Reset
    /// puts back. A scratch session goes back to being called "New shell".
    private var defaultName: String {
        store.workspaceDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? ShellWorkspace.scratchTitle
    }

    /// The window-level flag, answered by the row it NAMES — and only while the sidebar is
    /// the list on screen; the belt's tab answers it otherwise.
    private var isCustomizing: Binding<Bool> {
        Binding(get: { !ui.showsTabBelt && ui.customizingSessionID == store.workspaceID },
                set: { ui.customizingSessionID = $0 ? store.workspaceID : nil })
    }

    /// Renaming goes through the SESSION LIST, not straight onto the store: the list is what
    /// persists the window's sessions, and a title written without it would be on screen but
    /// not on disk.
    private var name: Binding<String> {
        Binding(get: { store.workspaceTitle }, set: { rename($0) })
    }

    var body: some View {
        HStack(spacing: 6) {
            // The icon — and, under the pointer on a project with sessions to list, the
            // chevron that folds them away or back. One box for both, of a fixed size, so
            // neither the swap nor a wide symbol moves the name beside it or the rows
            // below. The click itself is taken by the sidebar, with the row's other
            // presses (`SidebarRowPress.clicked`), so a drag can still start here.
            ZStack {
                if isOverIcon, hasSessions {
                    Image(systemName: listsSessions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Token.Colour.label)
                        .contentTransition(.identity)
                        .transition(.identity)
                } else {
                    Image(systemName: SessionSymbols.resolved(appearance.symbol))
                        .font(Token.Type_.tileTitle)
                        // Grey with the name once the project has gone inactive.
                        .foregroundStyle(isInactive ? AnyShapeStyle(Token.Colour.tertiaryLabel)
                                                    : AnyShapeStyle(tint.color))
                        .transition(.identity)
                }
            }
            .frame(width: Self.iconWidth, height: 16)
            // A swap, not a move: folding is animated around this row, and that animation
            // must not reach the box — the chevron turned and cross-faded through the icon.
            .transaction { $0.animation = nil }
            .contentShape(.rect)
            // Where the pointer IS, not what a hover says: folding resizes the cell, the
            // hover under it ended for a frame, and the icon flashed back mid-click.
            .background { PointerInside { isOverIcon = $0 } }
            .help(hasSessions ? SessionTerminalVisibility.shared.title(for: store)
                              : store.workspaceSubtitle ?? store.workspaceTitle)

            // The name alone. A pane count under it was a number about the layout, not
            // about the session — it changed every time a pane opened, and told a user
            // choosing where to go nothing they were choosing between. The full path is
            // still one hover away.
            Text(store.workspaceTitle)
                // The SAME token the pane header's title uses. A session row and a pane
                // title are both "what this thing is", and the sidebar's default 13pt made
                // the primary navigation read as smaller print than the panes it navigates
                // to. One token, so they cannot drift apart again.
                .font(Token.Type_.tileTitle)
                // One weight for every row. The badge says what is unread — the filled
                // check — and a name that changed weight beside it moved the column.
                // Dimmed once the session has gone quiet for good.
                .foregroundStyle(isInactive
                                 ? AnyShapeStyle(Token.Colour.tertiaryLabel) : AnyShapeStyle(Token.Colour.label))
                .lineLimit(1)

            Spacer(minLength: 0)

            // How long the state has held: "now", "4m", "2d". Fixed width and trailing, so
            // the symbol beside it does not move as the minutes turn.
            if let badge {
                Text(badge.age(at: AgentMonitor.shared.minute))
                    .font(Token.Type_.tileSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .fixedSize()
                    .frame(minWidth: 30, alignment: .trailing)
            }

            // ONE trailing slot, of a fixed width, holding whichever of two things the row
            // currently has to say. Two slots side by side was the obvious layout and it is
            // the wrong one: the close control comes and goes with the pointer, so the badge
            // beside it would jump left and right as the mouse crossed the row — and a
            // status light that moves is read as a change of status.
            //
            // The close control wins the slot when both want it, and that costs nothing:
            // it only appears on the row the pointer is over. At rest every row, the
            // selected one too, shows its badge.
            ZStack {
                if isHovering, canClose {
                    // Under the pointer only, the selected row included: at rest it shows
                    // its badge like any other. File ▸ Session ▸ Close Session is the key path.
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.label)
                    .help("Close session")
                } else if let badge {
                    AgentStateSymbol(state: badge)
                        .help(badge.title)
                }
            }
            // Reserved whether or not anything is in it. Without the frame the name beside
            // it would reflow every time an agent started or a pointer arrived.
            // Height too, so the X and a badge of another height cannot move the row.
            .frame(width: 16, height: 16)
        }
        // The WHOLE row, gaps included. Without it the hit area is the icon and the text
        // and nothing else, so the empty space between the name and the close button — most
        // of a wide sidebar — was dead to a click.
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // No gestures here: the sidebar puts the row's tap and drag on it, together, where
        // the drag's state lives. A tap alone, added here once to catch the click on the
        // row that is ALREADY selected, swallowed the List's own click handling and made
        // rows unselectable by their label — which is why the sidebar's tap selects.
        // The PATH, always — a renamed session must still be able to tell you which checkout
        // it actually is, and after a rename the title no longer can.
        .help(store.workspaceSubtitle ?? store.workspaceTitle)
        // The right-click menu is the sidebar's (`SessionSidebar.menuItems`), put up by
        // `SidebarRowPress`: the list's own rings the row in the table's shape.
        .sessionCustomizer(isPresented: isCustomizing, store: store, name: name,
                           appearance: $appearance,
                           defaultName: defaultName, rename: rename)
        .accessibilityElement(children: .combine)
        // The status is SPOKEN, not only coloured. A row whose whole meaning is a hue is a
        // row that says nothing to a VoiceOver user and half of one to anybody who cannot
        // separate the green from the red — which is why the badge carries a distinct glyph
        // as well, rather than four dots in four colours.
        .accessibilityLabel(state.map { "Session, \(store.workspaceTitle), \($0.title), \($0.spokenAge(at: AgentMonitor.shared.minute))" }
                            ?? "Session, \(store.workspaceTitle)")
    }
}

/// The customise sheet and everything that writes its edits through — the icon to the
/// appearance store, the agents to `.ultra/agents.json` — shared by the sidebar row and the
/// tab belt's tab, so the two ways into it cannot save differently.
///
/// The icon is the CALLER's state, bound in: each view draws the icon it carries, and has
/// to see a change the moment the sheet makes it. The agents are the sheet's own.
struct SessionCustomizerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let store: LayoutStore
    let name: Binding<String>
    @Binding var appearance: SessionAppearance
    let defaultName: String
    let rename: (String) -> Void
    /// The project's agent list, read from `.ultra/agents.json` when the sheet OPENS and
    /// dropped when it closes. It used to be seeded in every row's `init`, which SwiftUI
    /// runs on every redraw of the list — a file read per row per redraw, for a sheet that
    /// is almost never open. Nil means "not loaded", which is also how the write-through
    /// below tells a load apart from an edit.
    @State private var agents: [AgentDefinition]?

    private var agentsBinding: Binding<[AgentDefinition]> {
        // Straight from disk for the one frame the sheet can be drawn before the load below
        // lands, so it never opens on an empty list that then fills in.
        Binding(get: { agents ?? Self.loadAgents(forDirectory: store.workspaceDirectory) },
                set: { agents = $0 })
    }

    /// The defaults for a workspace with no directory: there is no file to read, and no
    /// file to write, which is why the sheet hides its agent section on such a session.
    static func loadAgents(forDirectory directory: String?) -> [AgentDefinition] {
        guard let directory else { return AgentDefinition.defaults }
        return ProjectAgents.load(in: URL(fileURLWithPath: directory, isDirectory: true))
    }

    func body(content: Content) -> some View {
        content
        // A SHEET, not a popover off the row: it holds a list of agents being edited, and a
        // popover closes the moment the pointer strays. See `SessionCustomizer`.
        .sheet(isPresented: $isPresented) {
            SessionCustomizer(name: name, appearance: $appearance, agents: agentsBinding,
                              defaultName: defaultName,
                              // A scratch session has no `.ultra/agents.json` to edit:
                              // the section would take changes and keep none of them.
                              showsAgents: store.workspaceDirectory != nil) {
                appearance = .default
                agents = AgentDefinition.defaults
                rename(defaultName)
            }
            // A sheet is its own window. Dismissing it hands key status back to this one,
            // and AppKit restores whatever first responder it had — which, since the sheet
            // was opened from the sidebar or the belt, is that list.
            .onDisappear { store.reclaimKeyboardFocus() }
        }
        .onChange(of: isPresented, initial: true) { _, shown in
            agents = shown ? Self.loadAgents(forDirectory: store.workspaceDirectory) : nil
        }
        // One place the icon is written, whichever control changed it — the swatches, the
        // symbols and Reset all just move the binding.
        .onChange(of: appearance) { _, new in
            SessionLook.set(new, for: store)
        }
        // Written through on every edit, like the icon. The file is the project's, so a
        // list that matches what is already on disk — a row untouched, a Reset on a project
        // that never had a file — is not written: opening Customize must not dirty a
        // checkout. And a fresh command is the moment to re-probe what is installed.
        .onChange(of: agents) { old, new in
            // A load or an unload, not an edit.
            guard old != nil, let new else { return }
            guard let directory = store.workspaceDirectory else { return }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            if new != ProjectAgents.load(in: root) {
                try? ProjectAgents.save(new, in: root)
            }
            ShellWorkspace.forgetAvailability()
        }
        // The seed in `init` reads whatever the store knows AT THAT MOMENT, and a session
        // being restored can learn its project a beat later. Without this, such a row would
        // hold the default icon for the rest of the launch — the customisation would look
        // like it had not been saved at all.
        .onChange(of: store.workspaceDirectory) { _, directory in
            appearance = SessionLook.appearance(for: store)
            if agents != nil { agents = Self.loadAgents(forDirectory: directory) }
        }
    }
}

extension View {
    func sessionCustomizer(isPresented: Binding<Bool>, store: LayoutStore, name: Binding<String>,
                           appearance: Binding<SessionAppearance>,
                           defaultName: String, rename: @escaping (String) -> Void) -> some View {
        modifier(SessionCustomizerSheet(isPresented: isPresented, store: store, name: name,
                                        appearance: appearance,
                                        defaultName: defaultName, rename: rename))
    }
}

/// How a session's agent work looks in the sidebar: a turning arc while it works, an
/// orange ringed dot when it asks, a filled check for a finish nobody has looked at, a
/// small grey check once someone has, and a moon when the session has been quiet a while.
///
/// The mapping lives HERE rather than on `AgentState` itself: the state is a fact the
/// terminal layer derives from a tty, and a type in `UltraTerminal` that knows about SF
/// Symbols and sidebar colours is a layer boundary that has stopped meaning anything.
///
/// Each state has its own SHAPE as well as its weight, so the column reads without colour:
/// only "needs you" is in colour at all.
struct AgentStateSymbol: View {
    let state: AgentState

    var body: some View {
        Group {
            switch state {
            case .working:
                AgentSpinner()
            case .needsYou:
                Image(systemName: "circle.inset.filled")
                    .foregroundStyle(Token.Colour.agentNeedsYou)
            case .done(_, read: false):
                // The disc in the label colour, the check cut out of it in the background's:
                // white with a dark tick on a dark sidebar, the reverse on a light one.
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(nsColor: .textBackgroundColor), Token.Colour.label)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Token.Colour.secondaryLabel)
            case .inactive:
                Image(systemName: "moon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)   // the row says the state in words
    }
}

/// An arc going round: the working state. Not a `ProgressView`, whose spinner is the
/// system's "loading" and the wrong weight beside a row's text. Under Reduce Motion it
/// stands still — an arc with a gap still reads as "in progress".
///
/// Turned by the clock, not by an animation. It was a `repeatForever` animation on a flag
/// flipped in `onAppear`, and inside a view that is laid out AFTER it appears — a strip
/// in a hosting view whose frame arrives on the next layout — that animation took the
/// move into place along with the turn: the arc slid from the bottom of the pane to its
/// slot, forever, until another pane's arrival laid the strip out again. A timeline has
/// no transaction to leak into anything.
private struct AgentSpinner: View {
    var body: some View {
        let reduceMotion = Token.Environment_.reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            // Grey, not the label colour: it turns beside a name, and in white it
            // outweighed the name it was about.
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(Token.Colour.secondaryLabel, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(reduceMotion ? 0 : seconds.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 12, height: 12)
    }
}

extension AgentState {
    /// What the state is called, on hover and to VoiceOver.
    var title: String {
        switch self {
        case .working: "Agent is working"
        case .needsYou: "Needs you"
        case .done(_, read: false): "Done, not read yet"
        case .done: "Done"
        case .inactive: "Inactive"
        }
    }

    /// The age in words, for VoiceOver: "4m" is read as "4 metres".
    func spokenAge(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "just now" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds < 3600 ? [.minute] : seconds < 86_400 ? [.hour] : [.day]
        return (formatter.string(from: seconds) ?? "") + " ago"
    }
}

/// The five states, the way a column of sessions shows them.
struct AgentStateGallery: View {
    let now = Date()

    private var rows: [(String, AgentState)] {
        [("ultra-swift", .working(since: now.addingTimeInterval(-70))),
         ("checkout-api", .needsYou(since: now)),
         ("design-system", .done(at: now.addingTimeInterval(-240), read: false)),
         ("docs", .done(at: now.addingTimeInterval(-720), read: true)),
         ("old-prototype", .inactive(since: now.addingTimeInterval(-86_400 * 2)))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.0) { name, state in
                HStack(spacing: 6) {
                    Text(name)
                        .font(Token.Type_.tileTitle)
                        .foregroundStyle({ if case .inactive = state { Token.Colour.tertiaryLabel } else { Token.Colour.label } }())
                    Spacer(minLength: 0)
                    Text(state.age(at: now))
                        .font(Token.Type_.tileSubtitle)
                        .monospacedDigit()
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                        .fixedSize()
                        .frame(minWidth: 30, alignment: .trailing)
                    AgentStateSymbol(state: state)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
        }
        .padding(8)
        .frame(width: 260)
    }
}

#Preview("Agent states", traits: .fixedLayout(width: 280, height: 190)) {
    AgentStateGallery()
}
