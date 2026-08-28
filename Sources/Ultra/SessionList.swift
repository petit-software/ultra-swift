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

    init(storage: WorkspaceStorage) {
        self.storage = storage
    }

    /// A list built from stores that already exist.
    ///
    /// Previews and tests need one without `ShellWorkspace.make` spawning a real shell for
    /// every session — a preview that starts four PTYs is a preview nobody can leave open.
    init(storage: WorkspaceStorage, adopting stores: [LayoutStore]) {
        self.storage = storage
        self.sessions = stores
        self.selectedID = stores.first?.workspaceID
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
    @discardableResult
    func open(directory: String, restore: Bool = true) -> LayoutStore {
        let wanted = WorkspaceDocument.canonical(directory)
        if let existing = sessions.first(where: {
            $0.workspaceDirectory.map(WorkspaceDocument.canonical) == wanted
        }) {
            select(existing.workspaceID)
            return existing
        }
        let store = ShellWorkspace.make(storage: storage, directory: directory, restore: restore)
        sessions.append(store)
        select(store.workspaceID)
        RecentProjects.remember(directory)
        persist()
        return store
    }

    func select(_ id: UUID) {
        guard selectedID != id, sessions.contains(where: { $0.workspaceID == id }) else { return }
        selectedID = id
        persist()
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

    // MARK: - Closing

    /// Whether a session can be closed. The last one cannot — the same rule a pane follows,
    /// and for the same reason: there is nothing to fall back to, and a window with no canvas
    /// is a window with nothing in it. ⌘⇧W still closes the window.
    var canCloseSelected: Bool { sessions.count > 1 }

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
