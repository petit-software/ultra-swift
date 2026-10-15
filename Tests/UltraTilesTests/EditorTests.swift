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

    @Test("a file opened before it exists becomes the file when it appears, even an empty one")
    func appearsLater() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-edit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.notice == .failed("Could not read \(url.lastPathComponent)"))

        try "".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()
        #expect(document.notice == nil)
        #expect(document.text == "")
        #expect(document.isDirty == false)

        // And it is watched from then on, like a file that was there to begin with.
        try "later".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()
        #expect(document.text == "later")
        #expect(document.notice == .reloadedFromDisk)
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

/// Pictures, films, sounds and PDFs open in the editor to be LOOKED at. What matters is
/// that they are told by type without being read as text, that nothing typed can be saved
/// over one, and that a file written again on disk is shown again — and only then.
@Suite("Editor media")
@MainActor
struct EditorMediaTests {

    private func scratch(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-media-\(UUID().uuidString)-\(name)")
    }

    /// Not a real PNG, on purpose: the type comes from the name, and the bytes are the
    /// view's business. That a NUL-free file still opens as a picture is the point.
    private func writeFile(_ name: String, _ bytes: String = "not really an image") throws -> URL {
        let url = scratch(name)
        try bytes.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("pictures, PDFs, films and sounds are media; text is not, and SVG is text", arguments: [
        ("shot.png", EditorMedia.image), ("photo.HEIC", .image), ("icon.icns", .image),
        ("paper.pdf", .pdf), ("clip.mov", .movie), ("clip.mp4", .movie),
        ("ding.aiff", .audio), ("song.mp3", .audio),
    ])
    func classifies(name: String, kind: EditorMedia) {
        #expect(EditorMedia.kind(of: URL(fileURLWithPath: "/p/\(name)")) == kind)
    }

    @Test("text, SVG and a file with no extension are not media", arguments: [
        "drawing.svg", "Package.swift", "notes.md", "data.json", "Makefile", "archive.zip",
    ])
    func notMedia(name: String) {
        #expect(EditorMedia.kind(of: URL(fileURLWithPath: "/p/\(name)")) == nil)
    }

    @Test("a picture opens as media, with no text, and cannot be saved over")
    func opensAsMedia() throws {
        let url = try writeFile("shot.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.media == .image)
        #expect(document.isBinary)
        #expect(document.text.isEmpty, "a picture is not read as text")
        #expect(document.notice == nil)
        document.text = "typed"
        #expect(document.save() == false, "nothing typed may be written over a picture")
        #expect(try String(contentsOf: url, encoding: .utf8) == "not really an image")
    }

    @Test("an SVG opens as text, to be edited")
    func svgIsText() throws {
        let url = try writeFile("drawing.svg", "<svg/>")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.media == nil)
        #expect(document.text == "<svg/>")
    }

    @Test("a picture written again is shown again; a file beside it changing is not")
    func reloadsOnlyOnItsOwnChange() throws {
        let url = try writeFile("shot.png", "one")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.mediaRevision == 0)

        // The folder watch fires for a sibling too: nothing about this file moved.
        document.externalChange()
        #expect(document.mediaRevision == 0)

        try "a longer two".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()
        #expect(document.mediaRevision == 1)
        #expect(document.notice == nil, "a picture changing needs no toast; the picture is the news")
    }

    @Test("a picture opened before it exists becomes the picture when it appears")
    func appears() throws {
        let url = scratch("later.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.media == .image)
        #expect(document.isBinary, "binary even while missing, so nothing can be saved in its place")
        guard case .failed = document.notice else {
            Issue.record("a missing picture should say it could not be read")
            return
        }
        try "arrived".write(to: url, atomically: true, encoding: .utf8)
        document.externalChange()
        #expect(document.notice == nil)
        #expect(document.mediaRevision == 1)
    }

    @Test("a media tab wears its kind's icon")
    func tabSymbol() throws {
        let picture = try writeFile("shot.png")
        let text = try writeFile("notes.txt")
        defer {
            try? FileManager.default.removeItem(at: picture)
            try? FileManager.default.removeItem(at: text)
        }
        let sessions = EditorSessions()
        #expect(sessions.open(.file(picture)).symbol == "photo")
        #expect(sessions.open(.file(text)).symbol == "doc.text")
    }
}
