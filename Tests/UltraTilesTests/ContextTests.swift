import Testing
import Foundation
@testable import UltraTiles

/// M6's acceptance criterion: a folder dropped from Finder, the app quit and relaunched,
/// still resolves and can be sent into a fresh shell — including after it has been MOVED,
/// which is what paths cannot survive and bookmarks can.
@Suite("Context")
@MainActor
struct ContextTests {

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("items survive a relaunch")
    func persistsAcrossRelaunch() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try String(repeating: "x", count: 4000).write(to: file, atomically: true, encoding: .utf8)

        let first = ContextModel(root: root)
        #expect(first.add(file))
        #expect(first.items.count == 1)

        // Quit and relaunch.
        let second = ContextModel(root: root)
        #expect(second.items.count == 1)
        #expect(second.items.first?.url.lastPathComponent == "notes.md")
        #expect(second.items.first?.isMissing == false)
    }

    @Test("a file MOVED between launches still resolves — the point of bookmarks")
    func survivesAMove() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("before.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)

        let first = ContextModel(root: root)
        #expect(first.add(original))

        // Renamed underneath us, exactly as a refactor would.
        let moved = root.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: moved)

        let second = ContextModel(root: root)
        let item = try #require(second.items.first)
        #expect(item.isMissing == false, "a recorded path would have gone missing here")
        #expect(item.url.lastPathComponent == "after.txt")
    }

    @Test("a genuinely deleted file is marked missing, not silently dropped")
    func missingIsVisible() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("gone.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let first = ContextModel(root: root)
        #expect(first.add(file))
        try FileManager.default.removeItem(at: file)

        let second = ContextModel(root: root)
        #expect(second.items.count == 1, "a shorter list would hide the problem")
        #expect(second.items.first?.isMissing == true)
        #expect(second.items.first?.name == "gone.txt")
    }

    @Test("the same file cannot be added twice")
    func noDuplicates() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let model = ContextModel(root: root)
        #expect(model.add(file))
        #expect(model.add(file) == false)
        #expect(model.items.count == 1)
    }

    @Test("pinned items survive Clear and sort first")
    func pinning() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            _ = ContextModel(root: root)
        }
        let model = ContextModel(root: root)
        for name in ["a.txt", "b.txt", "c.txt"] {
            model.add(root.appendingPathComponent(name))
        }
        let b = try #require(model.items.first { $0.name == "b.txt" })
        model.togglePin(b)
        #expect(model.items.first?.name == "b.txt", "pinned sorts first")
        model.removeAllUnpinned()
        #expect(model.items.map(\.name) == ["b.txt"])
    }

    @Test("references are @paths relative to the project root")
    func references() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("Main.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let model = ContextModel(root: root)
        model.add(file)
        #expect(model.referenceText(relativeTo: root) == "@Sources/Main.swift")
    }

    @Test("a path outside the root stays absolute rather than growing ../..")
    func outsideRoot() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ContextModel.relativePath(URL(fileURLWithPath: "/etc/hosts"), to: root)
                == "/etc/hosts")
    }

    @Test("token estimate scales with size and sums over a directory")
    func tokenEstimates() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "x", count: 4000)
            .write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 8000)
            .write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let single = ContextModel.estimateTokens(
            at: folder.appendingPathComponent("a.txt"), isDirectory: false)
        #expect(single == 1000, "bytes ÷ 4")
        let whole = ContextModel.estimateTokens(at: folder, isDirectory: true)
        #expect(whole == 3000, "a directory sums its files")
    }
}
