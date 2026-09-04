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
        var body: [String: Any] = [
            "contents": request.messages.map { message in
                // Gemini's word for the assistant is "model".
                ["role": message.role == .user ? "user" : "model",
                 "parts": [["text": message.text]]]
            },
        ]
        if let system = request.system, !system.isEmpty {
            body["system_instruction"] = ["parts": [["text": system]]]
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
                    let (status, lines) = try await transport.lines(for: makeRequest(request))
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
                    continuation.yield(.finished(state.finish()))
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
