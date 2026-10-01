import Testing
import Foundation
@testable import UltraChat

/// The two engines, against recorded lines of their protocols: what Claude Code's
/// stream-json and Codex's notifications become, and what is sent to each.
@Suite("Engines")
struct EngineTests {

    private func text(of events: [ChatEvent]) -> String {
        events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    // MARK: - Claude Code

    @Test("the command line is the documented headless shape, with read-only tools")
    func claudeArguments() {
        let fresh = ClaudeCodeProvider.arguments(model: "default", system: "Be terse.",
                                                 session: "abc", resume: false)
        #expect(fresh.first == "-p")
        #expect(fresh.contains("stream-json"))
        #expect(fresh.contains("--include-partial-messages"))
        // The tools, and no more: nothing that writes, nothing that asks.
        let tools = fresh.firstIndex(of: "--tools")!
        #expect(Array(fresh[(tools + 1)...(tools + 3)]) == ["Read", "Glob", "Grep"])
        #expect(!fresh.contains("Bash") && !fresh.contains("Edit") && !fresh.contains("Write"))
        #expect(fresh.contains("--strict-mcp-config"))
        // The engine's default model is not named; a chosen one is.
        #expect(!fresh.contains("--model"))
        #expect(fresh.suffix(2) == ["--session-id", "abc"])
        let system = fresh.firstIndex(of: "--append-system-prompt")!
        #expect(fresh[system + 1] == "Be terse.")

        let resumed = ClaudeCodeProvider.arguments(model: "opus", system: nil, session: "abc", resume: true)
        #expect(resumed.suffix(2) == ["--resume", "abc"])
        let model = resumed.firstIndex(of: "--model")!
        #expect(resumed[model + 1] == "opus")
        #expect(!resumed.contains("--append-system-prompt"))
    }

    @Test("stream-json lines become text deltas, tool calls with results, and a finish")
    func claudeLines() throws {
        let lines = [
            #"{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":12}}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"look."}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/p/Package.swift"}}]}}"#,
            // The same message again, as the agent repeats it with every block.
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/p/Package.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"// swift-tools-version: 6.2"}]}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It is Swift 6.2."}}}"#,
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}}"#,
            "not json, a warning",
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"It is Swift 6.2.","usage":{"input_tokens":12,"output_tokens":9}}"#,
        ]
        var state = ClaudeCodeProvider.State()
        var events: [ChatEvent] = []
        for line in lines { events += try ClaudeCodeProvider.handle(line: line, state: &state) }

        #expect(text(of: events) == "Let me look.It is Swift 6.2.")
        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.map(\.id) == ["toolu_1"])
        #expect(calls.first?.name == "Read")
        #expect(calls.first?.string("file_path") == "/p/Package.swift")
        let results = events.compactMap { if case .toolResult(let id, let r) = $0 { (id, r) } else { nil } }
        #expect(results.count == 1)
        #expect(results.first?.0 == "toolu_1")
        #expect(results.first?.1 == "// swift-tools-version: 6.2")
        guard case .finished(let finish)? = events.last else {
            Issue.record("no finish")
            return
        }
        #expect(finish.reason == .complete)
        #expect(finish.inputTokens == 12)
        #expect(finish.outputTokens == 9)
        #expect(state.finished)
    }

    @Test("a result that is an error is thrown, and one about login names the sign-in")
    func claudeErrors() {
        #expect(throws: ChatError.http(status: 0, message: "Something broke")) {
            try ClaudeCodeProvider.handle(line: #"{"type":"result","is_error":true,"result":"Something broke"}"#)
        }
        #expect(throws: ChatError.notSignedIn(.claudeCode)) {
            try ClaudeCodeProvider.handle(line: #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#)
        }
    }

    @Test("a cut-off answer is a length finish")
    func claudeLength() throws {
        var state = ClaudeCodeProvider.State()
        _ = try ClaudeCodeProvider.handle(
            line: #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}}"#,
            state: &state)
        let events = try ClaudeCodeProvider.handle(line: #"{"type":"result","subtype":"success"}"#, state: &state)
        #expect(events == [.finished(ChatFinish(reason: .length))])
    }

    @Test("the account comes from `claude auth status`")
    func claudeAccount() {
        let signedIn = ChatEngine.claudeAccount(from: #"{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}"#)
        #expect(signedIn == EngineAccount(email: "a@b.c", plan: "max"))
        #expect(signedIn?.description == "a@b.c · Max")
        #expect(ChatEngine.claudeAccount(from: #"{"loggedIn":false}"#) == nil)
        #expect(ChatEngine.claudeAccount(from: "garbage") == nil)
    }

    // MARK: - Codex

    private func params(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("a turn's notifications become text, a command with its output, and a finish")
    func codexTurn() throws {
        var state = CodexProvider.TurnState()
        var events: [ChatEvent] = []
        let turn: [(String, String)] = [
            ("turn/started", #"{"threadId":"t","turn":{"id":"u","status":"inProgress"}}"#),
            ("item/started", #"{"threadId":"t","item":{"type":"reasoning","id":"r1","summary":[]}}"#),
            ("item/completed", #"{"threadId":"t","item":{"type":"reasoning","id":"r1","summary":[]}}"#),
            ("item/started", #"{"threadId":"t","item":{"type":"commandExecution","id":"c1","command":"git log -1","status":"inProgress"}}"#),
            ("item/completed", #"{"threadId":"t","item":{"type":"commandExecution","id":"c1","command":"git log -1","status":"completed","aggregatedOutput":"commit abc\n","exitCode":0}}"#),
            ("item/started", #"{"threadId":"t","item":{"type":"agentMessage","id":"m1","text":""}}"#),
            ("item/agentMessage/delta", #"{"threadId":"t","turnId":"u","itemId":"m1","delta":"The last "}"#),
            ("item/agentMessage/delta", #"{"threadId":"t","turnId":"u","itemId":"m1","delta":"commit"}"#),
            // The finished item carries the whole text; only the rest of it is new.
            ("item/completed", #"{"threadId":"t","item":{"type":"agentMessage","id":"m1","text":"The last commit is abc."}}"#),
            ("thread/tokenUsage/updated", #"{"threadId":"t","turnId":"u","tokenUsage":{"total":{"inputTokens":100,"outputTokens":30},"last":{"inputTokens":40,"outputTokens":10}}}"#),
            ("turn/completed", #"{"threadId":"t","turn":{"id":"u","status":"completed","error":null}}"#),
        ]
        for (method, json) in turn {
            events += try CodexProvider.handle(method: method, params: params(json), state: &state)
        }
        #expect(text(of: events) == "The last commit is abc.")
        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.map(\.name) == ["command"])
        #expect(calls.first?.string("command") == "git log -1")
        #expect(ProjectFiles.summary(of: calls[0]) == "Run git log -1")
        let results = events.compactMap { if case .toolResult(let id, let r) = $0 { (id, r) } else { nil } }
        #expect(results.first?.0 == "c1")
        #expect(results.first?.1 == "commit abc\n")
        #expect(events.last == .finished(ChatFinish(reason: .complete, inputTokens: 40, outputTokens: 10)))
        #expect(state.finished)
    }

    @Test("a message that never streamed arrives whole when its item completes")
    func codexWholeMessage() throws {
        let events = try CodexProvider.handle(
            method: "item/completed",
            params: params(#"{"threadId":"t","item":{"type":"agentMessage","id":"m1","text":"Four words, no deltas."}}"#))
        #expect(events == [.text("Four words, no deltas.")])
    }

    @Test("a failed turn is the server's message; an interrupted one is said in the finish")
    func codexEndings() throws {
        #expect(throws: ChatError.http(status: 0, message: "usage limit reached")) {
            try CodexProvider.handle(
                method: "turn/completed",
                params: params(#"{"threadId":"t","turn":{"id":"u","status":"failed","error":{"message":"usage limit reached"}}}"#))
        }
        let interrupted = try CodexProvider.handle(
            method: "turn/completed",
            params: params(#"{"threadId":"t","turn":{"id":"u","status":"interrupted"}}"#))
        #expect(interrupted == [.finished(ChatFinish(reason: .other, detail: "interrupted"))])
        // An error Codex will retry is its own business.
        #expect(try CodexProvider.handle(
            method: "error",
            params: params(#"{"threadId":"t","willRetry":true,"error":{"message":"transient"}}"#)) == [])
    }

    @Test("the model list is the engine's default, then what the picker would show")
    func codexModels() {
        let response = params(#"{"data":[{"id":"gpt-6","hidden":false,"isDefault":true},{"id":"gpt-6-mini","hidden":false},{"id":"codex-old","hidden":true}]}"#)
        #expect(CodexProvider.parseModels(response) == ["default", "gpt-6", "gpt-6-mini"])
    }

    // MARK: - Shared

    @Test("a lost conversation is replayed as one prompt, earlier turns first")
    func transcript() {
        let messages = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Hello."),
            ChatMessage(role: .assistant, text: ""),
            ChatMessage(role: .user, text: "Again?"),
        ]
        let prompt = ChatEngine.transcript(messages)
        #expect(prompt.hasPrefix("Earlier in this conversation:\n\nUser: Hi\n\nAssistant: Hello."))
        #expect(prompt.hasSuffix("Now the user says:\n\nAgain?"))
        // Nothing earlier: the question alone.
        #expect(ChatEngine.transcript([ChatMessage(role: .user, text: "Only")]) == "Only")
    }

    @Test("an engine's tool rows say what was read or run, without the whole path")
    func summaries() {
        #expect(ChatEngine.summary(of: ChatToolCall(id: "1", name: "Read", arguments: #"{"file_path":"/Users/x/Repo/app/Sources/A.swift"}"#))
                == "Read Sources/A.swift")
        #expect(ChatEngine.summary(of: ChatToolCall(id: "2", name: "Grep", arguments: #"{"pattern":"TODO"}"#))
                == "Search for “TODO”")
        #expect(ChatEngine.summary(of: ChatToolCall(id: "3", name: "something_else", arguments: "{}")) == nil)
    }

    @Test("the engine providers are offered, need no key, and default to the engine's own model")
    func offered() {
        #expect(ChatProviderID.offered.contains(.claudeCode))
        #expect(ChatProviderID.offered.contains(.codex))
        #expect(!ChatProviderID.claudeCode.requiresCredential)
        #expect(ChatProviderID.codex.isEngine)
        #expect(ChatProviderID.codex.engine == .codex)
        #expect(ChatProviderID.anthropic.engine == nil)
        #expect(ChatProviderID.claudeCode.defaultModel == ChatEngine.defaultModel)
    }
}
