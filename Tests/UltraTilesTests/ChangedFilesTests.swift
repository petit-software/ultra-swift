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
        #expect(rows.allSatisfy { $0.kind == .modified })
    }

    @Test("a file is what the last change made it: deleted wins, new stays new, deleted-then-written is changed")
    func kinds() {
        let calls = [
            ChatToolCall(id: "a", name: "Write", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/New.swift", additions: 10, kind: .added)]),
            ChatToolCall(id: "b", name: "Edit", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/New.swift", additions: 1, deletions: 1)]),
            ChatToolCall(id: "c", name: "Edit", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/Old.swift", additions: 1)]),
            ChatToolCall(id: "d", name: "Bash", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/Old.swift", deletions: 7, kind: .deleted),
                                   ChatFileChange(path: "/p/Back.swift", deletions: 2, kind: .deleted)]),
            ChatToolCall(id: "e", name: "Write", arguments: "{}", result: "ok",
                         changes: [ChatFileChange(path: "/p/Back.swift", additions: 3, kind: .added)]),
        ]
        let rows = ChangedFile.rows(in: calls)
        #expect(rows.map(\.path) == ["/p/New.swift", "/p/Old.swift", "/p/Back.swift"])
        #expect(rows[0].kind == .added && rows[0].additions == 11)
        #expect(rows[1].kind == .deleted && rows[1].deletions == 7)
        #expect(rows[2].kind == .modified && rows[2].additions == 3 && rows[2].deletions == 2)
    }

    @Test("an answer's table is drawn under its last turn, with every turn's changes")
    func oneTablePerAnswer() {
        let edit = { (id: String, path: String) in
            ChatToolCall(id: id, name: "Edit", arguments: "{}", result: "ok", changes: [ChatFileChange(path: path, additions: 1)])
        }
        let messages = [
            ChatMessage(role: .user, text: "do it"),
            ChatMessage(role: .assistant, text: "first", toolCalls: [edit("1", "/p/A.swift")]),
            ChatMessage(role: .assistant, text: "then", toolCalls: [edit("2", "/p/B.swift"), edit("3", "/p/A.swift")]),
            ChatMessage(role: .assistant, text: "done"),
            ChatMessage(role: .user, text: "more"),
            ChatMessage(role: .assistant, text: "ok", toolCalls: [edit("4", "/p/C.swift")]),
        ]
        #expect(ChangedFile.answer(endingAt: 0, in: messages) == nil)
        #expect(ChangedFile.answer(endingAt: 1, in: messages) == nil)
        #expect(ChangedFile.answer(endingAt: 2, in: messages) == nil)
        let first = ChangedFile.answer(endingAt: 3, in: messages).map(ChangedFile.rows) ?? []
        #expect(first.map(\.path) == ["/p/A.swift", "/p/B.swift"])
        #expect(first[0].additions == 2)
        #expect(ChangedFile.answer(endingAt: 5, in: messages)?.map(\.id) == ["4"])
        #expect(ChangedFile.answer(endingAt: 6, in: messages) == nil)
    }

    @Test("an edit that failed, and a read, make no row")
    func nothingChanged() {
        let calls = [
            ChatToolCall(id: "r", name: "Read", arguments: "{}", result: "…"),
            ChatToolCall(id: "a", name: "Edit", arguments: "{}", result: "not found", changes: []),
        ]
        #expect(ChangedFile.rows(in: calls).isEmpty)
    }

    @Test("the name is the file's, and the folder is from the project down")
    func naming() {
        let root = URL(fileURLWithPath: "/Users/me/Project")
        let inside = ChangedFile(path: "/Users/me/Project/Sources/App/View.swift", additions: 0, deletions: 0, kind: .modified, isSettled: true)
        #expect(inside.name == "View.swift")
        #expect(inside.folder(under: root) == "Sources/App")
        let atRoot = ChangedFile(path: "/Users/me/Project/Package.swift", additions: 0, deletions: 0, kind: .modified, isSettled: true)
        #expect(atRoot.folder(under: root) == "")
        let relative = ChangedFile(path: "docs/README.md", additions: 0, deletions: 0, kind: .modified, isSettled: true)
        #expect(relative.url(under: root).path == "/Users/me/Project/docs/README.md")
        #expect(relative.folder(under: root) == "docs")
        let outside = ChangedFile(path: NSHomeDirectory() + "/Other/a.txt", additions: 0, deletions: 0, kind: .modified, isSettled: true)
        #expect(outside.folder(under: root) == "~/Other")
    }
}
