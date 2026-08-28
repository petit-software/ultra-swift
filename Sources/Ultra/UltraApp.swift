import AppKit
import SwiftUI
import UltraCanvas
import UltraCore
import UltraTerminal
import UltraDesign
import UltraLayout

/// The focused tab's store and UI state.
///
/// SwiftUI menu commands are app-level, but with tabs there is no single store to bind them
/// to — a command must act on whichever tab has focus. These carry that focus to the menu.
struct LayoutStoreKey: FocusedValueKey { typealias Value = LayoutStore }
struct UIStateKey: FocusedValueKey { typealias Value = UIState }
struct SessionListKey: FocusedValueKey { typealias Value = SessionList }

extension FocusedValues {
    var layoutStore: LayoutStore? {
        get { self[LayoutStoreKey.self] }
        set { self[LayoutStoreKey.self] = newValue }
    }
    var uiState: UIState? {
        get { self[UIStateKey.self] }
        set { self[UIStateKey.self] = newValue }
    }
    /// The focused WINDOW's sessions. Distinct from `layoutStore`, which is the one session
    /// currently on screen — a command like "New Session" acts on the list, not on a canvas.
    var sessionList: SessionList? {
        get { self[SessionListKey.self] }
        set { self[SessionListKey.self] = newValue }
    }
}

@main
struct UltraApp: App {
    static let workspaceWindowID = "ultra.workspace"

    init() {
        #if DEBUG
        PaneCommands.assertNoTerminalConflicts()
        #endif
        // An SPM executable has no bundle, so it needs to ask for a regular app's
        // activation policy. The Xcode app target (M8) will not need this.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(id: Self.workspaceWindowID) {
            WorkspaceWindow()
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            PaneMenuCommands()
            WorkspaceCommands()
        }

        // ⌘, and the standard Settings window, for free.
        Settings { UltraSettings() }
    }
}

/// One window — which in AppKit is the same object as one TAB.
///
/// The store is created HERE rather than on `App`, and that is what makes tabs real: state
/// on `App` is shared by every window, so every tab would have shown the same panes.
struct WorkspaceWindow: View {
    @State private var model = WorkspaceModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(sessions: model.sessions, ui: model.ui)
            .task {
                model.adoptWindow()
                // Idempotent: every tab asks, one monitor runs. Started from a window
                // rather than from `init` because there is nothing to count until a
                // workspace exists, and stopping it is the app quitting.
                AgentMonitor.shared.start()
                // Idempotent too, and started here for the same reason: a notification
                // delivered before the last quit is still on screen, and this is the first
                // moment the app can take it back.
                AgentCompletionNotifier.shared.startClearingWhenActive()
                // Settings only reach panes that already exist because of this.
                PreferenceBridge.start()
                MenuBarItem.shared.syncWithPreference()
                // `openWindow` only exists in a SwiftUI environment; the menu bar item
                // needs it to recreate a window every user has closed.
                MenuBarItem.shared.openWorkspace = { openWindow(id: UltraApp.workspaceWindowID) }
                Updater.shared.startIfUpdatable()
            }
            .onDisappear {
                // EVERY session, not just the one on screen. A window holds several now, and
                // the ones behind it have exactly as much unsaved history as the visible one.
                for store in model.sessions.sessions {
                    store.persistNow()
                    ShellWorkspace.Registry.factories[store.workspaceID]?.saveScrollback()
                }
            }
            .focusedSceneValue(\.layoutStore, model.sessions.selected)
            .focusedSceneValue(\.sessionList, model.sessions)
            .focusedSceneValue(\.uiState, model.ui)
    }
}

/// Owns one WINDOW's sessions. A plain box held by `@State` so they survive redraws.
@MainActor
final class WorkspaceModel {
    let sessions: SessionList
    let ui = UIState()

    /// Only the first window of a launch reopens what the last run had. A second window is
    /// new work — restoring into it would clone the sessions already on screen.
    private static var hasRestored = false

