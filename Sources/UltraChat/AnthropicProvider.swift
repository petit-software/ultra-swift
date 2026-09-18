import Foundation

/// Claude, over the Messages API.
///
/// Raw HTTP rather than a package: Anthropic ships no Swift SDK, and the community ones
/// lag the API — adaptive thinking, the `refusal` stop reason, fallbacks. The request is
/// small enough that a wrapper would be more code than the request.
public struct AnthropicProvider: ChatProvider {
    public let id = ChatProviderID.anthropic
    let credential: ChatCredential
    let transport: ChatTransport

    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let version = "2023-06-01"
    /// The output cap. Streaming, so it can be generous: a cap hit mid-answer is an answer
    /// cut off, and nothing about a chat wants that.
    static let maxTokens = 64_000

    public init(credential: ChatCredential, transport: ChatTransport = URLSessionTransport()) {
        self.credential = credential
        self.transport = transport
    }

    private var baseURL: URL { credential.baseURL ?? Self.defaultBaseURL }

    // MARK: Request

    /// The request, in the shape the API documents. Public so a test can read it.
    ///
    /// `fallbacks: "default"` is opt-in on the API and on here: when a safety classifier
    /// declines a request the API re-runs it on a fallback model inside the same call,
    /// rather than the chat simply stopping. A service that does not know the parameter
    /// answers 400, and `stream` retries once without it.
    public func makeRequest(_ request: ChatRequest, withFallbacks: Bool = true) throws -> URLRequest {
        try makeRequest(request, messages: Self.wireMessages(request.messages),
                        withFallbacks: withFallbacks)
    }

