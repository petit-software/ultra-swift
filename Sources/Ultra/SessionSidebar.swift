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
    /// The window's UI state, for one flag: whether the selected row's customise popover is
    /// open. It lives up there because File ▸ Session ▸ Customize Session… has to be able to
    /// open it without going through a row.
    @Bindable var ui: UIState
    /// The folder picker lives in the app's command layer, so the bar asks for it rather
    /// than opening its own — two `NSOpenPanel`s configured separately drift apart.
    let openFolder: () -> Void

    private var selection: Binding<UUID?> {
        Binding(get: { sessions.selectedID },
                set: { id in
                    guard let id else { return }
                    sessions.select(id)
                    // Clicking a row leaves AppKit's first responder on the LIST. Nothing
                    // about that changes the model, so the canvas had no reason to re-assert
                    // itself and the shell you just switched to could not be typed into.
                    sessions.selected?.reclaimKeyboardFocus()
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
            SessionSidebarBar(sessions: sessions, openFolder: openFolder)
        }
    }
}

/// The bar under the list: add a session, and nothing else.
///
/// Deliberately one control. A bottom bar is the easiest place in an app to accumulate
/// buttons nobody presses, and everything else a session can do is on the row itself.
private struct SessionSidebarBar: View {
    @Bindable var sessions: SessionList
    let openFolder: () -> Void

    var body: some View {
        HStack(spacing: 0) {
                Menu {
                    ForEach(RecentProjects.list, id: \.self) { path in
                        Button(ShellPaneFactory.abbreviate(path)) { sessions.open(directory: path) }
                    }
                    if !RecentProjects.list.isEmpty { Divider() }
                    Button("Open Folder…") { openFolder() }
                } label: {
                    // The label is the whole hit target, padded rather than framed, so the
                    // press area matches what a bottom-bar button looks like instead of
                    // being a 12pt glyph you have to aim at.
                    Label("New Session", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 20)
                        .contentShape(.rect)
                } primaryAction: {
                    // Clicking opens a folder; holding drops the recents menu. The plain
                    // menu made the common case — "add a project I have not opened before"
                    // — take two clicks and a read.
                    openFolder()
                    // Whether or not a folder was chosen: the button took first responder
                    // the moment it was pressed, and a cancelled panel leaves it there.
                    sessions.selected?.reclaimKeyboardFocus()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open another project in this window (⌘T)")
                .accessibilityLabel("New session")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
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

private struct SessionRow: View {
    let store: LayoutStore
    @Bindable var ui: UIState
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    @State private var isHovering = false
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

            // Shown on the SELECTED row as well as the hovered one. Hover-only meant the
            // close control did not exist for anyone not holding the pointer over the row —
            // and the row you are most likely to want to close is the one you are in.
            if isSelected || isHovering, canClose {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                // Dimmer until the pointer is actually on the row, so a permanent control on
                // the selected row does not compete with the name beside it.
                .foregroundStyle(isHovering ? AnyShapeStyle(Token.Colour.label)
                                            : AnyShapeStyle(.secondary))
                .help("Close session")
            }
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
        .accessibilityLabel("Session, \(store.workspaceTitle)")
    }

    /// Select first, then open. The popover is anchored to the SELECTED row, and macOS lets
    /// you right-click a row without selecting it — without this, customising the second row
    /// would open a popover on the first.
    private func beginCustomizing() {
        select()
        ui.isCustomizingSession = true
    }
}
