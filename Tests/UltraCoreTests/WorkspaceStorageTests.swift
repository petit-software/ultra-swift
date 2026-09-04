import Testing
import Foundation
import CoreGraphics
@testable import UltraCore
@testable import UltraLayout

@MainActor
private func makeDocument(_ fixture: LayoutTree.Fixture = .grid2x2) -> WorkspaceDocument {
    let tree = LayoutTree.fixture(fixture)
    let panes = Dictionary(uniqueKeysWithValues: tree.paneIDs.enumerated().map { index, id in
        (id, PaneRecord(kind: .shell, title: "Pane \(index + 1)",
                        subtitle: "~/Repo/ultra-swift", cwd: "/Users/x/Repo"))
    })
    return WorkspaceDocument(title: "ultra-swift", subtitle: "~/Repo/ultra-swift",
                             tree: tree, panes: panes,
                             windowFrame: CGRect(x: 100, y: 120, width: 1200, height: 780))
}

private func temporaryStorage(debounceMS: Int = 20) -> WorkspaceStorage {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ultra-tests-\(UUID().uuidString)")
    return WorkspaceStorage(directory: directory, debounce: .milliseconds(debounceMS))
}

@Suite("Workspace persistence")
struct WorkspaceStorageTests {

    @Test("a workspace round-trips through disk unchanged", arguments: LayoutTree.Fixture.allCases)
    @MainActor
    func roundTrip(fixture: LayoutTree.Fixture) throws {
        let storage = temporaryStorage()
        let document = makeDocument(fixture)
        try storage.saveNow(document)

        let restored = try #require(storage.load(document.id))
        #expect(restored.tree == document.tree)
        #expect(restored.panes == document.panes)
        #expect(restored.windowFrame == document.windowFrame)
        #expect(restored.title == document.title)
    }

    @Test("restoring preserves fractions exactly, so a window reopens pixel-identical")
    @MainActor
    func fractionsSurvive() throws {
        let storage = temporaryStorage()
        var document = makeDocument(.sidebarMain)
        // A deliberately awkward split that a naive encoder would round.
        document.tree.resize(divider: DividerRef(containerID: document.tree.root.id, index: 0),
                             by: 137, containerSize: 1184, minPaneSize: 160)
        try storage.saveNow(document)

        let restored = try #require(storage.load(document.id))
        let before = document.tree.root.asContainer!.fractions
        let after = restored.tree.root.asContainer!.fractions
        for (a, b) in zip(before, after) { #expect(a == b) }

        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(layout(restored.tree, in: bounds).frames == layout(document.tree, in: bounds).frames)
    }

    @Test("a document with a pane missing its record is refused, not half-restored")
    @MainActor
    func refusesInconsistent() throws {
        let storage = temporaryStorage()
        var document = makeDocument(.twoAcross)
        document.panes.removeValue(forKey: document.tree.paneIDs[0].uuidString)
        #expect(!document.isConsistent)
        #expect(throws: WorkspaceError.self) { try storage.saveNow(document) }
    }

    @Test("records for panes no longer in the tree are dropped")
    @MainActor
    func reconcileDropsStaleRecords() {
        var document = makeDocument(.grid2x2)
        document.setRecord(PaneRecord(kind: .ports, title: "ghost"), for: PaneID())
        #expect(document.panes.count == 5)
        document.reconcile()
        #expect(document.panes.count == 4)
        #expect(document.isConsistent)
    }

    @Test("an unreadable file is quarantined, not deleted, and load returns nil")
    @MainActor
    func corruptFileIsQuarantined() throws {
        let storage = temporaryStorage()
        let document = makeDocument(.single)
        try storage.saveNow(document)
        try Data("{ not json".utf8).write(to: storage.url(for: document.id))

        #expect(storage.load(document.id) == nil, "a corrupt file must not become the layout")
        #expect(!FileManager.default.fileExists(atPath: storage.url(for: document.id).path))

        let salvage = try FileManager.default
            .contentsOfDirectory(atPath: storage.directory.path)
            .filter { $0.contains("corrupt") }
        #expect(salvage.count == 1, "the user's file must still be on disk somewhere")
    }

    @Test("a future schema version is refused rather than guessed at")
    @MainActor
    func futureVersionRefused() throws {
        var document = makeDocument(.single)
        document.version = WorkspaceDocument.currentVersion + 1
        #expect(throws: WorkspaceError.self) { try WorkspaceMigration.migrate(document) }
    }

    @Test("repeated saves collapse to one write")
    @MainActor
    func debounced() throws {
        let storage = temporaryStorage(debounceMS: 60)
        let document = makeDocument(.twoAcross)
        for _ in 0..<25 { storage.scheduleSave(document) }
        #expect(storage.load(document.id) == nil, "nothing should be written yet")

        storage.flush()
        #expect(storage.load(document.id) != nil, "flush must not lose the last change")
    }

    @Test("loadAll finds every saved workspace and skips the corrupt one")
    @MainActor
    func loadAll() throws {
        let storage = temporaryStorage()
        let good = [makeDocument(.single), makeDocument(.twoAcross), makeDocument(.grid2x2)]
        for document in good { try storage.saveNow(document) }
        let bad = makeDocument(.deepNest)
        try storage.saveNow(bad)
        try Data("garbage".utf8).write(to: storage.url(for: bad.id))

        let loaded = storage.loadAll()
        #expect(loaded.count == 3)
        #expect(Set(loaded.map(\.id)) == Set(good.map(\.id)))
    }
}

/// The default layout sits beside the project documents under a name that is not a UUID.
/// It must round-trip, and it must never be mistaken for a project.
@Suite("Default layout")
struct DefaultLayoutTests {

    @Test("a default layout round-trips and is not listed as a project")
    @MainActor
    func roundTripsAndStaysOutOfTheList() throws {
        let storage = temporaryStorage()
        #expect(!storage.hasDefaultLayout)
        #expect(storage.loadDefaultLayout() == nil)

        let document = makeDocument(.grid2x2)
        try storage.saveDefaultLayout(document)
        #expect(storage.hasDefaultLayout)
        let restored = try #require(storage.loadDefaultLayout())
        #expect(restored.tree == document.tree)
        #expect(restored.panes == document.panes)
        #expect(storage.loadAll().isEmpty, "the default layout was listed as a project")
        #expect(storage.recentDirectories().isEmpty)

        storage.clearDefaultLayout()
        #expect(!storage.hasDefaultLayout)
    }

    @Test("a fresh project adopts the default layout's shape under its own directory")
    @MainActor
    func freshProjectAdoptsIt() throws {
        let storage = temporaryStorage()
        try storage.saveDefaultLayout(makeDocument(.threeAcross))
        let template = try #require(storage.loadDefaultLayout())
        let blank = WorkspaceDocument(directory: "/Users/x/Repo/other", title: "other",
                                      tree: LayoutTree(single: PaneID()), panes: [:])
        let adopted = blank.adoptingLayout(of: template)
        #expect(adopted.tree.paneCount == 3)
        #expect(adopted.directory == "/Users/x/Repo/other")
        #expect(adopted.isConsistent)
    }
}
