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

extension FocusedValues {
    var layoutStore: LayoutStore? {
        get { self[LayoutStoreKey.self] }
        set { self[LayoutStoreKey.self] = newValue }
    }
    var uiState: UIState? {
        get { self[UIStateKey.self] }
        set { self[UIStateKey.self] = newValue }
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

    var body: some View {
        RootView(store: model.store, ui: model.ui)
            .task { model.adoptWindow() }
            .onDisappear { model.store.persistNow() }
            .focusedSceneValue(\.layoutStore, model.store)
            .focusedSceneValue(\.uiState, model.ui)
    }
}

/// Owns one tab's workspace. A plain box held by `@State` so the store survives redraws.
@MainActor
final class WorkspaceModel {
    let store: LayoutStore
    let ui = UIState()

    /// Only the first window of a launch restores the saved layout. A new tab is new work —
    /// restoring into it would clone the panes the user already has open.
    private static var hasRestored = false

    /// A bundled app is launched by `launchd` with "/" as its working directory, so a new
    /// tab would open at the filesystem root. Home is the sane default for a shell.
    static var startDirectory: String {
        let cwd = FileManager.default.currentDirectoryPath
        return cwd == "/" ? NSHomeDirectory() : cwd
    }

    init() {
        let restore = !Self.hasRestored
        Self.hasRestored = true
        store = ShellWorkspace.make(storage: WorkspaceStorage(),
                                    directory: Self.startDirectory,
                                    restore: restore)
    }

    /// Put the window back where it was before it can be seen elsewhere. Only the restoring
    /// tab has a saved frame; a new tab takes AppKit's cascade.
    func adoptWindow() {
        NSApplication.shared.activate()
        guard let frame = store.windowFrame else { return }
        let window = NSApp.windows.first { $0.isKeyWindow } ?? NSApp.windows.first
        window?.setFrame(frame, display: false)
    }
}

/// Window- and tab-level verbs. Everything reaches the focused tab through `@FocusedValue`.
struct WorkspaceCommands: Commands {
    @FocusedValue(\.layoutStore) private var store
    @FocusedValue(\.uiState) private var ui
    @Environment(\.openWindow) private var openWindow

    /// What the focused pane currently is, so "Change Pane To" can disable the no-op.
    private var currentKind: PaneRecord.Kind? {
        guard let store else { return nil }
        return store.surfaces.records[store.tree.focused]?.kind
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // ⌘T is the tab key on every other Mac app, so it is the tab key here. The
            // pane verb it used to hold moved to ⌥⌘T, beside the other pane bindings.
            Button("New Tab") { openWindow(id: UltraApp.workspaceWindowID) }
                .keyboardShortcut("t", modifiers: .command)

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

        CommandGroup(after: .saveItem) {
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
    let store: LayoutStore
    @Bindable var ui: UIState

    /// What the focused pane is right now, so "Change This Pane To" can dim the entry the
    /// user is already looking at.
    private var currentKind: PaneRecord.Kind? {
        store.surfaces.records[store.tree.focused]?.kind
    }

    var body: some View {
        CanvasSurface(store: store, barActions: [
            WindowBarAction(id: "pane.split.right", symbol: "square.split.2x1",
                            help: "Split Right (⌘D)") { store.split(edge: .right) },
            WindowBarAction(id: "pane.split.down", symbol: "square.split.1x2",
                            help: "Split Down (⇧⌘D)") { store.split(edge: .bottom) },
            WindowBarAction(id: "pane.zoom", symbol: "arrow.down.right.and.arrow.up.left",
                            help: "Toggle Zoom (⇧⌘↩)") { store.toggleZoom() },
            WindowBarAction(id: "app.palette", symbol: "command",
                            help: "Command Palette (⇧⌘P)") { ui.isPaletteShown = true },
        ])
            .sheet(isPresented: $ui.isPaletteShown) {
                CommandPalette(store: store, isPresented: $ui.isPaletteShown)
            }
            // In the real toolbar rather than drawn into the titlebar ourselves: on macOS 26
            // a toolbar item gets the standard Liquid Glass treatment automatically, which
            // is the same glass Finder's toolbar buttons wear. Nothing to style by hand.
            .toolbar {
                // Every pane kind, one click from the window itself. Buried in a menu bar
                // submenu they may as well not exist — this is where someone looks for
                // "another pane", and it is the only place the full list is discoverable.
                // `.navigation` is the toolbar's LEADING slot, so it sits with the traffic
                // lights rather than among the pane verbs on the right.
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Section("New Pane") {
                            Button("Shell") { ShellWorkspace.openShell(in: store) }
                            ForEach(PaneKind.all.filter { $0.kind != .shell }) { entry in
                                Button(entry.title) {
                                    ShellWorkspace.openTile(entry.kind, in: store)
                                }
                            }
                        }
                        // Dimmed rather than silent: with the canvas full, every one of
                        // these can only beep.
                        .disabled(!ShellWorkspace.canOpenNewPane(in: store))
                        Section("Change This Pane To") {
                            ForEach(PaneKind.all) { entry in
                                Button(entry.title) {
                                    ShellWorkspace.convert(store.tree.focused,
                                                           to: entry.kind, in: store)
                                }
                                .disabled(currentKind == entry.kind)
                            }
                        }
                    } label: {
                        Label("Add Pane", systemImage: "plus")
                    }
                    .help("New pane, or change this one")
                }

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

                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.split(edge: .right) } label: {
                        Label("Split Right", systemImage: "square.split.2x1")
                    }
                    .help("Split Right (⌘D)")

                    Button { store.split(edge: .bottom) } label: {
                        Label("Split Down", systemImage: "square.split.1x2")
                    }
                    .help("Split Down (⇧⌘D)")

                    Button { store.toggleZoom() } label: {
                        Label("Toggle Zoom", systemImage: store.tree.zoomed != nil
                              ? "arrow.up.left.and.arrow.down.right"
                              : "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Toggle Zoom (⇧⌘↩)")
                    .disabled(store.tree.paneCount <= 1)

                    Button { ui.isPaletteShown = true } label: {
                        Label("Commands", systemImage: "command")
                    }
                    .help("Command Palette (⇧⌘P)")
                }
            }
    }
}

#Preview("Root — three across", traits: .fixedLayout(width: 1100, height: 700)) {
    RootView(store: .placeholders(.threeAcross), ui: UIState())
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
