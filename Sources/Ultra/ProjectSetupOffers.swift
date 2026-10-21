import Foundation
import Observation
import UltraCanvas
import UltraCore

/// "Open ultra-swift's Ultra setup?" — asked when a shell in a scratch session walks into a
/// project Ultra already knows.
///
/// A scratch session (the belt's `+`, File ▸ New Shell Session) is on no project, so nothing
/// it does is saved and none of a project's panes come with it. Someone who opens one and
/// `cd`s into a project that has a layout is one step from the session they meant to open,
/// and nothing said so. This says so — once per folder per session, and only for a folder
/// that is a project: a `.ultra/` folder and a saved workspace (`WorkspaceStorage.hasSetup`).
///
/// Asked in a toast over the canvas rather than an alert. The question arrives while the
/// user is typing into a shell, and a modal there would take the next Return as its answer.
/// The keyboard path is File ▸ Open Ultra Setup, and Dismiss Notice says no.
@MainActor
@Observable
final class ProjectSetupOffers {
    static let shared = ProjectSetupOffers()

    /// The folder each scratch session is being offered, by workspace.
    private(set) var offers: [UUID: String] = [:]
    /// Folders a session was offered and turned down: not asked again in that session.
    private var declined: [UUID: Set<String>] = [:]

    /// The folder the session on this canvas — or the session a pane window belongs to —
    /// is being offered.
    func offer(for store: LayoutStore) -> String? { offers[store.session.workspaceID] }

    /// A shell in this canvas is now in `directory`.
    ///
    /// Moving on to a folder with nothing to offer withdraws the question: it was about
    /// where the shell WAS.
    func note(_ directory: String, in store: LayoutStore,
              storage: @autoclosure () -> WorkspaceStorage = WorkspaceStorage()) {
        let session = store.session
        guard session.workspaceDirectory == nil else { return }
        let id = session.workspaceID
        let folder = WorkspaceDocument.canonical(directory)
        guard offers[id] != folder else { return }
        if declined[id, default: []].contains(folder) || !storage().hasSetup(for: folder) {
            offers[id] = nil
        } else {
            offers[id] = folder
        }
    }

    /// Open the offered project as a session of its own, beside the scratch one. The
    /// scratch session stays: its shell may be running something, and closing it is a
    /// question of its own (⇧⌃⌘W).
    func accept(in store: LayoutStore) {
        let id = store.session.workspaceID
        guard let folder = offers.removeValue(forKey: id) else { return }
        declined[id, default: []].insert(folder)
        SessionList.holding(store.session)?.open(directory: folder)
    }

    func decline(in store: LayoutStore) {
        let id = store.session.workspaceID
        guard let folder = offers.removeValue(forKey: id) else { return }
        declined[id, default: []].insert(folder)
    }

    /// The session closed.
    func forget(_ workspaceID: UUID) {
        offers[workspaceID] = nil
        declined[workspaceID] = nil
    }

    /// The toast's question, in the folder's own name.
    static func question(for folder: String) -> String {
        "Open \((folder as NSString).lastPathComponent)'s Ultra setup?"
    }
}