    /// The same, with the messages already in the API's shape — which is how a round of
    /// the tool loop asks again, its own turns appended exactly as they arrived.
    func makeRequest(_ request: ChatRequest, messages: [[String: Any]],
                     withFallbacks: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "messages": messages,
        ]
        if let system = request.system, !system.isEmpty { body["system"] = system }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["name": tool.name, "description": tool.description, "input_schema": tool.schema()]
            }
        }
        if withFallbacks { body["fallbacks"] = "default" }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        if withFallbacks {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try HTTPProviderSupport.json(body)
        return urlRequest
    }

    /// The conversation in the API's shape. A turn that called tools becomes two messages:
    /// the assistant's, with a `tool_use` block per call, and a user's carrying every
    /// result — all of them in the one message, which is what keeps the model calling
    /// tools side by side.
    static func wireMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        for message in messages where !message.isEmpty {
            guard message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty else {
                wire.append(["role": message.role.rawValue, "content": message.text])
                continue
            }
            var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
            content += calls.map { call in
                ["type": "tool_use", "id": call.id, "name": call.name, "input": call.argumentValues]
            }
            wire.append(["role": "assistant", "content": content])
            wire.append(["role": "user", "content": calls.map(Self.toolResult)])
        }
        return wire
    }

    private static func toolResult(_ call: ChatToolCall) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": call.id,
         "content": call.result ?? ChatToolCall.missingResult]
    }

    // MARK: Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !credential.apiKey.isEmpty else { throw ChatError.missingCredential(id) }
                    var messages = Self.wireMessages(request.messages)
                    var withFallbacks = true
                    for round in 1...maxToolRounds {
                        var (status, lines) = try await transport.lines(
                            for: makeRequest(request, messages: messages, withFallbacks: withFallbacks))
                        if status == 400, withFallbacks {
                            // Possibly a service that does not know `fallbacks`. One retry
                            // without; a second 400 is the real error.
                            let body = await HTTPProviderSupport.drain(lines)
                            if body.contains("fallbacks") || body.contains("anthropic-beta") {
                                withFallbacks = false
                                (status, lines) = try await transport.lines(
                                    for: makeRequest(request, messages: messages, withFallbacks: false))
                            } else {
                                throw HTTPProviderSupport.errorMessage(from: body, status: status)
                            }
                        }
                        guard (200..<300).contains(status) else {
                            let body = await HTTPProviderSupport.drain(lines)
                            throw HTTPProviderSupport.errorMessage(from: body, status: status)
                        }
                        var parser = SSEParser()
                        var state = StreamState()
                        for try await line in lines {
                            // `.finished` is held back: whether this round is the end
                            // is only known once its tool calls have been counted.
                            if let event = parser.feed(line),
                               case .text(let text)? = try Self.handle(event, state: &state) {
                                continuation.yield(.text(text))
                            }
                        }
                        if let event = parser.finish(),
                           case .text(let text)? = try Self.handle(event, state: &state) {
                            continuation.yield(.text(text))
                        }

                        // Only a turn that STOPPED to call tools has calls worth running:
                        // one cut off by the output cap may hold half a call.
                        let calls = state.stopReason == "tool_use" ? state.toolCalls : []
                        guard let toolbox = request.toolbox, !calls.isEmpty else {
                            continuation.yield(.finished(state.finish()))
                            break
                        }
                        guard round < maxToolRounds else {
                            continuation.yield(.finished(ChatFinish(
                                reason: .other, detail: "too many tool calls in one answer")))
                            break
                        }
                        var results: [[String: Any]] = []
                        // Every call of the round is announced before any is run, so
                        // the store can tell one round's calls from the next round's.
                        for call in calls { continuation.yield(.toolCall(call)) }
                        for var call in calls {
                            try Task.checkCancellation()
                            let result = await toolbox.run(call)
                            continuation.yield(.toolResult(id: call.id, result: result))
                            call.result = result
                            results.append(Self.toolResult(call))
                        }
                        // The turn goes back exactly as it arrived — thinking blocks and
                        // their signatures included, which the API checks — then the results.
                        messages.append(["role": "assistant", "content": state.content])
                        messages.append(["role": "user", "content": results])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What has been learned about the response so far. `message_delta` carries the stop
    /// reason and the usage; `message_stop` is when they are reported. The content blocks
    /// are kept whole, keyed by their index, so a turn that calls tools can be sent back.
    struct StreamState {
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var finished = false
        var blocks: [Int: [String: Any]] = [:]
        /// A tool call's arguments arrive as pieces of JSON text, per block.
        var partialInput: [Int: String] = [:]

        /// The turn's content, in order, as the API wants it back. An empty text block is
        /// dropped: the API sends them and then refuses them.
        var content: [[String: Any]] {
            blocks.keys.sorted().compactMap { index in
                guard var block = blocks[index] else { return nil }
                switch block["type"] as? String {
                case "text":
                    return (block["text"] as? String ?? "").isEmpty ? nil : block
                case "tool_use":
                    let text = partialInput[index] ?? ""
                    block["input"] = text.data(using: .utf8).flatMap(HTTPProviderSupport.object) ?? [:]
                    return block
                default:
                    return block
                }
            }
        }

        /// More of a block's text, thinking or signature, all of which arrive in pieces.
        mutating func append(_ piece: String, to key: String, at index: Int) {
            blocks[index, default: [:]][key] = (blocks[index]?[key] as? String ?? "") + piece
        }

        var toolCalls: [ChatToolCall] {
            blocks.keys.sorted().compactMap { index in
                guard let block = blocks[index], block["type"] as? String == "tool_use",
                      let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                let input = partialInput[index] ?? ""
                return ChatToolCall(id: id, name: name, arguments: input.isEmpty ? "{}" : input)
            }
        }

        mutating func finish() -> ChatFinish {
            finished = true
            let reason: ChatFinish.Reason = switch stopReason {
            case nil, "end_turn", "stop_sequence", "tool_use": .complete
            case "max_tokens": .length
            case "refusal": .refusal
            default: .other
            }
            return ChatFinish(reason: reason,
                              detail: reason == .other ? stopReason : nil,
                              inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    /// One event of the stream, as a chat event — or nothing, for the many that carry
    /// nothing a chat shows. Public so the parsing is testable against a transcript.
    public static func handle(_ event: ServerSentEvent) throws -> ChatEvent? {
        var state = StreamState()
        return try handle(event, state: &state)
    }

    static func handle(_ event: ServerSentEvent, state: inout StreamState) throws -> ChatEvent? {
        guard let data = event.data.data(using: .utf8),
              let object = HTTPProviderSupport.object(data) else {
            throw ChatError.malformed("not JSON: \(event.data.prefix(80))")
        }
        switch object["type"] as? String ?? event.event {
        case "content_block_start":
            if let index = object["index"] as? Int, let block = object["content_block"] as? [String: Any] {
                state.blocks[index] = block
            }
            return nil
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return nil }
            let index = object["index"] as? Int ?? 0
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return nil }
                if state.blocks[index] == nil { state.blocks[index] = ["type": "text"] }
                state.append(text, to: "text", at: index)
                return .text(text)
            case "input_json_delta":
                state.partialInput[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                state.append(delta["thinking"] as? String ?? "", to: "thinking", at: index)
            case "signature_delta":
                state.append(delta["signature"] as? String ?? "", to: "signature", at: index)
            default:
                break
            }
            return nil
        case "message_start":
            if let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                state.inputTokens = usage["input_tokens"] as? Int
            }
            return nil
        case "message_delta":
            if let delta = object["delta"] as? [String: Any] {
                state.stopReason = delta["stop_reason"] as? String
            }
            if let usage = object["usage"] as? [String: Any] {
                state.outputTokens = usage["output_tokens"] as? Int ?? state.outputTokens
                state.inputTokens = usage["input_tokens"] as? Int ?? state.inputTokens
            }
            return nil
        case "message_stop":
            return .finished(state.finish())
        case "error":
            let error = object["error"] as? [String: Any]
            throw ChatError.http(status: 0, message: error?["message"] as? String ?? "stream error")
        default:
            return nil
        }
    }

    // MARK: Models

    public func models() async throws -> [String] {
        guard !credential.apiKey.isEmpty else { throw ChatError.missingCredential(id) }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        let (status, data) = try await transport.data(for: urlRequest)
        guard (200..<300).contains(status) else {
            throw HTTPProviderSupport.errorMessage(from: String(decoding: data, as: UTF8.self),
                                                   status: status)
        }
        return Self.parseModels(data)
    }

    public static func parseModels(_ data: Data) -> [String] {
        guard let object = HTTPProviderSupport.object(data),
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}
