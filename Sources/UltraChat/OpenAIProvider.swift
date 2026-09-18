import Foundation

/// OpenAI's chat completions API, as spoken by OpenRouter — and, at its original base URL,
/// by OpenAI itself.
///
/// One type serves two providers. `.openRouter`, the one offered, points at openrouter.ai,
/// which fronts many vendors' models behind one key. `.openAI` points at api.openai.com
/// and is retired: it exists so a conversation saved on it still opens, not for new ones.
public struct OpenAIProvider: ChatProvider {
    public let id: ChatProviderID
    let credential: ChatCredential
    let transport: ChatTransport

    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    public static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    public init(id: ChatProviderID = .openRouter, credential: ChatCredential,
                transport: ChatTransport = URLSessionTransport()) {
        self.id = id
        self.credential = credential
        self.transport = transport
    }

    private var baseURL: URL {
        credential.baseURL ?? (id == .openRouter ? Self.openRouterBaseURL : Self.defaultBaseURL)
    }

    /// The bearer token, plus the app-attribution headers OpenRouter asks for so the
    /// request shows up under a name in its dashboard.
    private func authorize(_ urlRequest: inout URLRequest) {
        if !credential.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if id == .openRouter {
            urlRequest.setValue("Ultra", forHTTPHeaderField: "X-Title")
        }
    }

    // MARK: Request

    public func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        try makeRequest(request, messages: Self.wireMessages(request))
    }

    /// The same, with the messages already in the API's shape, for a round of the tool loop.
    func makeRequest(_ request: ChatRequest, messages: [[String: Any]]) throws -> URLRequest {
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            // Usage arrives in one last chunk; without asking, it never arrives at all.
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description,
                              "parameters": tool.schema()]]
            }
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.httpBody = try HTTPProviderSupport.json(body)
        return urlRequest
    }

    /// The conversation in the API's shape: the system prompt first, and a turn that called
    /// tools as the assistant's message with its `tool_calls`, then one `tool` message per
    /// result.
    static func wireMessages(_ request: ChatRequest) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            wire.append(["role": "system", "content": system])
        }
        for message in request.messages where !message.isEmpty {
            guard message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty else {
                wire.append(["role": message.role.rawValue, "content": message.text])
                continue
            }
            wire.append(assistantMessage(text: message.text, calls: calls))
            wire += calls.map(toolMessage)
        }
        return wire
    }

    private static func assistantMessage(text: String, calls: [ChatToolCall]) -> [String: Any] {
        ["role": "assistant",
         "content": text.isEmpty ? NSNull() : text,
         "tool_calls": calls.map { call in
             ["id": call.id, "type": "function",
              "function": ["name": call.name, "arguments": call.arguments]]
         }]
    }

    private static func toolMessage(_ call: ChatToolCall) -> [String: Any] {
        ["role": "tool", "tool_call_id": call.id,
         "content": call.result ?? ChatToolCall.missingResult]
    }

    // MARK: Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if id.requiresCredential, credential.apiKey.isEmpty {
                        throw ChatError.missingCredential(id)
                    }
                    var messages = Self.wireMessages(request)
                    for round in 1...maxToolRounds {
                        let (status, lines) = try await transport.lines(
                            for: makeRequest(request, messages: messages))
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

                        // A turn cut off by the output cap may hold half a call.
                        let calls = state.finishReason == "length" ? [] : state.toolCalls
                        guard let toolbox = request.toolbox, !calls.isEmpty else {
                            continuation.yield(.finished(state.finish()))
                            break
                        }
                        guard round < maxToolRounds else {
                            continuation.yield(.finished(ChatFinish(
                                reason: .other, detail: "too many tool calls in one answer")))
                            break
                        }
                        messages.append(Self.assistantMessage(text: state.text, calls: calls))
                        // Every call of the round is announced before any is run, so
                        // the store can tell one round's calls from the next round's.
                        for call in calls { continuation.yield(.toolCall(call)) }
                        for var call in calls {
                            try Task.checkCancellation()
                            let result = await toolbox.run(call)
                            continuation.yield(.toolResult(id: call.id, result: result))
                            call.result = result
                            messages.append(Self.toolMessage(call))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct StreamState {
        var finishReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var finished = false
        /// Everything said this turn, which goes back with the turn's tool calls.
        var text = ""
        /// Tool calls arrive in pieces keyed by index: the id and name once, the
        /// arguments a fragment of JSON text at a time.
        var partialCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        var toolCalls: [ChatToolCall] {
            partialCalls.keys.sorted().compactMap { index in
                guard let call = partialCalls[index], !call.name.isEmpty else { return nil }
                return ChatToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name,
                                    arguments: call.arguments.isEmpty ? "{}" : call.arguments)
            }
        }

        mutating func finish() -> ChatFinish {
            finished = true
            let reason: ChatFinish.Reason = switch finishReason {
            case nil, "stop", "tool_calls", "function_call": .complete
            case "length": .length
            case "content_filter": .refusal
            default: .other
            }
            return ChatFinish(reason: reason, detail: reason == .other ? finishReason : nil,
                              inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    public static func handle(_ event: ServerSentEvent) throws -> ChatEvent? {
        var state = StreamState()
        return try handle(event, state: &state)
    }

    static func handle(_ event: ServerSentEvent, state: inout StreamState) throws -> ChatEvent? {
        // The one non-JSON line the API sends.
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return state.finished ? nil : .finished(state.finish())
        }
        guard let data = event.data.data(using: .utf8),
              let object = HTTPProviderSupport.object(data) else {
            throw ChatError.malformed("not JSON: \(event.data.prefix(80))")
        }
        if let error = object["error"] as? [String: Any] {
            throw ChatError.http(status: 0, message: error["message"] as? String ?? "stream error")
        }
        if let usage = object["usage"] as? [String: Any] {
            state.inputTokens = usage["prompt_tokens"] as? Int ?? state.inputTokens
            state.outputTokens = usage["completion_tokens"] as? Int ?? state.outputTokens
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
        if let reason = choice["finish_reason"] as? String { state.finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }
        for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = piece["index"] as? Int ?? 0
            var call = state.partialCalls[index] ?? (id: "", name: "", arguments: "")
            let function = piece["function"] as? [String: Any]
            call.id += piece["id"] as? String ?? ""
            call.name += function?["name"] as? String ?? ""
            call.arguments += function?["arguments"] as? String ?? ""
            state.partialCalls[index] = call
        }
        guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
        state.text += text
        return .text(text)
    }

    // MARK: Models

    public func models() async throws -> [String] {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("models"))
        authorize(&urlRequest)
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
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}
