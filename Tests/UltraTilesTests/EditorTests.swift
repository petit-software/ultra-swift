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

    // MARK: New files

    private func makeFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a new file has no path, is clean while empty, and cannot be saved in place")
    func untitled() {
        let document = EditorDocument(untitled: "Untitled 2")
        #expect(document.isUntitled)
        #expect(document.displayName == "Untitled 2")
        #expect(document.isDirty == false, "an empty new file has nothing to lose")
        document.text = "notes"
        #expect(document.isDirty)
        #expect(document.save() == false, "there is nowhere to save it until it is told where")
        #expect(document.isDirty, "a save that went nowhere must not claim the text is safe")
    }

    @Test("the first save writes the file, makes its folder, and becomes that file")
    func firstSave() throws {
        let project = try makeFolder()
        defer { try? FileManager.default.removeItem(at: project) }
        // A project opened rather than created here has no `.ultra/` yet.
        let target = EditorDocument.defaultFolder(in: project).appendingPathComponent("plan.md")
        let document = EditorDocument(untitled: "Untitled")
        document.text = "# Plan\n"

        #expect(document.save(to: target))
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Plan\n")
        #expect(document.isUntitled == false)
        #expect(document.displayName == "plan.md")
        #expect(document.isDirty == false)

        // From here on it is an ordinary file: ⌘S goes back to the same place.
        document.text = "# Plan\n\n- one\n"
        #expect(document.save())
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Plan\n\n- one\n")
    }

    @Test("a first save that fails leaves the file new and the text dirty")
    func firstSaveFails() throws {
        let project = try makeFolder()
        defer { try? FileManager.default.removeItem(at: project) }
        // A FILE where the folder should be, so the folder cannot be made.
        let blocker = project.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let document = EditorDocument(untitled: "Untitled")
        document.text = "keep me"

        #expect(document.save(to: blocker.appendingPathComponent("note.md")) == false)
        #expect(document.isUntitled, "it must not claim a path nothing was written to")
        #expect(document.isDirty)
        #expect(document.text == "keep me")
        if case .failed = document.notice {} else { Issue.record("the failure was not reported") }
    }

    @Test("a new file is offered the project's .ultra folder and a name that is free")
    func defaultLocation() throws {
        let project = try makeFolder()
        defer { try? FileManager.default.removeItem(at: project) }
        let folder = EditorDocument.defaultFolder(in: project)
        #expect(folder.path == project.appendingPathComponent(".ultra").path)

        #expect(EditorDocument.suggestedName(in: folder) == "untitled.md", "a missing folder is an empty one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "".write(to: folder.appendingPathComponent("untitled.md"), atomically: true, encoding: .utf8)
        #expect(EditorDocument.suggestedName(in: folder) == "untitled-2.md")
        try "".write(to: folder.appendingPathComponent("untitled-2.md"), atomically: true, encoding: .utf8)
        #expect(EditorDocument.suggestedName(in: folder) == "untitled-3.md")
    }

    @Test("a new file asks for the keyboard once")
    func initialFocus() throws {
        let document = EditorDocument(untitled: "Untitled")
        #expect(document.claimInitialFocus())
        #expect(document.claimInitialFocus() == false, "a rebuilt view must not take the keyboard back")

        let url = try makeFile("existing")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EditorDocument(url: url).claimInitialFocus() == false)
    }
}
