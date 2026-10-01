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

    /// The per-row send exists so a prompt can name ONE file out of a list gathered over a
    /// session. It has to speak the same `@path` the whole-list send does, or the two
    /// buttons in this tile would be typing two different things at the same prompt.
    @Test("one item's reference is the same @path the whole list would send")
    func singleReference() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["Main.swift", "Other.swift"] {
            try "x".write(to: nested.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
        }
        let model = ContextModel(root: root)
        model.add(nested.appendingPathComponent("Main.swift"))
        model.add(nested.appendingPathComponent("Other.swift"))
        let main = try #require(model.items.first { $0.name == "Main.swift" })
        #expect(ContextModel.reference(for: main, relativeTo: root) == "@Sources/Main.swift")
        #expect(model.referenceText(relativeTo: root)
                == "@Sources/Main.swift @Sources/Other.swift",
                "sending one file must not be a different spelling from sending the list")
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

    /// The card shows size and, for a folder, how many files — out of the SAME walk the
    /// token estimate makes, so a folder is not enumerated twice to say two things about it.
    @Test("one walk measures bytes, file count and tokens together")
    func measurement() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "x", count: 4000)
            .write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 8000)
            .write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let file = ContextModel.measure(at: folder.appendingPathComponent("a.txt"), isDirectory: false)
        #expect(file == .init(bytes: 4000, fileCount: nil))
        let whole = ContextModel.measure(at: folder, isDirectory: true)
        #expect(whole == .init(bytes: 12000, fileCount: 2))
        #expect(whole.tokens == 3000)

        let model = ContextModel(root: root)
        model.add(folder)
        model.add(folder.appendingPathComponent("b.txt"))
        let dir = try #require(model.items.first { $0.isDirectory })
        #expect(dir.bytes == 12000)
        #expect(dir.fileCount == 2)
        let b = try #require(model.items.first { $0.name == "b.txt" })
        #expect(b.bytes == 8000)
        #expect(b.fileCount == nil)
    }

    @Test("the kind is the extension in capitals, or Folder, or File")
    func kinds() {
        func item(_ path: String, directory: Bool = false) -> ContextModel.Item {
            ContextModel.Item(id: UUID(), url: URL(fileURLWithPath: path), isPinned: false,
                              tokens: 0, isDirectory: directory)
        }
        #expect(item("/p/notes.md").kind == "MD")
        #expect(item("/p/Main.swift").kind == "SWIFT")
        #expect(item("/p/Makefile").kind == "File")
        #expect(item("/p/Sources", directory: true).kind == "Folder")
    }

    /// The caption is the accessibility label and the picture's text in one, so it is
    /// pinned down here: kind, a folder's count, the size in Finder's units, the tokens.
    @Test("the caption reads kind · files · size · ~count, or just missing")
    func captions() {
        let file = ContextModel.Item(id: UUID(), url: URL(fileURLWithPath: "/p/notes.md"),
                                     isPinned: false, tokens: 1000, isDirectory: false, bytes: 4000)
        #expect(file.caption == "MD · 4 KB · ~1k")

        let folder = ContextModel.Item(id: UUID(), url: URL(fileURLWithPath: "/p/Sources"),
                                       isPinned: false, tokens: 25000, isDirectory: true,
                                       bytes: 100_000, fileCount: 12)
        #expect(folder.caption == "Folder · 12 files · 100 KB · ~25k")

        let one = ContextModel.Item(id: UUID(), url: URL(fileURLWithPath: "/p/One"),
                                    isPinned: false, tokens: 10, isDirectory: true,
                                    bytes: 40, fileCount: 1)
        #expect(one.caption == "Folder · 1 file · 40 bytes · ~10")

        let gone = ContextModel.Item(id: UUID(), url: URL(fileURLWithPath: "/p/gone.txt"),
                                     isPinned: false, tokens: 0, isDirectory: false, isMissing: true)
        #expect(gone.caption == "missing", "stale measurements of an absent file are not shown")
    }

    @Test("token counts compact to k above a thousand, without a trailing .0")
    func compactTokens() {
        #expect(ContextModel.Item.compact(999) == "999")
        #expect(ContextModel.Item.compact(1000) == "1k")
        #expect(ContextModel.Item.compact(1250) == "1.2k")
        #expect(ContextModel.Item.compact(25000) == "25k")
        #expect(ContextModel.Item.compact(123_456) == "123k")
    }
}
