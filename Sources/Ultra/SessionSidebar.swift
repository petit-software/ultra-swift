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
    /// The window's UI state, for two flags: whether the selected row's customise popover is
    /// open, and whether the new-project sheet is up. Both live up there because File ▸
    /// Session ▸ Customize Session… and File ▸ New Project… have to be able to open them
    /// without going through the sidebar at all.
    @Bindable var ui: UIState
    /// The folder picker lives in the app's command layer, so the bar asks for it rather
    /// than opening its own — two `NSOpenPanel`s configured separately drift apart.
    let openFolder: () -> Void

    private var selection: Binding<UUID?> {
        Binding(get: { sessions.selectedID },
                set: { id in
                    guard let id else { return }
                    // Clicking a row leaves AppKit's first responder on the LIST. Nothing
                    // about that changes the model, so the canvas has no reason to re-assert
                    // itself and the shell you just switched to could not be typed into —
                    // which is why `select` itself asks for the keyboard back, for this
                    // route and for the four others that never came through here.
                    sessions.select(id)
                })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(sessions.sessions, id: \.workspaceID) { store in
                SessionRow(store: store,
                           ui: ui,
                           isSelected: sessions.selectedID == store.workspaceID,
                           canClose: sessions.canCloseSelected,
                           select: { sessions.select(store.workspaceID) },
                           rename: { sessions.rename(store.workspaceID, to: $0) },
                           close: { sessions.close(store.workspaceID) })
                    .tag(store.workspaceID)
            }
        }
        // A sidebar list draws its selection in the TINT colour, so this is how the
        // selected row gets a neutral wash instead of a slab of accent — see
        // `Token.Colour.sidebarSelection` for why a coloured one fights the row's own icon.
        .tint(Token.Colour.sidebarSelection)
        // The footer floats OVER the list, and the list's content — not the list itself —
        // is inset to clear it. `safeAreaInset` was the obvious spelling and it is the wrong
        // one, for the reason written out on `View.tileFooter`: it shrinks the container, so
        // rows stop dead at the footer's top edge, nothing ever passes underneath, and the
        // ramp has nothing to fade against. Which made the footer read as a bar bolted on —
        // which is what the divider was there to justify.
        .contentMargins(.bottom, Token.Space.tileHeaderHeight, for: .scrollContent)
        // One kind of thing in one group, so a header would be a word explaining a list that
        // explains itself. The editor's sidebar has two sections because it holds two kinds.
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        .accessibilityLabel("Sessions")
        // The flag is window-level but the popover is anchored to the SELECTED row, so a
        // session switch while it is open — ⌥⌘] does this without touching the mouse — would
        // leave the flag set and reopen the popover on whatever row was landed on.
        .onChange(of: sessions.selectedID) { _, _ in ui.isCustomizingSession = false }
        // Under the list, which is where every source list on this platform puts "add" —
        // Finder's sidebar, Mail's mailboxes, Xcode's navigator. It was a toolbar item, up
        // in the strip the traffic lights own and a long way from the list it adds to.
        .overlay(alignment: .bottom) {
            SessionSidebarBar(sessions: sessions, ui: ui, openFolder: openFolder)
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
            // NEW. A plain button, not a menu: the choice between an empty folder and a
            // clone belongs in the sheet, where both are visible at once and the fields
            // under them explain what each one needs. A menu here would have made it a
            // decision taken before seeing either.
            Button { ui.isCreatingProject = true } label: {
                barLabel("plus.capsule.fill")
            }
            .buttonStyle(.plain)
            .help("New project — an empty folder or a clone (⇧⌘N)")
            .accessibilityLabel("New project")

            Spacer(minLength: 0)

            // OPEN. Clicking opens a folder; holding drops the recents. The plain menu made
            // the common case — "a project I have not opened before" — two clicks and a
            // read.
            Menu {
                ForEach(RecentProjects.list, id: \.self) { path in
                    Button(ShellPaneFactory.abbreviate(path)) { sessions.open(directory: path) }
                }
                if !RecentProjects.list.isEmpty { Divider() }
                Button("Open Folder…") { openFolder() }
            } label: {
                barLabel("folder.fill")
            } primaryAction: {
                openFolder()
                // Whether or not a folder was chosen: the button took first responder the
                // moment it was pressed, and a cancelled panel leaves it there.
                sessions.selected?.reclaimKeyboardFocus()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Belt and braces with the `foregroundStyle` in `barLabel`: the tint is what a
            // menu style reaches for first when it draws a label.
            .tint(Token.Colour.secondaryLabel)
            .help("Open an existing project in this window (⌘T)")
            .accessibilityLabel("Open project")
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

    /// The label is the whole hit target, padded rather than framed, so the press area
    /// matches what a bottom-bar button looks like instead of being a 12pt glyph you have to
    /// aim at. Shared by both controls so the two cannot end up different sizes.
    private func barLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            // Bold rather than semibold. These two are the smallest glyphs in the window and
            // they sit on a blurred ramp with rows fading underneath them, which eats a
            // weight — semibold read as thin here in a way the same weight does not in a
            // pane header sitting on a solid surface.
            .font(.system(size: 14, weight: .bold))
            // Stated, not inherited. One of these is a `Button` and the other is a `Menu`,
            // and a borderless menu draws its label in the CONTROL tint while a plain button
            // takes the foreground it is given — so the pair rendered in two different
            // colours despite sharing this label. The same token every other chrome icon
            // rests in (`ChromeIconLabel`), so the bar matches the pane headers above it.
            .foregroundStyle(Token.Colour.secondaryLabel)
            .frame(width: 26, height: 22)
            .contentShape(.rect)
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
    /// session's status changes and not when another's does. There is no per-row timer here
    /// and there must never be: one poll for the whole app is the rule `AgentMonitor` was
    /// written to hold.
    private var status: AgentStatus {
        AgentMonitor.shared.statusBySession[store.workspaceID] ?? .idle
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
        _appearance = State(initialValue: SessionAppearanceStore.appearance(
            forDirectory: store.workspaceDirectory))
    }

    private var tint: SessionTint { SessionTint(storedValue: appearance.tint) }

    /// The project folder's own name — what an emptied field falls back to, and what Reset
    /// puts back. Nil-safe: a workspace with no directory keeps whatever it is called.
    private var defaultName: String {
        store.workspaceDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? store.workspaceTitle
    }

    /// A window-level flag, read through this row's own selection. Only the selected row
    /// answers true, so the one flag cannot open a dozen popovers at once.
    private var isCustomizing: Binding<Bool> {
        Binding(get: { isSelected && ui.isCustomizingSession },
                set: { ui.isCustomizingSession = $0 })
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
                .lineLimit(1)

            Spacer(minLength: 0)

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
                } else if let badge = status.badge {
                    Image(systemName: badge.symbol)
                        .font(Token.Type_.tileTitle)
                        .foregroundStyle(badge.colour)
                        // Free, and correct: SwiftUI drops a symbol effect under Reduce
                        // Motion without this view having to ask. A working agent is the one
                        // state that is about to change on its own, so it is the one worth
                        // animating — the other three are settled.
                        .symbolEffect(.pulse, isActive: status == .working)
                        .help(badge.help)
                }
            }
            // Reserved whether or not anything is in it. Without the frame the name beside
            // it would reflow every time an agent started or a pointer arrived.
            .frame(width: 16)
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
            Button("Customize") { beginCustomizing() }
                // A workspace with no directory has no key to file an icon under, so the
                // picker would forget every choice the moment it closed. Dimmed rather than
                // silently lossy.
                .disabled(store.workspaceDirectory == nil)
            if canClose {
                Divider()
                Button("Close Session", action: close)
            }
        }
        .popover(isPresented: isCustomizing, arrowEdge: .trailing) {
            SessionCustomizer(name: name, appearance: $appearance, defaultName: defaultName) {
                appearance = .default
                rename(defaultName)
            }
            // A popover is its own window. Dismissing it hands key status back to this one,
            // and AppKit restores whatever first responder it had — which, since the popover
            // was opened from the sidebar, is the sidebar.
            .onDisappear { store.reclaimKeyboardFocus() }
        }
        // One place the icon is written, whichever control changed it — the swatches, the
        // symbols and Reset all just move the binding.
        .onChange(of: appearance) { _, new in
            SessionAppearanceStore.set(new, forDirectory: store.workspaceDirectory)
        }
        // The seed in `init` reads whatever the store knows AT THAT MOMENT, and a session
        // being restored can learn its project a beat later. Without this, such a row would
        // hold the default icon for the rest of the launch — the customisation would look
        // like it had not been saved at all.
        .onChange(of: store.workspaceDirectory) { _, directory in
            appearance = SessionAppearanceStore.appearance(forDirectory: directory)
        }
        .accessibilityElement(children: .combine)
        // The status is SPOKEN, not only coloured. A row whose whole meaning is a hue is a
        // row that says nothing to a VoiceOver user and half of one to anybody who cannot
        // separate the green from the red — which is why the badge carries a distinct glyph
        // as well, rather than four dots in four colours.
        .accessibilityLabel(status.badge.map { "Session, \(store.workspaceTitle), \($0.help)" }
                            ?? "Session, \(store.workspaceTitle)")
    }

    /// Select first, then open. The popover is anchored to the SELECTED row, and macOS lets
    /// you right-click a row without selecting it — without this, customising the second row
    /// would open a popover on the first.
    private func beginCustomizing() {
        select()
        ui.isCustomizingSession = true
    }
}

