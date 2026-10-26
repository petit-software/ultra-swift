import AppKit
import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign
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
        // The WINDOW's surface under the list, not the sidebar's own. On macOS 26 the column
        // is a glass panel holding its content, and that glass read as a second, darker
        // surface beside the canvas. It cannot be taken off — it IS the column — so the
        // window's material is laid inside it instead, the same view `RootView` puts behind
        // the canvas, and a hairline is all that parts the two.
        ZStack {
            if Token.Environment_.reduceTransparency {
                Token.Colour.tileBackground.ignoresSafeArea()
            } else {
                // The LEFT corners only: those are the window's, and the right edge meets
                // the canvas along the hairline.
                WindowSurface(corners: [.layerMinXMinYCorner, .layerMinXMaxYCorner])
                    .ignoresSafeArea()
            }
            list
        }
        // One kind of thing in one group, so a header would be a word explaining a list that
        // explains itself. The editor's sidebar has two sections because it holds two kinds.
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Token.Colour.separator)
                .frame(width: 1)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                // In the overlay because a `background` on the column's root is never built.
                .background(SidebarSelectionHider())
        }
        // Under the list, which is where every source list on this platform puts "add" —
        // Finder's sidebar, Mail's mailboxes, Xcode's navigator. It was a toolbar item, up
        // in the strip the traffic lights own and a long way from the list it adds to.
        .overlay(alignment: .bottom) {
            SessionSidebarBar(sessions: sessions, ui: ui, openFolder: openFolder)
        }
    }

    private var list: some View {
        List(selection: selection) {
            // Above every session: the one view that is about all of them.
            AgentsRow(isSelected: ui.showsAgents)
                .tag(AgentsOverview.selectionID)
                .listRowBackground(
                    Capsule(style: .continuous)
                        .fill(Token.Colour.selectionWash)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .opacity(ui.showsAgents ? 1 : 0))
            ForEach(sessions.sessions, id: \.workspaceID) { store in
                SessionRow(store: store,
                           ui: ui,
                           isSelected: sessions.selectedID == store.workspaceID,
                           canClose: sessions.canCloseSelected,
                           select: { sessions.select(store.workspaceID) },
                           rename: { sessions.rename(store.workspaceID, to: $0) },
                           close: { ui.closingSessionID = store.workspaceID })
                    .tag(store.workspaceID)
                    // The selection, drawn here as a capsule — see `.tint(.clear)` below.
                    .listRowBackground(
                        Capsule(style: .continuous)
                            .fill(Token.Colour.selectionWash)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .opacity(!ui.showsAgents && sessions.selectedID == store.workspaceID ? 1 : 0))
            }
            // Drag a row to reorder. `List` gives this for nothing once a `ForEach` says it
            // is possible, including the insertion line and the drag image.
            //
            // The keyboard path is View ▸ Move Session Up / Down (⇧⌥⌘[ and ⇧⌥⌘]),
            // which is the rule rather than a courtesy: a drag-only reorder cannot be
            // reached at all by someone whose hands are on the keys, which here is everyone.
            .onMove { offsets, destination in
                sessions.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        // A sidebar list draws its selection in the TINT colour, as a rounded rectangle
        // whose radius there is no way to set. Clear, so the list's own goes unseen, and the
        // row's background above draws it instead: fully rounded, in the neutral wash —
        // see `Token.Colour.selectionWash` for why a coloured one fights the row's own icon.
        .tint(.clear)
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

/// Stops the sidebar list drawing its own selection, so the row's capsule is the only one.
///
/// A sidebar `List` draws its selection as a rounded rectangle there is no way to reshape,
/// and `.tint(.clear)` hides it only while the list has the keyboard — the rest of the time
/// it draws in grey, behind the capsule, as a second shape round the first. The list is an
/// `NSTableView` underneath, and a table can be told to draw no selection at all; selection
/// itself, the arrow keys and the binding are untouched. SwiftUI has no say over that, so
/// the table is found from a probe inside the column.
///
/// Re-applied on every update and on being moved into a window, since collapsing and
/// reopening the column can build the list again.
private struct SidebarSelectionHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Next turn: the list is built after this probe is in the window.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply() {
            // Up to the column — the view the split view holds — then down to the table.
            var column: NSView? = self
            while let view = column, !(view.superview is NSSplitView) { column = view.superview }
            guard let column else { return }
            Self.unhighlight(in: column)
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

/// The row above the sessions: the Agents overview, with how many agents are running
/// and the state the most pressing of them is in — the same glyph the session rows wear,
/// rolled up once more. Never hidden: a row that comes and goes is a view nobody learns
/// the key for. Dimmed with nothing running.
private struct AgentsRow: View {
    let isSelected: Bool

    private var running: Int { AgentMonitor.shared.runningCount }
    private var state: AgentState? { AgentState.rollup(AgentMonitor.shared.stateByPane.values) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.grid.2x2.fill")
                .font(Token.Type_.tileTitle)
                .foregroundStyle(running > 0 ? Token.Colour.label : Token.Colour.tertiaryLabel)
                .frame(width: 20)
            Text("Agents")
                .font(Token.Type_.tileTitle)
                .fontWeight(state?.isUnread == true ? .bold : .regular)
                .foregroundStyle(running > 0 ? Token.Colour.label : Token.Colour.tertiaryLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
            if running > 0 {
                Text("\(running)")
                    .font(Token.Type_.tileSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .fixedSize()
                    .frame(minWidth: 30, alignment: .trailing)
            }
            ZStack {
                if let state { AgentStateSymbol(state: state).help(state.title) }
            }
            .frame(width: 16, height: 16)
        }
        .contentShape(.rect)
        .help("Every working agent's pane, from every project (⌘0)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running > 0
                            ? "Agents, \(running) running" + (state.map { ", \($0.title)" } ?? "")
                            : "Agents, none running")
    }
}

private struct SessionRow: View {
    let store: LayoutStore
    @Bindable var ui: UIState
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    @State private var isHovering = false
    /// Read straight off the monitor, which is `@Observable`, so a row redraws when its own
    /// session's state changes and not when another's does. There is no per-row timer here
    /// and there must never be: one poll for the whole app is the rule `AgentMonitor` was
    /// written to hold. The age beside it reads the monitor's `minute`, which moves once a
    /// minute.
    private var state: AgentState? {
        AgentMonitor.shared.stateBySession[store.workspaceID]
    }
    /// Seeded from disk at the row's first appearance, so a customised session is already
    /// wearing its icon on the frame it is drawn in rather than flashing the default first.
    /// SwiftUI keeps this per row IDENTITY, and a row's identity is its session.
    @State private var appearance: SessionAppearance

    init(store: LayoutStore, ui: UIState, isSelected: Bool, canClose: Bool,
         select: @escaping () -> Void, rename: @escaping (String) -> Void,
         close: @escaping () -> Void) {
        self.store = store
        self.ui = ui
        self.isSelected = isSelected
        self.canClose = canClose
        self.select = select
        self.rename = rename
        self.close = close
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
            Image(systemName: SessionSymbols.resolved(appearance.symbol))
                .font(Token.Type_.tileTitle)
                .foregroundStyle(tint.color)
                // A fixed box, so switching between a wide symbol and a narrow one does not
                // shift the name beside it — a list whose text jumps as you customise rows
                // reads as broken.
                .frame(width: 20)

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
                // Bold while a finished turn waits to be looked at, as an unread mail is —
                // against the regular weight of every other row, or bold would not show
                // beside the title token's own medium. Dimmed once the session has gone
                // quiet for good.
                .fontWeight(state?.isUnread == true ? .bold : .regular)
                .foregroundStyle(state.map { if case .inactive = $0 { true } else { false } } == true
                                 ? AnyShapeStyle(Token.Colour.tertiaryLabel) : AnyShapeStyle(Token.Colour.label))
                .lineLimit(1)

            Spacer(minLength: 0)

            // How long the state has held: "now", "4m", "2d". Fixed width and trailing, so
            // the symbol beside it does not move as the minutes turn.
            if let state {
                Text(state.age(at: AgentMonitor.shared.minute))
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
            // it only appears on the row the pointer is over or the one that is selected,
            // and in both cases the session's agents are a glance away in the canvas
            // itself. The badge is for the sessions you are NOT looking at.
            ZStack {
                if isSelected || isHovering, canClose {
                    // Shown on the SELECTED row as well as the hovered one. Hover-only meant
                    // the close control did not exist for anyone not holding the pointer over
                    // the row — and the row you are most likely to want to close is the one
                    // you are in.
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    // Dimmer until the pointer is actually on the row, so a permanent control
                    // on the selected row does not compete with the name beside it.
                    .foregroundStyle(isHovering ? AnyShapeStyle(Token.Colour.label)
                                                : AnyShapeStyle(.secondary))
                    .help("Close session")
                } else if let state {
                    AgentStateSymbol(state: state)
                        .help(state.title)
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
        // NO tap gesture here, however tempting. One was added to catch the click on the
        // row that is ALREADY selected — SwiftUI does not call a selection binding's setter
        // when the value does not change, so that click had no path back to the terminal —
        // and even as a `simultaneousGesture` it swallowed the List's own click handling,
        // which made rows unselectable by their label. A focus nicety is not worth the
        // sidebar's primary verb. The same-row case is covered from the keyboard instead:
        // ⌘1…⌘9 and the focus commands reclaim even when the pane is already focused.
        // The PATH, always — a renamed session must still be able to tell you which checkout
        // it actually is, and after a rename the title no longer can.
        .help(store.workspaceSubtitle ?? store.workspaceTitle)
        // Right-click, where a source list keeps a row's own verbs. A visible button would be
        // a third control competing for the width the NAME needs. Both items here are views
        // of a menu command — a context menu is never the only way to reach something.
        .contextMenu {
            // Live on a scratch session as well — it is how one is renamed. Its icon is
            // kept for the session's lifetime (`SessionLook`), so nothing is silently lost.
            Button("Customize") { beginCustomizing() }
            if canClose {
                Divider()
                Button("Close Session", action: close)
            }
        }
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

    /// Select as well as open, so the session being customised is the one on screen behind
    /// the sheet. macOS lets you right-click a row without selecting it.
    private func beginCustomizing() {
        select()
        ui.customizingSessionID = store.workspaceID
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
private struct AgentSpinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.82)
            .stroke(Token.Colour.label, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(Token.Environment_.reduceMotion ? nil
                       : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
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
                        .fontWeight(state.isUnread ? .bold : .regular)
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
