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
