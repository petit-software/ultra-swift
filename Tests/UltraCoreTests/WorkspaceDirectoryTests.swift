import Testing
import Foundation
import CoreGraphics
@testable import UltraCore
@testable import UltraLayout

@MainActor
private func document(at directory: String?, title: String = "p") -> WorkspaceDocument {
    let tree = LayoutTree.fixture(.twoAcross)
    let panes = Dictionary(uniqueKeysWithValues: tree.paneIDs.map {
        ($0, PaneRecord(kind: .shell, title: title))
    })
    return WorkspaceDocument(directory: directory, title: title,
                             subtitle: directory, tree: tree, panes: panes)
}

private func temporaryStorage() -> WorkspaceStorage {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ultra-dir-tests-\(UUID().uuidString)")
    return WorkspaceStorage(directory: directory, debounce: .milliseconds(10))
}

/// A workspace is found by the project it belongs to. Before this, restore took
/// `loadAll().first` — "whichever document is on disk first" — which is indistinguishable
/// from correct until there are two projects, and then hands both of them the same layout.
@Suite("Workspace directories")
struct WorkspaceDirectoryTests {

    @Test("two projects keep two layouts, and each restores its own")
    @MainActor
    func twoProjectsDoNotShareALayout() throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: "/tmp/alpha", title: "alpha"))
        try storage.saveNow(document(at: "/tmp/beta", title: "beta"))

        #expect(storage.load(directory: "/tmp/alpha")?.title == "alpha")
        #expect(storage.load(directory: "/tmp/beta")?.title == "beta")
    }

    @Test("a project never opened has no workspace, rather than someone else's")
    @MainActor
    func unknownProjectIsNil() throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: "/tmp/alpha", title: "alpha"))
        #expect(storage.load(directory: "/tmp/never-opened") == nil)
    }

    /// The same project arrives spelled several ways — a trailing slash from a drag, `~`
    /// from a config, a symlink from `/tmp`. Each extra spelling would be another workspace
    /// with its own layout, and the user would watch their panes change depending on how
    /// they happened to open the folder.
    @Test("one project, however it is spelled", arguments: [
        "/tmp/alpha/", "/tmp/alpha//", "/tmp/./alpha",
    ])
    @MainActor
    func spellingsAgree(spelling: String) throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: "/tmp/alpha", title: "alpha"))
        #expect(storage.load(directory: spelling)?.title == "alpha")
    }

    @Test("a tilde path is the same project as its expansion")
    @MainActor
    func tildeExpands() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storage = temporaryStorage()
        try storage.saveNow(document(at: home, title: "home"))
        #expect(storage.load(directory: "~")?.title == "home")
    }

    /// A document with no directory is restorable but not findable. It must never be
    /// adopted by a project that simply asked first — that is the `loadAll().first` bug
    /// wearing a different hat.
    @Test("a document with no directory is matched by nothing")
    @MainActor
    func directorylessIsNeverMatched() throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: nil, title: "orphan"))
        #expect(storage.load(directory: "/tmp/alpha") == nil)
        #expect(storage.loadAll().count == 1, "still on disk, just not findable by path")
    }

    @Test("recents lists each project once, most recently written first")
    @MainActor
    func recentsAreOrderedAndUnique() throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: "/tmp/alpha", title: "alpha"))
        try storage.saveNow(document(at: "/tmp/beta", title: "beta"))
        let recents = storage.recentDirectories()
        #expect(Set(recents) == ["/tmp/alpha", "/tmp/beta"])
        #expect(recents.count == 2)
    }

    @Test("a document with no directory is left out of recents")
    @MainActor
    func recentsSkipDirectoryless() throws {
        let storage = temporaryStorage()
        try storage.saveNow(document(at: nil, title: "orphan"))
        #expect(storage.recentDirectories().isEmpty)
    }
}

/// v1 predates `directory`. Its subtitle was written as the abbreviated path, so the tilde
/// form can be expanded back — a recovery, not a guarantee.
@Suite("Workspace migration to v2")
struct WorkspaceMigrationV2Tests {

    @Test("a v1 document recovers its directory from its subtitle")
    @MainActor
    func v1RecoversDirectory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var old = document(at: nil, title: "old")
        old.version = 1
        old.subtitle = "~"

        let migrated = try WorkspaceMigration.migrate(old)
        #expect(migrated.version == WorkspaceDocument.currentVersion)
        #expect(migrated.directory == home)
    }

    /// A subtitle the user renamed, or one naming a folder since deleted, must not become a
    /// directory — a workspace claiming a project it does not belong to is worse than one
    /// claiming none.
    @Test("a v1 subtitle that is not a real path yields no directory")
    @MainActor
    func v1RefusesToGuess() throws {
        var old = document(at: nil, title: "old")
        old.version = 1
        old.subtitle = "My Project"

        #expect(try WorkspaceMigration.migrate(old).directory == nil)
    }

    @Test("a version from the future is refused, not guessed at")
    @MainActor
    func futureVersionRefused() {
        var future = document(at: "/tmp/alpha")
        future.version = WorkspaceDocument.currentVersion + 1
        #expect(throws: WorkspaceError.self) { try WorkspaceMigration.migrate(future) }
    }
}
