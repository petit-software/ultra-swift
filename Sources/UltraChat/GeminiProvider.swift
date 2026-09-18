import Foundation

/// Gemini, over the Generative Language API.
///
/// Google's own Swift SDK was archived in December 2025 in favour of Firebase, which wants
/// a Firebase project — the wrong shape for a terminal. The REST API is one endpoint with
/// `alt=sse`, and that is all a chat needs.
public struct GeminiProvider: ChatProvider {
    public let id = ChatProviderID.gemini
    let credential: ChatCredential
    let transport: ChatTransport

    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public init(credential: ChatCredential, transport: ChatTransport = URLSessionTransport()) {
        self.credential = credential
        self.transport = transport
    }

    private var baseURL: URL { credential.baseURL ?? Self.defaultBaseURL }

    // MARK: Request

    public func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        try makeRequest(request, contents: Self.wireContents(request.messages))
    }

    /// The conversation in the API's shape. Gemini's word for the assistant is "model"; a
    /// turn that called tools is the model's `functionCall` parts, then a user turn of
    /// `functionResponse` parts, matched by name and order rather than by id.
    static func wireContents(_ messages: [ChatMessage]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        for message in messages where !message.isEmpty {
            var parts: [[String: Any]] = message.text.isEmpty ? [] : [["text": message.text]]
            let calls = message.role == .assistant ? message.toolCalls ?? [] : []
            parts += calls.map { ["functionCall": ["name": $0.name, "args": $0.argumentValues]] }
            wire.append(["role": message.role == .user ? "user" : "model", "parts": parts])
            if !calls.isEmpty { wire.append(responseContent(calls)) }
        }
        return wire
    }

    private static func responseContent(_ calls: [ChatToolCall]) -> [String: Any] {
        ["role": "user", "parts": calls.map { call in
            ["functionResponse": ["name": call.name,
                                  "response": ["result": call.result ?? ChatToolCall.missingResult]]]
        }]
    }

    /// The same, with the contents already in the API's shape, for a round of the tool loop.
    func makeRequest(_ request: ChatRequest, contents: [[String: Any]]) throws -> URLRequest {
        var body: [String: Any] = ["contents": contents]
        if let system = request.system, !system.isEmpty {
            body["system_instruction"] = ["parts": [["text": system]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": request.tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "parameters": tool.schema(uppercaseTypes: true)]
            }]]
        }
        let model = request.model.hasPrefix("models/") ? request.model : "models/\(request.model)"
        var components = URLComponents(url: baseURL.appendingPathComponent("\(model):streamGenerateContent"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try HTTPProviderSupport.json(body)
        return urlRequest
    }

    // MARK: Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !credential.apiKey.isEmpty else { throw ChatError.missingCredential(id) }
                    var contents = Self.wireContents(request.messages)
                    for round in 1...maxToolRounds {
                        let (status, lines) = try await transport.lines(
                            for: makeRequest(request, contents: contents))
                        guard (200..<300).contains(status) else {
                            let body = await HTTPProviderSupport.drain(lines)
                            throw HTTPProviderSupport.errorMessage(from: body, status: status)
                        }
                        var parser = SSEParser()
                        var state = StreamState()
                        for try await line in lines {
                            if let event = parser.feed(line),
                               let out = try Self.handle(event, state: &state) {
                                continuation.yield(out)
                            }
                        }
                        if let event = parser.finish(),
                           let out = try Self.handle(event, state: &state) {
                            continuation.yield(out)
                        }

                        // A turn cut off by the output cap may hold half a call.
                        let calls = state.finishReason == "MAX_TOKENS" ? [] : state.toolCalls
                        guard let toolbox = request.toolbox, !calls.isEmpty else {
                            continuation.yield(.finished(state.finish()))
                            break
                        }
                        guard round < maxToolRounds else {
                            continuation.yield(.finished(ChatFinish(
                                reason: .other, detail: "too many tool calls in one answer")))
                            break
                        }
                        var answered: [ChatToolCall] = []
                        // Every call of the round is announced before any is run, so
                        // the store can tell one round's calls from the next round's.
                        for call in calls { continuation.yield(.toolCall(call)) }
                        for var call in calls {
                            try Task.checkCancellation()
                            let result = await toolbox.run(call)
                            continuation.yield(.toolResult(id: call.id, result: result))
                            call.result = result
                            answered.append(call)
                        }
                        // The model's parts go back exactly as they arrived: a call can
                        // carry a `thoughtSignature`, and the newer models refuse a
                        // call of this turn that comes back without it.
                        contents.append(["role": "model", "parts": state.parts])
                        contents.append(Self.responseContent(answered))
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
        /// Every part the model sent this turn, whole, for sending back with tool results.
        var parts: [[String: Any]] = []

        /// Gemini gives a call no id; one is made here, unique within the turn, so a result
        /// can be matched to its row in the pane. The service matches by name and order.
        var toolCalls: [ChatToolCall] {
            parts.enumerated().compactMap { index, part in
                guard let call = part["functionCall"] as? [String: Any],
                      let name = call["name"] as? String else { return nil }
                let args = (try? HTTPProviderSupport.json(call["args"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                return ChatToolCall(id: call["id"] as? String ?? "\(name)-\(index)",
                                    name: name, arguments: String(decoding: args, as: UTF8.self))
            }
        }

        func finish() -> ChatFinish {
            let reason: ChatFinish.Reason = switch finishReason {
            case nil, "STOP": .complete
            case "MAX_TOKENS": .length
            case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": .refusal
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

    /// Gemini never sends a terminator: the last chunk carries `finishReason`, and the
    /// body simply ends. So no event here is `.finished`; the caller adds it at the end.
    static func handle(_ event: ServerSentEvent, state: inout StreamState) throws -> ChatEvent? {
        guard let data = event.data.data(using: .utf8),
              let object = HTTPProviderSupport.object(data) else {
            throw ChatError.malformed("not JSON: \(event.data.prefix(80))")
        }
        if let error = object["error"] as? [String: Any] {
            throw ChatError.http(status: error["code"] as? Int ?? 0,
                                 message: error["message"] as? String ?? "stream error")
        }
        if let usage = object["usageMetadata"] as? [String: Any] {
            state.inputTokens = usage["promptTokenCount"] as? Int ?? state.inputTokens
            state.outputTokens = usage["candidatesTokenCount"] as? Int ?? state.outputTokens
        }
        // A prompt blocked outright has no candidates, only a reason.
        if let feedback = object["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            state.finishReason = reason
            return nil
        }
        guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return nil }
        if let reason = candidate["finishReason"] as? String { state.finishReason = reason }
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        state.parts += parts
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : .text(text)
    }

    // MARK: Models

    public func models() async throws -> [String] {
        guard !credential.apiKey.isEmpty else { throw ChatError.missingCredential(id) }
        var components = URLComponents(url: baseURL.appendingPathComponent("models"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (status, data) = try await transport.data(for: urlRequest)
        guard (200..<300).contains(status) else {
            throw HTTPProviderSupport.errorMessage(from: String(decoding: data, as: UTF8.self),
                                                   status: status)
        }
        return Self.parseModels(data)
    }

    /// Only the models that can chat: the list also carries embedding and image models,
    /// which a chat pane cannot use.
    public static func parseModels(_ data: Data) -> [String] {
        guard let object = HTTPProviderSupport.object(data),
              let list = object["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }
}
