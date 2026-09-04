import Foundation

/// OpenAI's chat completions API — and, at another base URL, everything that imitates it.
///
/// One type serves two providers. `.openAI` points at api.openai.com; `.compatible` points
/// wherever the user says, which is how Ollama, LM Studio, OpenRouter and a company proxy
/// all become a chat pane without a provider each.
public struct OpenAIProvider: ChatProvider {
    public let id: ChatProviderID
    let credential: ChatCredential
    let transport: ChatTransport

    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    /// Ollama's OpenAI-compatible endpoint, the likeliest local server.
    public static let defaultCompatibleBaseURL = URL(string: "http://localhost:11434/v1")!

    public init(id: ChatProviderID = .openAI, credential: ChatCredential,
                transport: ChatTransport = URLSessionTransport()) {
        self.id = id
        self.credential = credential
        self.transport = transport
    }

    private var baseURL: URL {
        credential.baseURL ?? (id == .compatible ? Self.defaultCompatibleBaseURL : Self.defaultBaseURL)
    }

    // MARK: Request

    public func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        var messages: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = [
            "model": request.model,
            "stream": true,
            // Usage arrives in one last chunk; without asking, it never arrives at all.
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !credential.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try HTTPProviderSupport.json(body)
        return urlRequest
    }

    // MARK: Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if id.requiresCredential, credential.apiKey.isEmpty {
                        throw ChatError.missingCredential(id)
                    }
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
                    if !state.finished { continuation.yield(.finished(state.finish())) }
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
        guard let delta = choice["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return .text(text)
    }

    // MARK: Models

    public func models() async throws -> [String] {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("models"))
        if !credential.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        }
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
