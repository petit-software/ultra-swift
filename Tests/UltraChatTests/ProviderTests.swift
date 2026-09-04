import Testing
import Foundation
@testable import UltraChat

/// A transport that answers from a recorded body instead of a network, and remembers
/// what it was asked.
final class RecordedTransport: ChatTransport, @unchecked Sendable {
    let status: Int
    let body: String
    var requests: [URLRequest] = []

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func lines(for request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let lines = body.components(separatedBy: "\n")
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    func data(for request: URLRequest) async throws -> (status: Int, data: Data) {
        requests.append(request)
        return (status, Data(body.utf8))
    }
}

private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func text(of events: [ChatEvent]) -> String {
    events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
}

private func lastFinish(of events: [ChatEvent]) -> ChatFinish? {
    events.compactMap { if case .finished(let f) = $0 { f } else { nil } }.last
}

private func body(of request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

private let sample = ChatRequest(model: "m", system: "Be terse.", messages: [
    ChatMessage(role: .user, text: "Hi"),
    ChatMessage(role: .assistant, text: "Hello."),
    ChatMessage(role: .user, text: "Write a haiku"),
])

// MARK: - SSE

@Suite("Server-sent events")
struct SSEParserTests {

    @Test("events are delimited by blank lines, and multi-line data joins with newlines")
    func basics() {
        var parser = SSEParser()
        #expect(parser.feed("event: ping") == nil)
        #expect(parser.feed("data: one") == nil)
        #expect(parser.feed("data: two") == nil)
        #expect(parser.feed("") == ServerSentEvent(event: "ping", data: "one\ntwo"))
        // The state is cleared for the next event.
        #expect(parser.feed("data: three") == nil)
        #expect(parser.feed("") == ServerSentEvent(event: nil, data: "three"))
    }

    @Test("comments and unknown fields are dropped, and a missing space is tolerated")
    func noise() {
        var parser = SSEParser()
        #expect(parser.feed(": keep-alive") == nil)
        #expect(parser.feed("id: 7") == nil)
        #expect(parser.feed("data:tight") == nil)
        #expect(parser.feed("") == ServerSentEvent(data: "tight"))
    }

    @Test("a body that ends without a blank line still yields its last event")
    func finish() {
        var parser = SSEParser()
        #expect(parser.feed("data: last") == nil)
        #expect(parser.finish() == ServerSentEvent(data: "last"))
        #expect(parser.finish() == nil)
    }
}

// MARK: - Anthropic

@Suite("Anthropic provider")
struct AnthropicProviderTests {

    static let transcript = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5","usage":{"input_tokens":25,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("the request carries the documented headers, body and system prompt")
    func request() throws {
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "sk-test"))
        let request = try provider.makeRequest(sample)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = body(of: request)
        #expect(json["model"] as? String == "m")
        #expect(json["stream"] as? Bool == true)
        #expect(json["system"] as? String == "Be terse.")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["max_tokens"] as? Int == 64_000)
        let messages = json["messages"] as? [[String: String]]
        #expect(messages?.count == 3)
        #expect(messages?.first == ["role": "user", "content": "Hi"])
        #expect(messages?.last == ["role": "user", "content": "Write a haiku"])
        // The system prompt is a top-level field, never a message.
        #expect(messages?.contains { $0["role"] == "system" } == false)
    }