    /// Where the FIRST window of a launch opens.
    ///
    /// A bundled app is launched by `launchd` with "/" as its working directory, so the cwd
    /// says nothing about intent and the app would open on the filesystem root. Falling back
    /// to home meant every launch landed in `$HOME` no matter how many projects had been
    /// opened — Open Folder every single time, which is not a feature, it is a chore.
    static var startDirectory: String {
        WorkspaceLaunch.directory(cwd: FileManager.default.currentDirectoryPath,
                                  preferred: Preferences.defaultProjectFolder,
                                  recents: RecentProjects.list,
                                  home: NSHomeDirectory(),
                                  exists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// The project the NEXT window should open on. Consumed once, the same idiom as a
    /// staged tile: `openWindow` cannot carry a value through to `WorkspaceModel`, and a
    /// value left standing would make every later tab inherit a project opened once.
    @MainActor static var pendingDirectory: String?

    init() {
        let requested = WorkspaceModel.pendingDirectory
        WorkspaceModel.pendingDirectory = nil
        sessions = SessionList(storage: WorkspaceStorage())

        // A window opened ON a project restores that project's layout even though it is not
        // the first window of the launch. The "new window is new work" rule exists to stop a
        // window cloning what is already on screen; a different project's document cannot do
        // that, and refusing to restore it would throw the layout away instead.
        let isFirst = !Self.hasRestored
        Self.hasRestored = true

        if let requested {
            sessions.open(directory: requested, restore: true)
            return
        }
        // The first window of a launch reopens every session the last run had, which is what
        // makes a window of sessions worth arranging: it is still there tomorrow.
        if isFirst, sessions.restoreSaved() { return }
        sessions.open(directory: Self.startDirectory, restore: isFirst)
    }

    /// Put the window back where it was before it can be seen elsewhere. Only the restoring
    /// tab has a saved frame; a new tab takes AppKit's cascade.
    func adoptWindow() {
        NSApplication.shared.activate()
        let window = NSApp.windows.first { $0.isKeyWindow } ?? NSApp.windows.first
        // Every session in this window lives in this window — the map is what lets "open a
        // project already open" raise the right one rather than opening it twice.
        if let window {
            for store in sessions.sessions {
                ShellWorkspace.Registry.windows[store.workspaceID] = window
            }
        }
        guard let frame = sessions.selected?.windowFrame else { return }
        window?.setFrame(frame, display: false)
    }
}

/// Window- and tab-level verbs. Everything reaches the focused tab through `@FocusedValue`.
struct WorkspaceCommands: Commands {
    @FocusedValue(\.layoutStore) private var store
    @FocusedValue(\.sessionList) private var sessions
    @FocusedValue(\.uiState) private var ui
    @Environment(\.openWindow) private var openWindow

    /// What the focused pane currently is, so "Change Pane To" can disable the no-op.
    private var currentKind: PaneRecord.Kind? {
        guard let store else { return nil }
        return store.surfaces.records[store.tree.focused]?.kind
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(directory: url.path)
    }

    /// Raise the project if it is already open; otherwise hand it to the next window.
    ///
    /// Raising rather than opening a second window is not politeness. Both windows would
    /// restore the same document id and both would persist to it, so whichever was touched
    /// last would silently overwrite the other's layout.
    private func open(directory: String) {
        // Already open SOMEWHERE: raise it. Two sessions on one project would both restore
        // the same document and both persist to it, so the last one touched would silently
        // overwrite the other's layout — the rule that made two windows on one project a bug
        // applies just as much to two sessions.
        if let existing = ShellWorkspace.Registry.store(forDirectory: directory) {
            if let window = ShellWorkspace.Registry.windows[existing.workspaceID] {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate()
            }
            sessions?.select(existing.workspaceID)
            return
        }
        // A SESSION in this window rather than another window. That is what the sidebar is
        // for: projects side by side in one place, not a window each.
        if let sessions {
            sessions.open(directory: directory)
            return
        }
        RecentProjects.remember(directory)
        WorkspaceModel.pendingDirectory = directory
        openWindow(id: UltraApp.workspaceWindowID)
    }

    var body: some Commands {
        // Where every Mac app puts it. Absent entirely on a copy that cannot update, rather
        // than present and disabled: a disabled item invites a click and explains nothing.
        CommandGroup(after: .appInfo) {
            if Updater.shared.canCheck {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            }
        }

        CommandGroup(after: .newItem) {
            Button("Open Folder…") { chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent") {
                ForEach(RecentProjects.list, id: \.self) { path in
                    Button(ShellPaneFactory.abbreviate(path)) { open(directory: path) }
                }
                if !RecentProjects.list.isEmpty {
                    Divider()
                    Button("Clear Menu") { RecentProjects.clear() }
                }
            }
            .disabled(RecentProjects.list.isEmpty)

            Divider()

            // ⌘T is the "another one of these" key on every Mac app, and a session is what
            // this window now holds more than one of. It used to make a native window tab;
            // those are off, because the sidebar replaced them.
            Button("New Session…") { chooseFolder() }
                .keyboardShortcut("t", modifiers: .command)

            Button("New Window") { openWindow(id: UltraApp.workspaceWindowID) }
                .keyboardShortcut("n", modifiers: .command)

            Menu("Session") {
                Button("Next Session") { sessions?.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Previous Session") { sessions?.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Divider()
                Button("Close Session") {
                    if let id = sessions?.selectedID { sessions?.close(id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .control, .shift])
                .disabled(!(sessions?.canCloseSelected ?? false))
            }
            .disabled(sessions == nil)

            Button("New Shell Pane") {
                guard let store else { return }
                ShellWorkspace.openShell(in: store)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(store == nil)

            // Every non-shell kind, from one list — a new kind must not need three
            // separate edits to become openable.
            Menu("New Tile Pane") {
                ForEach(PaneKind.all.filter { $0.kind != .shell }) { entry in
                    Button(entry.title) {
                        guard let store else { return }
                        ShellWorkspace.openTile(entry.kind, in: store)
                    }
                    .modifier(TileShortcut(kind: entry.kind))
                }
            }
            .disabled(store.map { !ShellWorkspace.canOpenNewPane(in: $0) } ?? true)

            // Switching an EXISTING pane, rather than opening another one. Separate on
            // purpose: converting a shell ends its process, which is not something to
            // discover by picking the wrong menu item.
            Menu("Change Pane To") {
                ForEach(PaneKind.all) { entry in
                    Button(entry.title) {
                        guard let store else { return }
                        ShellWorkspace.convert(store.tree.focused, to: entry.kind, in: store)
                    }
                    .disabled(currentKind == entry.kind)
                }
            }
            .disabled(store == nil)

            Menu("New Agent Pane") {
                ForEach(ShellWorkspace.availableAgents()) { agent in
                    Button(agent.name) {
                        guard let store else { return }
                        ShellWorkspace.openShell(agent: agent, in: store)
                    }
                }
            }
            .disabled(store == nil)
        }

        // ⌘W belongs to the PANE here, the way it does in every terminal — and taking it
        // requires REPLACING this group rather than rebinding anything.
        //
        // AppKit's stock File ▸ Close owns ⌘W, and the File menu is searched before Pane, so
        // `pane.close` never had the key to begin with: SwiftUI saw the duplicate and dropped
        // the shortcut, leaving Pane ▸ Close Pane showing no binding at all while ⌘W quietly
        // closed the window — and with it the app, since closing the last window quits.
        //
        // Closing a window is still one keystroke away, just the shifted one, which is the
        // arrangement Terminal and iTerm both settled on.
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            // `windows` includes panels and the offscreen ones AppKit keeps around, so this
            // asks each whether it is a real, visible window before closing it — and closes
            // through `performClose` so each still gets to save its scrollback and layout.
            Button("Close All Windows") {
                for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                    window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])

            Divider()

            Button("Save Layout Now") { store?.persistNow() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { ui?.isPaletteShown = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(ui == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(store?.undoManager.undoMenuItemTitle ?? "Undo") { store?.undoManager.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(store?.undoManager.canUndo ?? false))
            Button(store?.undoManager.redoMenuItemTitle ?? "Redo") { store?.undoManager.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(store?.undoManager.canRedo ?? false))
        }
    }
}

struct RootView: View {
    @Bindable var sessions: SessionList
    @Bindable var ui: UIState
    /// Owned here so the system's own sidebar toggle has something to drive. Starting at
    /// `.all` because a window whose session list is collapsed on first launch is a window
    /// with a feature nobody discovers.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The session on screen. Nil only for the instant before the first one exists.
    private var store: LayoutStore? { sessions.selected }

    /// What the focused pane is right now, so File ▸ Change Pane To can dim the entry the
    /// user is already looking at.
    private var currentKind: PaneRecord.Kind? {
        guard let store else { return nil }
        return store.surfaces.records[store.tree.focused]?.kind
    }

    private func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sessions.open(directory: url.path)
    }

    var body: some View {
        // Splitting and zoom belong to a PANE, and every pane header already carries them.
        // Duplicating them at window level meant two controls for one verb, and the window
        // copy silently acted on whichever pane happened to be focused.
        // `NavigationSplitView` rather than a hand-built column: the sidebar's width, its
        // collapse, the traffic lights sitting over it, its material, and the toggle button
        // in the toolbar are all things macOS already does. Rebuilding them out of an
        // `HStack` and a spacer is how you end up maintaining a worse copy of AppKit.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebar(sessions: sessions)
                .toolbar {
                    // The sidebar's OWN toolbar item, so it lands over the sidebar column
                    // where every source list puts "add", rather than among the pane verbs.
                    ToolbarItem {
                        Menu {
                            ForEach(RecentProjects.list, id: \.self) { path in
                                Button(ShellPaneFactory.abbreviate(path)) {
                                    sessions.open(directory: path)
                                }
                            }
                            if !RecentProjects.list.isEmpty { Divider() }
                            Button("Open Folder…") { chooseSessionFolder() }
                        } label: {
                            Label("New Session", systemImage: "plus")
                        }
                        .help("Open another project in this window (⌘T)")
                    }
                }
        } detail: {
            if let store {
                CanvasSurface(store: store)
            } else {
                Color.clear
            }
        }
        // The window's material, at WINDOW scope — behind the sidebar and the canvas alike.
        //
        // It used to live inside `CanvasSurface`, which was the whole window until the window
        // grew a sidebar. Left there it drew the window's rounded corner and edge stroke
        // around the DETAIL COLUMN, which reads as a bordered card parked beside the sidebar
        // rather than as one window.
        .background {
            if Token.Environment_.reduceTransparency {
                Token.Colour.tileBackground
            } else {
                WindowSurface()
            }
        }
        .ignoresSafeArea()
            .sheet(isPresented: $ui.isPaletteShown) {
                if let store {
                    CommandPalette(store: store, isPresented: $ui.isPaletteShown)
                }
            }
            // In the real toolbar rather than drawn into the titlebar ourselves: on macOS 26
            // a toolbar item gets the standard Liquid Glass treatment automatically, which
            // is the same glass Finder's toolbar buttons wear. Nothing to style by hand.
            .toolbar {
                // `.principal` is the toolbar's centre slot — the same one Mail and Notes
                // use for a title, so it stays centred as the window resizes.
                ToolbarItem(placement: .principal) {
                    Text("Ultra")
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .foregroundStyle(Token.Colour.label)
                }
                // A name is a label, not a control — the shared glass capsule macOS 26 puts
                // behind toolbar items made it read as a button you could press.
                .sharedBackgroundVisibility(.hidden)

                // Everything else the toolbar owns sits hard right; the flexible spacer is
                // what pushes it there, leaving the leading side to the traffic lights.
                ToolbarSpacer(.flexible)

                // Split and zoom are PANE verbs, and every pane header already carries
                // them next to the pane they act on. Up here they acted on whichever pane
                // happened to be focused, which is a different control wearing the same
                // icon. The palette stays: it is the one item here about the window.
                // Both remain on their keyboard shortcuts and in the menu bar.
                ToolbarItemGroup(placement: .primaryAction) {
                    // Every pane kind, one click from the window itself. Buried in a menu
                    // bar submenu they may as well not exist — this is where someone looks
                    // for "another pane", and it is the only place the full list is
                    // discoverable.
                    //
                    // Beside Commands rather than in `.navigation`. It sat with the traffic
                    // lights, which is where macOS puts BACK — a place for getting out of
                    // where you are, not for making something new. The two things this
                    // window offers at the top level are "run a command" and "add a pane",
                    // and a pair of verbs reads as a pair when it is together.
                    Menu {
                        Section("New Pane") {
                            Button("Shell") {
                                if let store { ShellWorkspace.openShell(in: store) }
                            }
                            ForEach(PaneKind.all.filter { $0.kind != .shell }) { entry in
                                Button(entry.title) {
                                    if let store { ShellWorkspace.openTile(entry.kind, in: store) }
                                }
                            }
                        }
                        // Dimmed rather than silent: with the canvas full, every one of
                        // these can only beep.
                        .disabled(store.map { !ShellWorkspace.canOpenNewPane(in: $0) } ?? true)
                    } label: {
                        Label("Add Pane", systemImage: "plus")
                    }
                    .help("New pane")

                    Button { ui.isPaletteShown = true } label: {
                        Label("Commands", systemImage: "command")
                    }
                    .help("Command Palette (⇧⌘P)")
                }
            }
    }
}

#Preview("Root — three sessions", traits: .fixedLayout(width: 1100, height: 700)) {
    // Adopted rather than opened: a preview that called `ShellWorkspace.make` three times
    // would start three real shells the moment the canvas appeared.
    RootView(sessions: SessionList(storage: WorkspaceStorage(),
                                   adopting: [.placeholders(.threeAcross),
                                              .placeholders(.grid2x2),
                                              .placeholders(.single)]),
             ui: UIState())
}


/// Default shortcuts for the tile kinds that earn one. Kinds without a binding are still
/// reachable from the menu and the palette — a shortcut nobody can remember is not a feature.
private struct TileShortcut: ViewModifier {
    let kind: PaneRecord.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .fileTree: content.keyboardShortcut("e", modifiers: [.command, .option])
        case .todo: content.keyboardShortcut("y", modifiers: [.command, .option])
        case .git: content.keyboardShortcut("g", modifiers: [.command, .option])
        default: content
        }
    }
}

