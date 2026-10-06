import AppKit
import Foundation
import Observation
import UltraCanvas
import UltraCore
import UltraDesign

/// The sessions one window is holding, and which of them is on screen.
///
/// A session is a WHOLE CANVAS — its own pane grid, its own shells, its own agent socket —
/// so this is what macOS window tabs used to be here, moved inside the window and given a
/// list you can see. Native tabbing is off (`WindowChrome.configure`): two tab systems in one
/// window is worse than either.
///
/// The architecture already allowed this and that is the only reason it is cheap.
/// `PaneSurfaceStore` owns pane views ABOVE the view layer precisely so a pane's process
/// outlives every layout change — so the sessions you are not looking at keep their shells
/// running, with nothing but their canvas view torn down.
@MainActor
@Observable
final class SessionList {
    private(set) var sessions: [LayoutStore] = []
    private(set) var selectedID: UUID?

    @ObservationIgnored private let storage: WorkspaceStorage

    /// The window this list is shown in, once it is known (`WorkspaceModel.attach`).
    ///
    /// Every session held is mapped to it in the Registry, including the ones opened
    /// AFTER the window arrived. They used not to be — the map was written once, when the
    /// window was adopted — so ⌘W on the last pane of a project opened later had no window
    /// to close, and the menu bar item had none to bring forward.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard let window else { return }
            for store in sessions { ShellWorkspace.Registry.windows[store.workspaceID] = window }
        }
    }

    /// The window's UI state, for the one thing a command needs of it from here: the
    /// question asked before a session closes. See `askToClose`.
    @ObservationIgnored weak var ui: UIState?

    /// Every list there is, so a session can be asked "which window has you?". Weak: a
    /// list belongs to its window's model, and SwiftUI builds and discards models freely
    /// (see `WorkspaceModel.init`). A discarded one holds no sessions and answers nothing.
    @ObservationIgnored private static let lists = NSHashTable<SessionList>.weakObjects()

    init(storage: WorkspaceStorage) {
        self.storage = storage
        Self.lists.add(self)
    }

    /// A list built from stores that already exist.
    ///
    /// Previews and tests need one without `ShellWorkspace.make` spawning a real shell for
    /// every session — a preview that starts four PTYs is a preview nobody can leave open.
    init(storage: WorkspaceStorage, adopting stores: [LayoutStore]) {
        self.storage = storage
        self.sessions = stores
        self.selectedID = stores.first?.workspaceID
        Self.lists.add(self)
    }

    var selected: LayoutStore? {
        sessions.first { $0.workspaceID == selectedID }
    }

    var isEmpty: Bool { sessions.isEmpty }

    /// What each row is called. The project's name, which is what a session IS.
    func title(of store: LayoutStore) -> String { store.workspaceTitle }

    // MARK: - Opening

    /// Open a project as a session, or select it if this window already has it.
    ///
    /// Selecting rather than adding a second is not politeness. Both sessions would restore
    /// the same document id and both would persist to it, so whichever was touched last would
    /// silently overwrite the other's layout — the same last-writer-wins collision that made
    /// two WINDOWS on one project a bug.
    ///
    /// The same rule reaches past this window, for the same reason: a project another
    /// window is showing is raised there, and one still running from a window that has
    /// closed is taken back as it is — see `WorkspaceLaunch.opening`. Only `restore: false`
    /// skips that: it is how a window is given a deliberate, unsaved twin.
    @discardableResult
    func open(directory: String, restore: Bool = true) -> LayoutStore {
        let wanted = WorkspaceDocument.canonical(directory)
        let matches = { (store: LayoutStore) in
            store.workspaceDirectory.map(WorkspaceDocument.canonical) == wanted
        }
        if let existing = sessions.first(where: matches) {
            select(existing.workspaceID)
            return existing
        }
        if restore, let running = ShellWorkspace.Registry.store(forDirectory: wanted) {
            let others = Self.others(than: self)
            switch WorkspaceLaunch.opening(
                wanted, here: [],
                elsewhere: others.flatMap(\.sessions).compactMap(\.workspaceDirectory),
                running: [wanted]) {
            case .raise:
                if let holder = others.first(where: { $0.sessions.contains(where: matches) }),
                   let held = holder.sessions.first(where: matches) {
                    holder.select(held.workspaceID)
                    holder.window?.makeKeyAndOrderFront(nil)
                    return held
                }
            case .adopt:
                hold(running)
                select(running.workspaceID)
                RecentProjects.remember(directory)
                persist()
                return running
            case .select, .make:
                break
            }
        }
        // A project that carries Ultra's `AGENTS.md` section keeps it current with this
        // build's text. One that does not is not written into — opening is not opting in.
        ProjectInstructions.refresh(in: directory)
        let store = ShellWorkspace.make(storage: storage, directory: directory, restore: restore)
        hold(store)
        select(store.workspaceID)
        RecentProjects.remember(directory)
        persist()
        return store
    }

    /// Add a session to this window, and say which window that is.
    private func hold(_ store: LayoutStore) {
        sessions.append(store)
        if let window { ShellWorkspace.Registry.windows[store.workspaceID] = window }
    }

    // MARK: - Windows closing, and coming back

    /// The list whose window is showing this session, if one is. How a registry command,
    /// which is handed a `LayoutStore` and nothing else, reaches the session's list.
    static func holding(_ store: LayoutStore) -> SessionList? {
        lists.allObjects.first { $0.sessions.contains { $0 === store } }
    }

    private static func others(than list: SessionList?) -> [SessionList] {
        lists.allObjects.filter { $0 !== list }
    }

    /// The sessions still running that no window is showing: their window has closed.
    private static var unheld: [LayoutStore] {
        let held = Set(lists.allObjects.flatMap(\.sessions).map(\.workspaceID))
        return ShellWorkspace.Registry.stores.values.filter { !held.contains($0.workspaceID) }
    }

    /// The window has closed. Let go of its sessions without stopping one of them.
    ///
    /// A pane's process outlives its window, so the shells go on running and the agents in
    /// them go on working; what ends here is this list's claim on them. Without that the
    /// sessions were running and unreachable: no window showed them, and every way of
    /// opening their projects found them "open" and stopped. Let go of, the next window
    /// takes them back (`adoptRunning`), and so does opening any one of them.
    ///
    /// Saved first, as the window's teardown always did. NOT `persist()`: the stored list
    /// is what this window held, and it is what the next launch should reopen.
    func relinquish() {
        for store in sessions {
            store.persistNow()
            ShellWorkspace.Registry.factories[store.workspaceID]?.saveScrollback()
            ShellWorkspace.Registry.windows[store.workspaceID] = nil
        }
        sessions = []
        selectedID = nil
        window = nil
    }

    /// Take back the sessions a closed window left running. False when there are none.
    ///
    /// In the order that window had them, which is the stored order, and — unless the
    /// caller has already put something on screen — on the one it had selected: a window
    /// closed and reopened comes back as it was, with nothing restarted.
    @discardableResult
    func adoptRunning(selecting: Bool = true) -> Bool {
        let saved = Self.saved
        let order = (saved?.directories ?? []).map(WorkspaceDocument.canonical)
        let rank = { (store: LayoutStore) in
            store.workspaceDirectory.map(WorkspaceDocument.canonical)
                .flatMap(order.firstIndex(of:)) ?? order.count
        }
        let running = Self.unheld.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        guard !running.isEmpty else { return false }
        for store in running { hold(store) }
        if selecting {
            let wanted = saved?.selected.map(WorkspaceDocument.canonical)
            let match = running.first {
                $0.workspaceDirectory.map(WorkspaceDocument.canonical) == wanted
            }
            select((match ?? running[0]).workspaceID)
        }
        persist()
        return true
    }

    /// Bring forward the window that has this project, if one does.
    static func raise(directory: String) -> Bool {
        let wanted = WorkspaceDocument.canonical(directory)
        for list in lists.allObjects {
            guard let store = list.sessions.first(where: {
                $0.workspaceDirectory.map(WorkspaceDocument.canonical) == wanted
            }) else { continue }
            list.select(store.workspaceID)
            list.window?.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    /// Rename a session.
    ///
    /// The title is a field of the WORKSPACE DOCUMENT — the same one `ShellWorkspace` reads
    /// back on restore — so persisting is the whole of the work; there is no second copy to
    /// keep in step. Debounced through `persist()` rather than written on every keystroke,
    /// because the field applies as you type and a synchronous write per character would hit
    /// the disk a dozen times for one rename.
    ///
    /// A blank name is refused rather than corrected here: the field that offers one already
    /// falls back to the folder's name when it loses focus, and a store that silently
    /// rewrites what it is handed makes that fallback impossible to reason about.
    func rename(_ id: UUID, to title: String) {
        guard let store = sessions.first(where: { $0.workspaceID == id }),
              !title.isEmpty, store.workspaceTitle != title else { return }
        store.workspaceTitle = title
        store.persist()
    }

    /// Show a session, and put the keyboard in it.
    ///
    /// The reclaim belongs HERE rather than in the sidebar's selection binding, which is
    /// where it used to live. A session is reached from at least five places — a row click,
    /// ⌥⌘] and ⌥⌘[, Open Recent raising a project this window already holds, the command
    /// palette, `open(directory:)` — and only the first of them went through that binding.
    /// Every other route landed on a canvas nothing had asked to take the keyboard back, so
    /// the shell you had just switched to could not be typed into.
    ///
    /// Asked for even when the id has not CHANGED, and deliberately: selecting the session
    /// already on screen is the one gesture a user has for "give me back the terminal", and
    /// a guard that returned early made it a no-op. Nothing else here runs twice — the
    /// write and the persist are still behind the change check.
    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.workspaceID == id }) else { return }
        if selectedID != id {
            selectedID = id
            persist()
        }
        selected?.reclaimKeyboardFocus()
        // Going to a session is how its finished-agent badge is dismissed. `done` and
        // `failed` are sticky precisely so a completion is not shown for the one second it
        // takes the next poll to arrive — which means something has to put them away, and
        // "the user went and looked" is the only honest something available.
        AgentMonitor.shared.acknowledge(session: id)
    }

    /// Wraps, for the same reason the editor's list does: stopping at the end just means
    /// pressing the other shortcut to get anywhere.
    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.workspaceID == selectedID })
        else { return }
        select(sessions[(current + offset + sessions.count) % sessions.count].workspaceID)
    }

    // MARK: - Ordering

    /// Where the selected session sits in the list, or nil when nothing is selected.
    private var selectedIndex: Int? {
        sessions.firstIndex { $0.workspaceID == selectedID }
    }

    /// Reorder the list.
    ///
    /// Persisting is the whole of the work, and cheaply: the saved form of a window's
    /// sessions is an ORDERED list of directories, and `restoreSaved` reopens them in the
    /// order it reads. So the sidebar's order has always been the stored order — until now
    /// nothing could change it except the order projects happened to be opened in.
    ///
    /// Selection is untouched. Dragging a row is a statement about where a session belongs
    /// in the list, not a request to go there, and a drag that stole the canvas would make
    /// tidying the sidebar something you cannot do while working in one project.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    /// Whether the selected session can move a row in this direction.
    ///
    /// Drives the menu items' enabled state, so Move Up on the top row DIMS rather than
    /// beeping — a command that cannot run says so, per the `keyboard-first` rules.
    func canMoveSelected(by offset: Int) -> Bool {
        guard let selectedIndex else { return false }
        return sessions.indices.contains(selectedIndex + offset)
    }

    /// The keyboard half of the drag. A drag-only reorder is the anti-pattern this app is
    /// written against: the sidebar is navigation, and navigation a terminal user cannot
    /// rearrange from the keys is navigation they will not rearrange.
    func moveSelected(by offset: Int) {
        guard canMoveSelected(by: offset), let selectedIndex else { return }
        sessions.swapAt(selectedIndex, selectedIndex + offset)
        persist()
    }

    // MARK: - Closing

    /// Whether a session can be closed. The last one cannot — the same rule a pane follows,
    /// and for the same reason: there is nothing to fall back to, and a window with no canvas
    /// is a window with nothing in it. ⌘⇧W still closes the window.
    var canCloseSelected: Bool { sessions.count > 1 }

    /// Ask before closing: the window puts up its "Close this session?" for this one.
    func askToClose(_ id: UUID) {
        guard canCloseSelected else { NSSound.beep(); return }
        ui?.closingSessionID = id
    }

    func close(_ id: UUID) {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.workspaceID == id }) else {
            NSSound.beep()
            return
        }
        let store = sessions.remove(at: index)
        // Everything this session owned: its history saved, its PTYs stopped, its socket
        // closed, its Registry entries dropped. A closed session that left its shells running
        // would be a window quietly holding processes nobody can reach.
        ShellWorkspace.tearDown(store)
        if selectedID == id {
            selectedID = sessions[max(0, index - 1)].workspaceID
            // ⌘W on a project's last pane closes it from the keyboard, and the keyboard
            // has to land somewhere: in the session that takes its place.
            selected?.reclaimKeyboardFocus()
        }
        persist()
    }

    // MARK: - Persistence

    /// The window's sessions, as an ordered list of project folders.
    ///
    /// The LIST is all that is stored here — each session's own layout is already a document
    /// saved by `WorkspaceStorage` under its directory, and duplicating it would give the two
    /// a way to disagree.
    private static let directoriesKey = "sessions.directories"
    private static let selectedKey = "sessions.selected"

    private func persist() {
        let paths = sessions.compactMap(\.workspaceDirectory)
        Preferences.store.set(paths, forKey: Self.directoriesKey)
        Preferences.store.set(selected?.workspaceDirectory, forKey: Self.selectedKey)
    }

    /// The sessions a window should reopen with, or nil when there is nothing saved.
    static var saved: (directories: [String], selected: String?)? {
        let paths = Preferences.store.stringArray(forKey: directoriesKey) ?? []
        guard !paths.isEmpty else { return nil }
        return (paths, Preferences.store.string(forKey: selectedKey))
    }

    /// Reopen what the last run had, dropping any project that has since been moved away.
    ///
    /// Silently, and deliberately: a folder that no longer exists is a session that cannot be
    /// restored, and a window that opens with an error for each one is a window nobody can
    /// use until they have dismissed them all.
    func restoreSaved() -> Bool {
        guard let saved = Self.saved else { return false }
        let exists = { FileManager.default.fileExists(atPath: $0) }
        for path in saved.directories where exists(path) {
            _ = open(directory: path)
        }
        if let wanted = saved.selected,
           let match = sessions.first(where: { $0.workspaceDirectory == wanted }) {
            select(match.workspaceID)
        }
        return !sessions.isEmpty
    }
}
