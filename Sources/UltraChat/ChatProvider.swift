import Foundation

/// The services a chat can talk to.
///
/// The raw values are stored in every conversation file, so they are stable forever.
public enum ChatProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Apple's on-device model. No key, no network, and the one that always works.
    case apple
    case anthropic
    case openAI
    case gemini
    /// Many vendors' models behind one key, through OpenAI's chat API at a fixed URL.
    /// Model ids are `vendor/model`, and the list is long enough that the live one matters.
    case openRouter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        }
    }

    /// Whether the service needs a key at all. Only the on-device model does not.
    public var requiresCredential: Bool {
        self != .apple
    }

    /// The model a fresh conversation starts on. Every one of these can be changed from
    /// the pane, and the live list from the service is offered beside it.
    public var defaultModel: String {
        switch self {
        case .apple: "on-device"
        case .anthropic: "claude-opus-5"
        case .openAI: "gpt-5"
        case .gemini: "gemini-2.5-flash"
        case .openRouter: "anthropic/claude-opus-5"
        }
    }
}

/// One service, ready to answer.
///
/// Every provider is a stream of `ChatEvent`s: text as it arrives, then how it ended. A
/// provider that cannot stream would wrap its one answer in two events, but all four of
/// these can, and a chat that appears a word at a time is the whole point.
public protocol ChatProvider: Sendable {
    var id: ChatProviderID { get }

    /// Answer a request, a piece at a time. Throws `ChatError` for anything the pane
    /// should show; the stream itself finishes with `.finished` on success.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>

    /// The models this service offers right now, for the picker. Empty if the service
    /// has no list to give, in which case the picker offers what it has.
    func models() async throws -> [String]
}

/// What a provider needs to reach its service: a key, and optionally where the service
/// is, so a test or a proxy can point it elsewhere.
public struct ChatCredential: Sendable, Equatable {
    public var apiKey: String
    public var baseURL: URL?

    public init(apiKey: String, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// The bytes of an HTTP response, line by line, so a provider can be tested against a
/// recorded transcript without a network.
public protocol ChatTransport: Sendable {
    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
    func data(for request: URLRequest) async throws -> (status: Int, data: Data)
}

/// The real network.
public struct URLSessionTransport: ChatTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func lines(for request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }

    public func data(for request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Shared plumbing for the three HTTP providers.
enum HTTPProviderSupport {
    /// Collect a non-streaming body's lines into one error the pane can show. The
    /// services all answer a failed request with JSON carrying a message; that message is
    /// worth more than the status code.
    static func errorMessage(from body: String, status: Int) -> ChatError {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .http(status: status, message: message)
            }
            if let message = object["message"] as? String {
                return .http(status: status, message: message)
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, message: trimmed.count < 300 ? trimmed : "")
    }

    /// Everything a failed streaming request had to say, gathered from its lines.
    static func drain(_ lines: AsyncThrowingStream<String, Error>) async -> String {
        var text = ""
        do { for try await line in lines { text += line + "\n" } } catch {}
        return text
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
