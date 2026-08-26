import Testing
import Foundation
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTiles

/// A tile opens on the folder the shell beside it is in, and that is right until it isn't:
/// the repository is a sibling of the project, the interesting files are one level up. These
/// lock in the retarget: the pane keeps its id, its record follows what is on screen, and a
/// rebuild comes back on the chosen folder rather than on the one the tile was created with.
@Suite("Tile folders")
@MainActor
struct TileFolderTests {

    private func makeDirectories() throws -> (a: URL, b: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-folders-\(UUID().uuidString)")
        let a = base.appendingPathComponent("alpha")
        let b = base.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (a, b)
    }

    private func makeFactory(root: URL) -> TileFactory {
        TileFactory(context: TileContext(root: root))
    }

    @Test("a retargeted tile records the new folder, and says so in its header")
    func retargetUpdatesTheRecord() throws {
        let (a, b) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let factory = makeFactory(root: a)
        let pane = PaneID()

        factory.stage(.git)
        let built = try #require(factory.makeContent(for: pane))
        #expect(built.record.cwd == a.path)

        var announced: PaneRecord?
        factory.onRootChange = { _, record in announced = record }
        factory.retarget(pane, to: b)

        #expect(factory.root(of: pane)?.path == b.path)
        #expect(announced?.cwd == b.path, "the canvas is told, so the pane can be rebuilt")
        #expect(announced?.subtitle == "beta",
                "a Git tile's header names its repository — 'Git' alone leaves the user guessing")
    }

    @Test("rebuilding a retargeted tile reopens it on the folder that was chosen")
    func rebuildKeepsTheNewFolder() throws {
        let (a, b) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let factory = makeFactory(root: a)
        let pane = PaneID()

        factory.stage(.fileTree)
        _ = factory.makeContent(for: pane)
        factory.retarget(pane, to: b)

        // What the canvas does after a retarget: release the surface and ask for it again.
        factory.release(pane)
        let rebuilt = try #require(factory.makeContent(for: pane))
        #expect(rebuilt.record.cwd == b.path, "not back on the folder it was created with")
        #expect(rebuilt.record.kind == .fileTree, "and still the same kind of tile")
    }

    @Test("only tiles that mean something different elsewhere can be retargeted")
    func onlyFolderScopedTiles() throws {
        let (a, b) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let factory = makeFactory(root: a)

        for kind in TileFactory.supported {
            let pane = PaneID()
            factory.stage(kind)
            _ = factory.makeContent(for: pane)
            let scoped = TileFactory.folderScoped.contains(kind)
            #expect(factory.canRetarget(pane) == scoped, "\(kind) retargetable: \(scoped)")

            factory.retarget(pane, to: b)
            #expect(factory.root(of: pane)?.path == (scoped ? b.path : a.path),
                    // Ports and Resources attribute by process, Todo and Context keep their
                    // own store control — a folder verb on those would be a second answer.
                    "\(kind) must not move unless it is folder-scoped")
        }
    }

    @Test("retargeting a tile to where it already is changes nothing")
    func sameFolderIsNotAChange() throws {
        let (a, _) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let factory = makeFactory(root: a)
        let pane = PaneID()
        factory.stage(.git)
        _ = factory.makeContent(for: pane)

        var announcements = 0
        factory.onRootChange = { _, _ in announcements += 1 }
        factory.retarget(pane, to: a)
        #expect(announcements == 0, "no rebuild, so a Git tile does not blink on a no-op")
    }

    @Test("a pane the factory does not own cannot be moved")
    func unknownPane() throws {
        let (a, b) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let factory = makeFactory(root: a)
        let shell = PaneID()

        #expect(factory.canRetarget(shell) == false)
        factory.retarget(shell, to: b)
        #expect(factory.root(of: shell) == nil, "a shell changes folder by cd, not by menu")
    }
}