    @Test("a recorded stream becomes text deltas and a finish with usage")
    func streaming() async throws {
        let transport = RecordedTransport(body: Self.transcript)
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(sample))
        #expect(text(of: events) == "Hello, world")
        let finish = try #require(lastFinish(of: events))
        #expect(finish.reason == .complete)
        #expect(finish.inputTokens == 25)
        #expect(finish.outputTokens == 12)
        // Exactly one finish, at the end.
        #expect(events.last == .finished(finish))
        #expect(events.filter { if case .finished = $0 { true } else { false } }.count == 1)
    }

    @Test("a refusal and a length cap are named, not silently ended")
    func stopReasons() throws {
        var state = AnthropicProvider.StreamState()
        _ = try AnthropicProvider.handle(ServerSentEvent(
            data: #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#),
            state: &state)
        #expect(state.finish().reason == .refusal)
        var capped = AnthropicProvider.StreamState()
        _ = try AnthropicProvider.handle(ServerSentEvent(
            data: #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#), state: &capped)
        #expect(capped.finish().reason == .length)
    }

    @Test("an error event surfaces as the service's own message")
    func errorEvent() async {
        let transport = RecordedTransport(body: """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """)
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        await #expect(throws: ChatError.http(status: 0, message: "Overloaded")) {
            try await collect(provider.stream(sample))
        }
    }

    @Test("a failed request surfaces the JSON error message, not the status alone")
    func httpError() async {
        let transport = RecordedTransport(status: 401, body:
            #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        await #expect(throws: ChatError.http(status: 401, message: "invalid x-api-key")) {
            try await collect(provider.stream(sample))
        }
    }

    @Test("no key means no request")
    func missingKey() async {
        let transport = RecordedTransport(body: "")
        let provider = AnthropicProvider(credential: ChatCredential(apiKey: ""), transport: transport)
        await #expect(throws: ChatError.missingCredential(.anthropic)) {
            try await collect(provider.stream(sample))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("the model list reads ids")
    func models() {
        let data = Data(#"{"data":[{"id":"claude-opus-5","type":"model"},{"id":"claude-sonnet-5"}]}"#.utf8)
        #expect(AnthropicProvider.parseModels(data) == ["claude-opus-5", "claude-sonnet-5"])
    }
}

// MARK: - OpenAI

@Suite("OpenAI provider")
struct OpenAIProviderTests {

    static let transcript = """
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}}

    data: [DONE]

    """

    @Test("the system prompt is the first message, and the key is a bearer token")
    func request() throws {
        let provider = OpenAIProvider(credential: ChatCredential(apiKey: "sk"))
        let request = try provider.makeRequest(sample)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
        let json = body(of: request)
        let messages = json["messages"] as? [[String: String]]
        #expect(messages?.first == ["role": "system", "content": "Be terse."])
        #expect(messages?.count == 4)
        #expect((json["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test("a compatible server at a custom base URL needs no key")
    func compatible() async throws {
        let transport = RecordedTransport(body: Self.transcript)
        let provider = OpenAIProvider(
            id: .compatible,
            credential: ChatCredential(apiKey: "", baseURL: URL(string: "http://localhost:11434/v1")),
            transport: transport)
        let events = try await collect(provider.stream(sample))
        #expect(text(of: events) == "Hello")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a recorded stream becomes text, then one finish carrying the usage chunk")
    func streaming() async throws {
        let transport = RecordedTransport(body: Self.transcript)
        let provider = OpenAIProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(sample))
        #expect(text(of: events) == "Hello")
        let finish = try #require(lastFinish(of: events))
        #expect(finish.reason == .complete)
        #expect(finish.inputTokens == 9)
        #expect(finish.outputTokens == 3)
        #expect(events.filter { if case .finished = $0 { true } else { false } }.count == 1)
    }

    @Test("length and content filter are told apart")
    func finishReasons() throws {
        var state = OpenAIProvider.StreamState()
        _ = try OpenAIProvider.handle(ServerSentEvent(
            data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#), state: &state)
        #expect(state.finish().reason == .length)
        var filtered = OpenAIProvider.StreamState()
        _ = try OpenAIProvider.handle(ServerSentEvent(
            data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"#), state: &filtered)
        #expect(filtered.finish().reason == .refusal)
    }

    @Test("the model list is sorted ids")
    func models() {
        let data = Data(#"{"object":"list","data":[{"id":"gpt-5"},{"id":"gpt-4.1"}]}"#.utf8)
        #expect(OpenAIProvider.parseModels(data) == ["gpt-4.1", "gpt-5"])
    }
}

// MARK: - Gemini

@Suite("Gemini provider")
struct GeminiProviderTests {

    static let transcript = """
    data: {"candidates":[{"content":{"parts":[{"text":"Old "}],"role":"model"},"index":0}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":1}}

    data: {"candidates":[{"content":{"parts":[{"text":"pond"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2,"totalTokenCount":6}}

    """

    @Test("the assistant is 'model', the system prompt is an instruction, and the key is a header")
    func request() throws {
        let provider = GeminiProvider(credential: ChatCredential(apiKey: "g"))
        let request = try provider.makeRequest(sample)
        #expect(request.url?.absoluteString ==
                "https://generativelanguage.googleapis.com/v1beta/models/m:streamGenerateContent?alt=sse")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g")
        let json = body(of: request)
        let contents = json["contents"] as? [[String: Any]]
        #expect(contents?.count == 3)
        #expect(contents?[1]["role"] as? String == "model")
        let system = json["system_instruction"] as? [String: Any]
        #expect(((system?["parts"] as? [[String: String]])?.first?["text"]) == "Be terse.")
    }

    @Test("a recorded stream ends with a finish even though the service sends no terminator")
    func streaming() async throws {
        let transport = RecordedTransport(body: Self.transcript)
        let provider = GeminiProvider(credential: ChatCredential(apiKey: "k"), transport: transport)
        let events = try await collect(provider.stream(sample))
        #expect(text(of: events) == "Old pond")
        let finish = try #require(lastFinish(of: events))
        #expect(finish.reason == .complete)
        #expect(finish.inputTokens == 4)
        #expect(finish.outputTokens == 2)
    }

    @Test("a blocked prompt is a refusal")
    func blocked() throws {
        var state = GeminiProvider.StreamState()
        _ = try GeminiProvider.handle(ServerSentEvent(
            data: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#), state: &state)
        #expect(state.finish().reason == .refusal)
    }

    @Test("only models that can generate content are listed, without the prefix")
    func models() {
        let data = Data("""
        {"models":[
          {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}
        ]}
        """.utf8)
        #expect(GeminiProvider.parseModels(data) == ["gemini-2.5-flash"])
    }
}

// MARK: - Archive and blocks

@Suite("Chat archive")
struct ChatArchiveTests {

    @Test("a conversation round-trips through disk and lists newest first")
    func roundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-chat-\(UUID().uuidString)")
        let archive = ChatArchive(root: root)
        #expect(archive.load().isEmpty)

        let older = ChatConversation(provider: .apple, model: "on-device",
                                     messages: [ChatMessage(role: .user, text: "first")],
                                     updatedAt: Date(timeIntervalSince1970: 100))
        let newer = ChatConversation(provider: .anthropic, model: "claude-opus-5",
                                     messages: [ChatMessage(role: .user, text: "second\nline"),
                                                ChatMessage(role: .assistant, text: "ok", model: "claude-opus-5")],
                                     updatedAt: Date(timeIntervalSince1970: 200))
        try archive.save(older)
        try archive.save(newer)

        let listed = archive.load()
        #expect(listed.map(\.id) == [newer.id, older.id])
        #expect(listed.first?.displayTitle == "second")
        #expect(archive.load(id: older.id)?.messages.first?.text == "first")

        archive.delete(id: older.id)
        #expect(archive.load().map(\.id) == [newer.id])
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a title falls back to the first user line, trimmed")
    func titles() {
        let long = String(repeating: "x", count: 60)
        let conversation = ChatConversation(provider: .apple, model: "m",
                                            messages: [ChatMessage(role: .user, text: long)])
        #expect(conversation.displayTitle.hasSuffix("…"))
        #expect(conversation.displayTitle.count == 49)
        #expect(ChatConversation(provider: .apple, model: "m").displayTitle == "New chat")
    }
}

@Suite("Markdown blocks")
struct MarkdownBlocksTests {

    @Test("fenced code is cut out of the prose around it")
    func fences() {
        let blocks = MarkdownBlocks.split("""
        Run this:

        ```sh
        ls -la
        ```

        Then **read** it.
        """)
        #expect(blocks == [
            .prose("Run this:"),
            .code(language: "sh", text: "ls -la"),
            .prose("Then **read** it."),
        ])
    }

    @Test("a fence still open while streaming renders as code")
    func openFence() {
        let blocks = MarkdownBlocks.split("Here:\n```swift\nlet x = 1\nlet y =")
        #expect(blocks == [.prose("Here:"), .code(language: "swift", text: "let x = 1\nlet y =")])
    }

    @Test("prose alone is one block, and tildes fence too")
    func plainAndTildes() {
        #expect(MarkdownBlocks.split("just words") == [.prose("just words")])
        #expect(MarkdownBlocks.split("~~~\na\n~~~") == [.code(language: nil, text: "a")])
        #expect(MarkdownBlocks.split("") == [])
    }
}

#if canImport(FoundationModels)
import FoundationModels

@Suite("Apple provider")
struct AppleProviderTests {

    @Test("the conversation becomes a transcript: instructions, then prompts and responses")
    func transcript() {
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Hello."),
        ]
        let transcript = AppleProvider.transcript(system: "Be terse.", history: history[...])
        let entries = Array(transcript)
        #expect(entries.count == 3)
        guard case .instructions = entries[0] else { Issue.record("no instructions"); return }
        guard case .prompt = entries[1] else { Issue.record("no prompt"); return }
        guard case .response = entries[2] else { Issue.record("no response"); return }
        // No system prompt, no instructions entry.
        #expect(Array(AppleProvider.transcript(system: nil, history: history[...])).count == 2)
    }
}
#endif
