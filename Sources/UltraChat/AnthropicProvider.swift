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
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "messages": request.messages.map { message in
                ["role": message.role.rawValue, "content": message.text]
            },
        ]
        if let system = request.system, !system.isEmpty { body["system"] = system }
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

    // MARK: Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !credential.apiKey.isEmpty else { throw ChatError.missingCredential(id) }
                    var (status, lines) = try await transport.lines(for: makeRequest(request))
                    if status == 400 {
                        // Possibly a service that does not know `fallbacks`. One retry
                        // without; a second 400 is the real error.
                        let body = await HTTPProviderSupport.drain(lines)
                        if body.contains("fallbacks") || body.contains("anthropic-beta") {
                            (status, lines) = try await transport.lines(
                                for: makeRequest(request, withFallbacks: false))
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
                        if let event = parser.feed(line),
                           let out = try Self.handle(event, state: &state) {
                            continuation.yield(out)
                        }
                    }
                    if let event = parser.finish(),
                       let out = try Self.handle(event, state: &state) {
                        continuation.yield(out)
                    }
                    if !state.finished {
                        continuation.yield(.finished(state.finish()))
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
    /// reason and the usage; `message_stop` is when they are reported.
    struct StreamState {
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var finished = false

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
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
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