/// How a session's agent status looks in the sidebar.
///
/// The mapping lives HERE rather than on `AgentStatus` itself: the status is a fact the
/// terminal layer derives from a tty, and a type in `UltraTerminal` that knows about SF
/// Symbols and sidebar colours is a layer boundary that has stopped meaning anything.
private extension AgentStatus {
    struct Badge {
        let symbol: String
        let colour: Color
        /// The tooltip AND the accessibility label — one string, so what is read aloud and
        /// what is shown on hover cannot drift apart.
        let help: String
    }

    /// Nil for `idle`, which is the state with nothing to say. An always-present grey dot
    /// was tried in the head and rejected: a sidebar of six projects would carry six pieces
    /// of punctuation reporting that nothing is happening in any of them, and the one row
    /// that DID have news would have to compete with them to be noticed.
    var badge: Badge? {
        switch self {
        case .idle:
            nil
        // A plain dot, because "working" is the state that needs no reading — it is the
        // baseline the other three are exceptions to, and it is the one that pulses.
        case .working:
            Badge(symbol: "circle.fill", colour: Token.Colour.agentWorking,
                  help: "Agent working")
        case .needsInput:
            Badge(symbol: "questionmark.circle.fill", colour: Token.Colour.agentNeedsInput,
                  help: "Agent waiting for you")
        case .done:
            Badge(symbol: "checkmark.circle.fill", colour: Token.Colour.agentDone,
                  help: "Agent finished")
        // A triangle rather than a fifth circle. Failure is the one state where the SHAPE
        // should differ from a glance away, not only the colour.
        case .failed:
            Badge(symbol: "exclamationmark.triangle.fill", colour: Token.Colour.agentFailed,
                  help: "Agent exited with an error")
        }
    }
}
