import Testing
import Foundation
@testable import UltraTiles

/// The tree reads one directory at a time and caches it. These lock in the two properties
/// that matter: a folder nobody opened is never read, and what you see is what is open.
@Suite("File tree")
@MainActor
struct FileTreeTests {

    /// A throwaway tree:
    ///   root/  a.txt  .hidden  sub/(b.txt deep/(c.txt))  empty/
    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-filetree-\(UUID().uuidString)")
        let fm = FileManager.default
        let deep = root.appendingPathComponent("sub/deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"),
                               withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "h".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: deep.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("only the root is read until a folder is opened")
    func lazyReading() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileTreeModel(root: root)
        // The root's own listing is loaded; nothing below it is.
        #expect(model.children[root] != nil)
        #expect(model.children[root.appendingPathComponent("sub")] == nil)
        #expect(model.rows.count == 3)          // a.txt, empty, sub — not .hidden

        let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
        model.toggle(sub)
        #expect(model.children[sub.url] != nil, "opening a folder reads exactly that folder")
        #expect(model.children[sub.url.appendingPathComponent("deep")] == nil,
                "opening a folder must not read its grandchildren")
    }

    @Test("directories sort before files, then by name")
    func ordering() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = FileTreeModel(root: root).rows.map(\.node.name)
        #expect(names == ["empty", "sub", "a.txt"])
    }

    @Test("dotfiles appear only when asked for")
    func hiddenFiles() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileTreeModel(root: root)
        #expect(!model.rows.contains { $0.node.name == ".hidden" })
        model.showsHidden = true
        #expect(model.rows.contains { $0.node.name == ".hidden" })
    }

    @Test("rows are exactly what is expanded, at the right depth")
    func visibleRows() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileTreeModel(root: root)
        let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
        model.expand(sub)
        let deep = try #require(model.rows.first { $0.node.name == "deep" }?.node)
        model.expand(deep)

        let rows = model.rows
        // sub holds deep/ and b.txt; deep sorts first, and c.txt nests under it.
        #expect(rows.map(\.node.name) == ["empty", "sub", "deep", "c.txt", "b.txt", "a.txt"])
        #expect(rows.first { $0.node.name == "deep" }?.depth == 1)
        #expect(rows.first { $0.node.name == "c.txt" }?.depth == 2)
    }

    @Test("collapsing a folder forgets its descendants' open state")
    func collapseForgetsDescendants() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileTreeModel(root: root)
        let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
        model.expand(sub)
        let deep = try #require(model.rows.first { $0.node.name == "deep" }?.node)
        model.expand(deep)
        model.collapse(sub)
        model.expand(sub)
        // Reopening `sub` must not explode straight back to `deep`'s contents.
        #expect(!model.rows.contains { $0.node.name == "c.txt" })
    }

    @Test("an unreadable directory is marked, not fatal")
    func unreadableDirectory() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }
        let model = FileTreeModel(root: root)
        let node = try #require(model.rows.first { $0.node.name == "locked" }?.node)
        model.expand(node)
        #expect(model.unreadable.contains(node.url))
        #expect(model.children[node.url] == [])
    }

    @Test("paths shown are relative to the root")
    func displayPath() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileTreeModel(root: root)
        #expect(model.displayPath(root.appendingPathComponent("sub/b.txt")) == "sub/b.txt")
    }

    @Test("a path with a space or a quote survives the trip to a prompt")
    func quoting() {
        #expect(shellQuoted("/tmp/my file.txt") == "'/tmp/my file.txt'")
        #expect(shellQuoted("/tmp/it's.txt") == "'/tmp/it'\\''s.txt'")
    }
}
