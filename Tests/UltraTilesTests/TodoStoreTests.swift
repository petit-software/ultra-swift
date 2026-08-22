import Testing
import Foundation
@testable import UltraTiles

/// M4's acceptance criterion, executable: an external edit is picked up, and toggling a
/// checkbox leaves the surrounding prose byte-identical on disk.
@Suite("Todo store")
@MainActor
struct TodoStoreTests {

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-todo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let prose = """
    # Notes

    Long-standing prose that no toggle may disturb.

    ## Doing

    - [ ] alpha
    - [x] beta

    Trailing thoughts.

    """

    @Test("a project with no list yet reports empty rather than creating a file")
    func noFileYet() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(root: root)
        #expect(store.exists == false)
        #expect(store.document.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path),
                "opening the tile must not write a file nobody asked for")
        #expect(store.url.path.hasSuffix(".ultra/todo.md"))
    }

    @Test("an existing TODO.md is adopted instead of starting a second list")
    func adoptsExistingList() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("TODO.md")
        try prose.write(to: existing, atomically: true, encoding: .utf8)
        let store = TodoStore(root: root)
        #expect(store.url == existing)
        #expect(store.document.items.count == 2)
    }

    @Test("toggling leaves every other byte on disk identical")
    func toggleIsByteExact() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("TODO.md")
        try prose.write(to: file, atomically: true, encoding: .utf8)

        let store = TodoStore(root: root)
        let alpha = try #require(store.document.items.first { $0.text == "alpha" })
        store.toggle(alpha.id)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk.count == prose.count)
        let differing = zip(Array(prose), Array(onDisk)).filter { $0 != $1 }
        #expect(differing.count == 1)
        #expect(onDisk.contains("Long-standing prose that no toggle may disturb."))
        #expect(onDisk.contains("Trailing thoughts."))
        #expect(onDisk.contains("- [x] alpha"))
    }

    @Test("an external edit is picked up and announced")
    func externalEdit() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("TODO.md")
        try prose.write(to: file, atomically: true, encoding: .utf8)
        let store = TodoStore(root: root)
        #expect(store.notice == nil)

        // Someone else edits the file — an editor, or the agent in the next pane.
        try prose.replacingOccurrences(of: "- [ ] alpha", with: "- [ ] alpha\n- [ ] gamma")
            .write(to: file, atomically: true, encoding: .utf8)
        store.reloadNow()

        #expect(store.document.items.map(\.text) == ["alpha", "gamma", "beta"])
        #expect(store.notice == .reloadedFromDisk)
    }

    @Test("our own write does not read back as an external change")
    func ownWriteIsNotAConflict() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("TODO.md")
        try prose.write(to: file, atomically: true, encoding: .utf8)
        let store = TodoStore(root: root)
        let beta = try #require(store.document.items.first { $0.text == "beta" })
        store.toggle(beta.id)
        store.reloadNow()
        #expect(store.notice == nil, "the echo of our own save must not raise a notice")
    }

    @Test("adding a task writes through and lands in the right section")
    func addWritesThrough() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("TODO.md")
        try prose.write(to: file, atomically: true, encoding: .utf8)
        let store = TodoStore(root: root)
        store.addItem("delta", to: "Doing")

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk.contains("- [ ] delta"))
        #expect(onDisk.contains("Trailing thoughts."))
        let reopened = TodoStore(root: root)
        #expect(reopened.document.items.map(\.text) == ["alpha", "beta", "delta"])
    }

    @Test("blank input is not a task")
    func ignoresBlankAdds() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(root: root)
        store.addItem("   \n  ")
        #expect(store.document.items.isEmpty)
        #expect(store.exists == false)
    }
}

/// A todo list is a file in a project, so where it lives is the user's call — one repo keeps
/// it at docs/TODO.md, another outside the tree entirely.
@Suite("Todo location")
@MainActor
struct TodoLocationTests {

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a chosen location is used, and survives reopening the tile")
    func relocatePersists() throws {
        let root = try makeProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: TodoStore.defaultsKey(for: root))
        }
        let chosen = root.appendingPathComponent("docs/PLAN.md")
        try FileManager.default.createDirectory(at: chosen.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "- [ ] from the chosen file\n".write(to: chosen, atomically: true, encoding: .utf8)

        let store = TodoStore(root: root)
        #expect(store.url.path.hasSuffix(".ultra/todo.md"))
        store.relocate(to: chosen)
        #expect(store.url == chosen)
        #expect(store.document.items.map(\.text) == ["from the chosen file"])

        // Closing and reopening the pane must not forget the choice.
        let reopened = TodoStore(root: root)
        #expect(reopened.url == chosen)
        #expect(reopened.document.items.count == 1)
    }

    @Test("edits after relocating write to the NEW file, not the old one")
    func writesToTheChosenFile() throws {
        let root = try makeProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: TodoStore.defaultsKey(for: root))
        }
        let chosen = root.appendingPathComponent("NOTES.md")
        try "- [ ] a\n".write(to: chosen, atomically: true, encoding: .utf8)

        let store = TodoStore(root: root)
        store.relocate(to: chosen)
        store.addItem("b")

        #expect(try String(contentsOf: chosen, encoding: .utf8).contains("- [ ] b"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".ultra/todo.md").path),
                "the default location must not be written to once a choice is made")
    }

    @Test("resetting goes back to the project default")
    func reset() throws {
        let root = try makeProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: TodoStore.defaultsKey(for: root))
        }
        let chosen = root.appendingPathComponent("ELSEWHERE.md")
        try "- [ ] x\n".write(to: chosen, atomically: true, encoding: .utf8)
        let store = TodoStore(root: root)
        store.relocate(to: chosen)
        store.resetLocation()
        #expect(store.url.path.hasSuffix(".ultra/todo.md"))
    }
}
