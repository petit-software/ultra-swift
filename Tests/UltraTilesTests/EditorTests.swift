import Testing
import Foundation
@testable import UltraTiles

/// The editor's job is small, so what matters is that it never loses work: the dirty flag
/// has to be honest, and an external change must not silently overwrite either side.
@Suite("Editor")
@MainActor
struct EditorTests {

    private func makeFile(_ contents: String, ext: String = "txt") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-edit-\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("opening loads the file and starts clean")
    func opening() throws {
        let url = try makeFile("hello\nworld\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.text == "hello\nworld\n")
        #expect(document.isDirty == false)
        #expect(document.displayName == url.lastPathComponent)
    }

    @Test("the dirty flag tracks the difference from disk, both ways")
    func dirtyTracking() throws {
        let url = try makeFile("one")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.text = "two"
        #expect(document.isDirty)
        // Typing back to what is on disk is not a change.
        document.text = "one"
        #expect(document.isDirty == false, "undoing back to the saved text clears the flag")
    }

    @Test("saving writes through and clears dirty")
    func saving() throws {
        let url = try makeFile("before")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.text = "after"
        #expect(document.save())
        #expect(document.isDirty == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after")
    }

    @Test("an external change with no local edits reloads")
    func externalReload() throws {
        let url = try makeFile("first")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        try "second".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()
        #expect(document.text == "second")
        #expect(document.notice == .reloadedFromDisk)
        #expect(document.isDirty == false)
    }

    @Test("an external change WITH local edits keeps both and says so")
    func conflict() throws {
        let url = try makeFile("first")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.text = "mine"
        try "theirs".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()

        #expect(document.notice == .conflict)
        #expect(document.text == "mine", "the buffer must not be overwritten")
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs",
                "and neither must the file")
    }

    @Test("our own save does not read back as an external change")
    func ownWriteIsNotAConflict() throws {
        let url = try makeFile("x")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.text = "y"
        #expect(document.save())
        document.externalChange()
        #expect(document.notice == nil)
    }

    @Test("a binary file is refused rather than shown as garbage")
    func binaryFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-edit-\(UUID().uuidString).bin")
        try Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01, 0x02, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.isBinary)
        #expect(document.save() == false, "saving must not be able to corrupt it")
    }

    @Test("reverting drops local edits and nothing else")
    func revert() throws {
        let url = try makeFile("saved")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.text = "scratch"
        document.revert()
        #expect(document.text == "saved")
        #expect(document.isDirty == false)
    }
}
