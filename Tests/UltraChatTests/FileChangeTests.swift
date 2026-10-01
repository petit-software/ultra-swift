import Testing
import Foundation
@testable import UltraChat

/// What an edit changed, counted: from the texts a Claude Code edit swaps, and from the
/// diff a Codex edit reports.
@Suite("File changes")
struct FileChangeTests {

    @Test("lines in common are matched once; the rest are added or removed")
    func lineCounts() {
        let old = "a\nb\nc\n"
        let new = "a\nx\nc\nd\n"
        let counts = ChatFileChange.counts(from: old, to: new)
        #expect(counts.additions == 2)
        #expect(counts.deletions == 1)
        #expect(ChatFileChange.counts(from: "same\n", to: "same\n") == (0, 0))
        #expect(ChatFileChange.counts(from: "", to: "one\ntwo") == (2, 0))
        #expect(ChatFileChange.counts(from: "gone", to: "") == (0, 1))
        // A trailing newline is not an empty last line.
        #expect(ChatFileChange.lineCount("a\nb\n") == 2)
        #expect(ChatFileChange.lineCount("") == 0)
    }

    @Test("a unified diff is counted by its + and − lines, headers aside")
    func unifiedDiff() {
        let diff = """
        --- a/File.swift
        +++ b/File.swift
        @@ -1,3 +1,4 @@
         kept
        -old
        +new
        +more
         kept
        """
        #expect(ChatFileChange.counts(ofUnifiedDiff: diff) == (2, 1))
        #expect(ChatFileChange.counts(ofUnifiedDiff: "") == (0, 0))
    }

    @Test("a Claude Code edit is counted from its arguments; a read is not a change")
    func claudeEdits() {
        let edit = ChatToolCall(id: "1", name: "Edit", arguments: #"{"file_path":"/p/A.swift","old_string":"a\nb","new_string":"a\nc\nd"}"#)
        #expect(ChatEngine.fileChanges(of: edit) == [ChatFileChange(path: "/p/A.swift", additions: 2, deletions: 1)])
        let write = ChatToolCall(id: "2", name: "Write", arguments: #"{"file_path":"/p/B.md","content":"one\ntwo\n"}"#)
        #expect(ChatEngine.fileChanges(of: write) == [ChatFileChange(path: "/p/B.md", additions: 2, deletions: 0)])
        let multi = ChatToolCall(id: "3", name: "MultiEdit", arguments: #"{"file_path":"/p/C.swift","edits":[{"old_string":"x","new_string":"y"},{"old_string":"","new_string":"z\nw"}]}"#)
        #expect(ChatEngine.fileChanges(of: multi) == [ChatFileChange(path: "/p/C.swift", additions: 3, deletions: 1)])
        let read = ChatToolCall(id: "4", name: "Read", arguments: #"{"file_path":"/p/A.swift"}"#)
        #expect(ChatEngine.fileChanges(of: read) == nil)
    }

    @Test("the stream carries the count on the call, and takes it back when the edit failed")
    func claudeStream() throws {
        var state = ClaudeCodeProvider.State()
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/A.swift","old_string":"a","new_string":"b\nc"}}]}}"#
        let events = try ClaudeCodeProvider.handle(line: call, state: &state)
        guard case .toolCall(let made)? = events.first else {
            Issue.record("no call")
            return
        }
        #expect(made.changes == [ChatFileChange(path: "/p/A.swift", additions: 2, deletions: 1)])

        let ok = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"The file has been updated."}]}}"#
        #expect(try ClaudeCodeProvider.handle(line: ok, state: &state)
                == [.toolResult(id: "t1", result: "The file has been updated.")])
        let failed = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"String to replace not found."}]}}"#
        #expect(try ClaudeCodeProvider.handle(line: failed, state: &state)
                == [.toolResult(id: "t1", result: "String to replace not found.", changes: [])])
    }

    @Test("a Codex edit is named when it starts and counted when it completes")
    func codexEdit() throws {
        var state = CodexProvider.TurnState()
        let started = #"{"threadId":"t","item":{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"/p/A.swift","kind":"update","diff":""}]}}"#
        let start = try CodexProvider.handle(method: "item/started", params: params(started), state: &state)
        guard case .toolCall(let call)? = start.first else {
            Issue.record("no call")
            return
        }
        #expect(call.changes == [ChatFileChange(path: "/p/A.swift")])

        let diff = "--- a/A.swift\\n+++ b/A.swift\\n@@ -1 +1,2 @@\\n-old\\n+new\\n+more\\n"
        let completed = #"{"threadId":"t","item":{"type":"fileChange","id":"f1","status":"completed","changes":[{"path":"/p/A.swift","kind":"update","diff":"DIFF"}]}}"#
            .replacingOccurrences(of: "DIFF", with: diff)
        let done = try CodexProvider.handle(method: "item/completed", params: params(completed), state: &state)
        #expect(done == [.toolResult(id: "f1", result: "Changed /p/A.swift",
                                     changes: [ChatFileChange(path: "/p/A.swift", additions: 2, deletions: 1)])])

        let failed = completed.replacingOccurrences(of: "completed", with: "failed")
        #expect(try CodexProvider.handle(method: "item/completed", params: params(failed), state: &state)
                == [.toolResult(id: "f1", result: "Edit failed", changes: [])])
    }

    @Test("a call saved before changes were counted loads with none")
    func decodesWithoutChanges() throws {
        let json = #"{"id":"1","name":"Edit","arguments":"{}"}"#
        let call = try JSONDecoder().decode(ChatToolCall.self, from: Data(json.utf8))
        #expect(call.changes == nil)
        let counted = ChatToolCall(id: "2", name: "Edit", arguments: "{}", changes: [ChatFileChange(path: "x", additions: 1)])
        let back = try JSONDecoder().decode(ChatToolCall.self, from: JSONEncoder().encode(counted))
        #expect(back == counted)
    }

    private func params(_ json: String) -> [String: Any] {
        HTTPProviderSupport.object(Data(json.utf8)) ?? [:]
    }
}
