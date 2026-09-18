import Testing
import Foundation
@testable import UltraChat

/// A transport that answers each request with the next recorded body: one per round of a
/// tool loop.
final class RoundsTransport: ChatTransport, @unchecked Sendable {
    var bodies: [String]
    var requests: [URLRequest] = []

    init(_ bodies: [String]) { self.bodies = bodies }

    func lines(for request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let lines = (bodies.isEmpty ? "" : bodies.removeFirst()).components(separatedBy: "\n")
        return (200, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    func data(for request: URLRequest) async throws -> (status: Int, data: Data) { (200, Data()) }

    func body(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

/// A toolbox that answers every call with the same line, and remembers the calls.
final class EchoToolbox: ChatToolbox, @unchecked Sendable {
    let tools = [ChatTool(name: "read_file", description: "Read a file.",
                          parameters: [.init("path", .string, "The file.", isRequired: true),
                                       .init("start_line", .integer, "First line.")])]
    var calls: [ChatToolCall] = []

    func run(_ call: ChatToolCall) async -> String {
        calls.append(call)
        return "contents of \(call.string("path") ?? "?")"
    }
}

private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private let question = [ChatMessage(role: .user, text: "What does the package build?")]

/// The events every provider should turn a two-round exchange into: the call, its result,
/// the answer, one finish.
private func expectOneRead(_ events: [ChatEvent], path: String = "Package.swift") {
    guard events.count == 4,
          case .toolCall(let call) = events[0],
          case .toolResult(let id, let result) = events[1],
          case .text(let text) = events[2],
          case .finished(let finish) = events[3] else {
        Issue.record("unexpected events: \(events)")
        return
    }
    #expect(call.name == "read_file")
    #expect(call.string("path") == path)
    #expect(id == call.id)
    #expect(result == "contents of \(path)")
    #expect(text == "A terminal.")
    #expect(finish.reason == .complete)
}

// MARK: - Schema and calls

@Suite("Chat tools")
struct ChatToolTests {

    @Test("a tool's parameters become JSON Schema, in capitals for Gemini")
    func schema() {
        let tool = EchoToolbox().tools[0]
        let schema = tool.schema()
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["path"])
        let properties = schema["properties"] as? [String: [String: String]]
        #expect(properties?["start_line"]?["type"] == "integer")
        #expect(tool.schema(uppercaseTypes: true)["type"] as? String == "OBJECT")
    }

    @Test("arguments are read leniently: integers as numbers, doubles or strings")
    func arguments() {
        let call = ChatToolCall(id: "1", name: "read_file",
                                arguments: #"{"path":" a.swift ","start_line":"12","line_count":5.0}"#)
        #expect(call.string("path") == "a.swift")
        #expect(call.integer("start_line") == 12)
        #expect(call.integer("line_count") == 5)
        #expect(ChatToolCall(id: "2", name: "x", arguments: "not json").string("path") == nil)
    }

    @Test("a message written before tools existed still decodes")
    func oldFiles() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"Hi","createdAt":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.toolCalls == nil)
        #expect(!message.isEmpty)
    }
}

// MARK: - Anthropic

@Suite("Anthropic tools")
struct AnthropicToolTests {

    static let callRound = """
    data: {"type":"message_start","message":{"usage":{"input_tokens":40}}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"Pack"}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"age.swift\\"}"}}

    data: {"type":"content_block_stop","index":1}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}

    data: {"type":"message_stop"}

    """

    static let answerRound = """
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A terminal."}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

    data: {"type":"message_stop"}

    """

    @Test("a tool call is run and the turn sent back whole, thinking and signature included")
    func loop() async throws {
        let transport = RoundsTransport([Self.callRound, Self.answerRound])
        let toolbox = EchoToolbox()
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(
            ChatRequest(model: "m", messages: question, toolbox: toolbox)))

        expectOneRead(events)
        #expect(toolbox.calls.count == 1)
        #expect(transport.requests.count == 2)

        let tools = transport.body(0)["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "read_file")
        #expect(tools?.first?["input_schema"] != nil)

        let messages = transport.body(1)["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        let turn = messages[1]["content"] as? [[String: Any]] ?? []
        #expect(turn.map { $0["type"] as? String } == ["thinking", "tool_use"])
        #expect(turn[0]["signature"] as? String == "sig==")
        #expect((turn[1]["input"] as? [String: Any])?["path"] as? String == "Package.swift")
        let results = messages[2]["content"] as? [[String: Any]] ?? []
        #expect(messages[2]["role"] as? String == "user")
        #expect(results.first?["tool_use_id"] as? String == "toolu_1")
        #expect(results.first?["content"] as? String == "contents of Package.swift")
    }

    @Test("without a toolbox no tools are offered and a call is not run")
    func noToolbox() async throws {
        let transport = RoundsTransport([Self.callRound])
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(ChatRequest(model: "m", messages: question)))
        #expect(transport.requests.count == 1)
        #expect(transport.body(0)["tools"] == nil)
        #expect(events == [.finished(ChatFinish(reason: .complete, inputTokens: 40, outputTokens: 30))])
    }

    @Test("a saved turn that called tools replays as tool_use, then every result in one user message")
    func replay() {
        let wire = AnthropicProvider.wireMessages([
            ChatMessage(role: .user, text: "Q"),
            ChatMessage(role: .assistant, text: "Looking.", toolCalls: [
                ChatToolCall(id: "a", name: "read_file", arguments: #"{"path":"x"}"#, result: "X"),
                ChatToolCall(id: "b", name: "read_file", arguments: #"{"path":"y"}"#),
            ]),
            ChatMessage(role: .assistant, text: ""),
            ChatMessage(role: .assistant, text: "Done."),
        ])
        #expect(wire.map { $0["role"] as? String } == ["user", "assistant", "user", "assistant"])
        let turn = wire[1]["content"] as? [[String: Any]] ?? []
        #expect(turn.map { $0["type"] as? String } == ["text", "tool_use", "tool_use"])
        let results = wire[2]["content"] as? [[String: Any]] ?? []
        #expect(results.map { $0["content"] as? String } == ["X", ChatToolCall.missingResult])
    }
}

// MARK: - OpenAI

@Suite("OpenAI tools")
struct OpenAIToolTests {

    static let callRound = """
    data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Package.swift\\"}"}}]}}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """

    static let answerRound = """
    data: {"choices":[{"delta":{"content":"A terminal."}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    @Test("a call arriving in fragments is assembled, run, and answered with a tool message")
    func loop() async throws {
        let transport = RoundsTransport([Self.callRound, Self.answerRound])
        let provider = OpenAIProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(
            ChatRequest(model: "m", system: "S", messages: question, toolbox: EchoToolbox())))

        expectOneRead(events)
        let tools = transport.body(0)["tools"] as? [[String: Any]]
        #expect((tools?.first?["function"] as? [String: Any])?["name"] as? String == "read_file")

        let messages = transport.body(1)["messages"] as? [[String: Any]] ?? []
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let calls = messages[2]["tool_calls"] as? [[String: Any]]
        #expect(calls?.first?["id"] as? String == "call_1")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == "contents of Package.swift")
    }
}

// MARK: - Gemini

@Suite("Gemini tools")
struct GeminiToolTests {

    static let callRound = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"read_file","args":{"path":"Package.swift"}},"thoughtSignature":"sig"}]},"finishReason":"STOP"}]}

    """

    static let answerRound = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"A terminal."}]},"finishReason":"STOP"}]}

    """

    @Test("a function call is run and goes back with its thought signature, then the response")
    func loop() async throws {
        let transport = RoundsTransport([Self.callRound, Self.answerRound])
        let provider = GeminiProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(
            ChatRequest(model: "m", messages: question, toolbox: EchoToolbox())))

        expectOneRead(events)
        let tools = transport.body(0)["tools"] as? [[String: Any]]
        let declarations = tools?.first?["functionDeclarations"] as? [[String: Any]]
        #expect((declarations?.first?["parameters"] as? [String: Any])?["type"] as? String == "OBJECT")

        let contents = transport.body(1)["contents"] as? [[String: Any]] ?? []
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let part = (contents[1]["parts"] as? [[String: Any]])?.first
        #expect(part?["thoughtSignature"] as? String == "sig")
        let response = ((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"]) as? [String: Any]
        #expect(response?["name"] as? String == "read_file")
        #expect((response?["response"] as? [String: Any])?["result"] as? String == "contents of Package.swift")
    }
}

// MARK: - Project files

@Suite("Project files")
struct ProjectFilesTests {

    /// A small project outside any repository, so the list is the walk, not git's.
    private func project() throws -> ProjectFiles {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-project-files-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Sources/App"),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("node_modules/junk"),
                                    withIntermediateDirectories: true)
        try "# Readme\nUltra is a terminal.\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try (1...50).map { "line \($0)" }.joined(separator: "\n").write(
            to: root.appendingPathComponent("Sources/App/Main.swift"), atomically: true, encoding: .utf8)
        try "ultra".write(to: root.appendingPathComponent("node_modules/junk/index.js"),
                          atomically: true, encoding: .utf8)
        try "SECRET=ultra".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("icon.png"))
        try "outside".write(to: root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(root.lastPathComponent).txt"), atomically: true, encoding: .utf8)
        return ProjectFiles(root: root)
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> ChatToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return ChatToolCall(id: "1", name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    @Test("a folder lists its children, folders marked, junk and hidden files left out")
    func list() async throws {
        let files = try project()
        #expect(await files.run(call("list_files", [:])) == "icon.png\nREADME.md\nSources/")
        #expect(await files.run(call("list_files", ["path": "Sources"])) == "App/")
    }

    @Test("files are found by part of their path, or by wildcard")
    func find() async throws {
        let files = try project()
        #expect(await files.run(call("find_files", ["pattern": "main"])) == "Sources/App/Main.swift")
        #expect(await files.run(call("find_files", ["pattern": "*.md"])) == "README.md")
    }

    @Test("a file is read a page at a time, and the header says how to get the next")
    func read() async throws {
        let files = try project()
        let page = await files.run(call("read_file", ["path": "Sources/App/Main.swift",
                                                       "start_line": 10, "line_count": 3]))
        #expect(page.hasPrefix("Sources/App/Main.swift — lines 10–12 of 50. For more, call again with start_line 13"))
        #expect(page.hasSuffix("line 10\nline 11\nline 12"))
        #expect(await files.run(call("read_file", ["path": "icon.png"])).contains("not text"))
        #expect(await files.run(call("read_file", ["path": "nope.swift"])).hasPrefix("Error"))
        // A file named outright can be read even though listing leaves it out.
        #expect(await files.run(call("read_file", ["path": ".env"])).hasSuffix("SECRET=ultra"))
    }

    @Test("nothing outside the root can be read, by .. or by an absolute path")
    func confinement() async throws {
        let files = try project()
        let sibling = "outside-\(files.root.lastPathComponent).txt"
        #expect(await files.run(call("read_file", ["path": "../\(sibling)"])).contains("outside the project"))
        #expect(await files.run(call("read_file", ["path": "/etc/hosts"])).contains("outside the project"))
        #expect(await files.run(call("list_files", ["path": ".."])).contains("outside the project"))
        // An absolute path INTO the project is fine.
        let inside = files.root.appendingPathComponent("README.md").path
        #expect(await files.run(call("read_file", ["path": inside])).contains("Ultra is a terminal."))
    }

    @Test("search ignores case and skips what listing skips")
    func search() async throws {
        let files = try project()
        #expect(await files.run(call("search_files", ["query": "ULTRA"])) == "README.md:2: Ultra is a terminal.")
        #expect(await files.run(call("search_files", ["query": "line 7", "path": "Sources"]))
                == "Sources/App/Main.swift:7: line 7")
        #expect(await files.run(call("search_files", ["query": "absent"])).hasPrefix("Nothing matches"))
    }

    @Test("inside a repository, git's ignore rules decide what is listed and searched")
    func gitIgnore() async throws {
        let files = try project()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-C", files.root.path, "init", "-q"]
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        try "README.md\n".write(to: files.root.appendingPathComponent(".gitignore"),
                                atomically: true, encoding: .utf8)
        // Untracked files count; the ignored one and the junk folder's do too, since
        // nothing ignores the junk here — git's rules, not ours.
        let listed = files.files()
        #expect(listed.contains("Sources/App/Main.swift"))
        #expect(listed.contains(".gitignore"))
        #expect(!listed.contains("README.md"))
        #expect(await files.run(call("search_files", ["query": "terminal"])).hasPrefix("Nothing matches"))
    }

    @Test("a call is summarised for the pane in a few words")
    func summary() {
        #expect(ProjectFiles.summary(of: call("read_file", ["path": "a.swift"])) == "Read a.swift")
        #expect(ProjectFiles.summary(of: call("read_file", ["path": "a.swift", "start_line": 40]))
                == "Read a.swift from line 40")
        #expect(ProjectFiles.summary(of: call("list_files", [:])) == "List the project")
    }
}
