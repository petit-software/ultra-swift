import AppKit
import SwiftUI
import UltraCanvas
import UltraDesign

/// The windows panes are moved into: Pane ▸ Move Pane to New Window (⇧⌘M).
///
/// Each shows a pane window's canvas — a `LayoutStore` of the same session, see
/// `LayoutStore.moveToNewWindow` — and nothing else: no sidebar and no tab belt, because
/// the sessions are the main window's. Its store is the focused store while it is key, so
/// the Pane menu, the palette and every key act on the panes in it.
///
/// Closing one is not closing its panes. They go back to the session's canvas, still
/// running — the window was only somewhere to look at them. Quitting is the exception:
/// the panes stay where they are, so the next launch opens the window again.
@MainActor
enum PaneWindows {
    static let sceneID = "ultra.paneWindow"

    /// The pane windows that are open or on their way, by the id their window was opened
    /// with. A window SwiftUI opens for an id not here has nothing to show and closes.
    private(set) static var stores: [UUID: LayoutStore] = [:]
    private static var windows: [UUID: NSWindow] = [:]
    private static var ids: [ObjectIdentifier: UUID] = [:]

    /// Opens a pane window's window. `openWindow` is an environment action, so this is set
    /// by the first workspace window to come up — after which the pane windows a restored
    /// session brought with it, which were waiting, open too.
    static var open: ((UUID) -> Void)? {
        didSet { flush() }
    }
    private static var pending: [UUID] = []
    private static var isTerminating = false
    private static var terminationObserver: (any NSObjectProtocol)?

    /// Show a pane window. Next turn of the run loop, so a window opened from a menu item
    /// is not opened from inside the menu's own action.
    static func show(_ store: LayoutStore) {
        let id = UUID()
        stores[id] = store
        ids[ObjectIdentifier(store)] = id
        store.onDismiss = { dismiss(id) }
        pending.append(id)
        DispatchQueue.main.async { flush() }
    }

    private static func flush() {
        guard let open, !pending.isEmpty else { return }
        let ids = pending
        pending = []
        for id in ids where stores[id] != nil { open(id) }
    }

    /// The pane window's store shown in this window, if it is one.
    static func store(in window: NSWindow) -> LayoutStore? {
        windows.first { $0.value === window }.flatMap { stores[$0.key] }
    }

    /// The window a pane window's store is shown in, if it is open.
    static func window(for store: LayoutStore) -> NSWindow? {
        ids[ObjectIdentifier(store)].flatMap { windows[$0] }
    }

    /// Its panes went back or its session closed: forget it, and close its window.
    private static func dismiss(_ id: UUID) {
        guard let store = stores.removeValue(forKey: id) else { return }
        ids[ObjectIdentifier(store)] = nil
        windows.removeValue(forKey: id)?.close()
    }

    /// The window that is showing a pane window, once it exists: put it where it was,
    /// and hear it close.
    static func attach(_ window: NSWindow, to id: UUID) {
        guard windows[id] !== window, let store = stores[id] else { return }
        windows[id] = window
        if let frame = store.windowFrame { window.setFrame(frame, display: false) }
        watchTermination()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { closed(id) }
            }
    }

    /// The user closed the window. Its panes go home — unless the app is quitting, when
    /// they stay in it for the next launch to open again.
    private static func closed(_ id: UUID) {
        // Out of the map first, so the dismissal that returning every pane ends in does
        // not close a window already closing.
        windows[id] = nil
        guard !isTerminating, let store = stores[id] else { return }
        store.returnAllPanes()
    }

    private static func watchTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isTerminating = true }
            }
    }
}

/// What a pane window's window holds: the canvas, on the window's material, with the
/// project's name over it.
struct PaneWindowView: View {
    let id: UUID?

    var body: some View {
        if let id, let store = PaneWindows.stores[id] {
            PaneWindowContent(store: store)
                .background(WindowReader { PaneWindows.attach($0, to: id) })
        } else {
            // A window with nothing to show — one SwiftUI brought back by itself, or one
            // whose panes went home before it appeared. It closes rather than standing
            // empty.
            Color.clear
                .frame(width: 1, height: 1)
                .background(WindowReader { window in
                    DispatchQueue.main.async { window.close() }
                })
        }
    }
}

private struct PaneWindowContent: View {
    let store: LayoutStore

    var body: some View {
        CanvasSurface(store: store)
            .overlay(alignment: .top) {
                WindowHeaderTitle(title: store.workspaceTitle)
                    .ignoresSafeArea()
            }
            .background {
                if Token.Environment_.reduceTransparency {
                    Token.Colour.tileBackground
                } else {
                    WindowSurface()
                }
            }
            .ignoresSafeArea()
            .navigationTitle(store.workspaceTitle)
            // The same bar as the main window's, and for the same reason: the project's
            // name is drawn in the middle of it (`WindowHeaderTitle`), which is laid out
            // for a toolbar's height. Without a toolbar the bar is the bare titlebar's,
            // half as tall, and the name sat on the pane's top edge.
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                // An empty centre, where the name is drawn: see `RootView`'s toolbar.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                // What a pane window can do as a window: send its pane home.
                ToolbarItem(placement: .primaryAction) {
                    Button { store.moveBackToMainWindow() } label: {
                        WindowBarGlyph("Move Pane Back to Main Window", symbol: "macwindow")
                    }
                    .help("Move Pane Back to Main Window (⇧⌘M)")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .focusedSceneValue(\.layoutStore, store)
    }
}

#Preview("Pane window", traits: .fixedLayout(width: 760, height: 520)) {
    // Placeholders, like the root's preview: a real session would start a shell the
    // moment the canvas appeared.
    PaneWindowContent(store: .placeholders(.single))
}
