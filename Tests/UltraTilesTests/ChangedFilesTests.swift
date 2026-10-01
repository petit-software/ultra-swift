import Foundation
import Testing
@testable import UltraChat
@testable import UltraTiles

/// The table of what an answer changed: one row per file, added up, in the order touched.
@Suite("Changed files")
struct ChangedFilesTests {

    @Test("every file once, in the order first touched, with its edits added up")
    func rows() {
        let calls = [
            ChatToolCall(id: "r", name: "Read", arguments: "{}", result: "…"),
            ChatToolCall(id: "a", name: "Edit", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/A.swift", additions: 2, deletions: 1)]),
            ChatToolCall(id: "b", name: "edit", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/B.swift", additions: 5),
                                   ChatFileChange(path: "/p/A.swift", additions: 1, deletions: 1)]),
            ChatToolCall(id: "c", name: "Edit", arguments: "{}", result: nil,
                         changes: [ChatFileChange(path: "/p/B.swift")]),
        ]
        let rows = ChangedFile.rows(in: calls)
        #expect(rows.map(\.path) == ["/p/A.swift", "/p/B.swift"])
        #expect(rows[0].additions == 3 && rows[0].deletions == 2 && rows[0].isSettled)
        #expect(rows[1].additions == 5 && rows[1].deletions == 0 && !rows[1].isSettled)
        #expect(ChangedFile.firstEdit(in: calls) == "a")
    }

    @Test("an edit that failed, and a read, make no row")
    func nothingChanged() {
        let calls = [
            ChatToolCall(id: "r", name: "Read", arguments: "{}", result: "…"),
            ChatToolCall(id: "a", name: "Edit", arguments: "{}", result: "not found", changes: []),
        ]
        #expect(ChangedFile.rows(in: calls).isEmpty)
        #expect(ChangedFile.firstEdit(in: calls) == nil)
    }

    @Test("the name is the file's, and the folder is from the project down")
    func naming() {
        let root = URL(fileURLWithPath: "/Users/me/Project")
        let inside = ChangedFile(path: "/Users/me/Project/Sources/App/View.swift", additions: 0, deletions: 0, isSettled: true)
        #expect(inside.name == "View.swift")
        #expect(inside.folder(under: root) == "Sources/App")
        let atRoot = ChangedFile(path: "/Users/me/Project/Package.swift", additions: 0, deletions: 0, isSettled: true)
        #expect(atRoot.folder(under: root) == "")
        let relative = ChangedFile(path: "docs/README.md", additions: 0, deletions: 0, isSettled: true)
        #expect(relative.url(under: root).path == "/Users/me/Project/docs/README.md")
        #expect(relative.folder(under: root) == "docs")
        let outside = ChangedFile(path: NSHomeDirectory() + "/Other/a.txt", additions: 0, deletions: 0, isSettled: true)
        #expect(outside.folder(under: root) == "~/Other")
    }
}
