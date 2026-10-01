import Foundation

/// The services a chat can talk to.
///
/// The raw values are stored in every conversation file, so they are stable forever.
public enum ChatProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Apple's on-device model. No key, no network, and the one that always works.
    case apple
    case anthropic
    /// RETIRED. Not offered anywhere in the app; the case stays so a conversation file
    /// written while it was can still be read. OpenRouter reaches the same models, and
    /// every other vendor's, behind one key — a second key for one vendor bought nothing.
    case openAI
    /// RETIRED, like OpenAI, and for the same reason: OpenRouter reaches Gemini behind the
    /// one key. The case stays so a conversation file written on it can still be read.
    case gemini
    /// Many vendors' models behind one key, through OpenAI's chat API at a fixed URL.
    /// Model ids are `vendor/model`, and the list is long enough that the live one matters.
    case openRouter
    /// The user's Claude subscription, through their own Claude Code binary: `claude -p`,
    /// one process per turn, talking stream-json. No key and no token ever passes through
    /// here — Anthropic's terms allow a subscription only inside the unmodified binary.
    case claudeCode
    /// The user's ChatGPT plan, through Codex's app server: `codex app-server` over stdio,
    /// JSON-RPC, kept running between turns. The same way Xcode reaches it.
    case codex

    public var id: String { rawValue }

    /// The services a pane or Settings will offer. `allCases` still includes the retired
    /// one, because decoding does.
    public static let offered: [ChatProviderID] = [.apple, .claudeCode, .codex, .anthropic, .openRouter]

    /// How a provider is paid for, which is how the pane's menu and Settings group them:
    /// a choice between "my plan" and "my key" comes before a choice of vendor.
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case device = "On this Mac"
        case subscription = "Subscription"
        case api = "API key"

        public var id: String { rawValue }
        public var title: String { rawValue }

        /// The offered providers of this group, in the order they are offered.
        public var providers: [ChatProviderID] { ChatProviderID.offered.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .apple: .device
        case .claudeCode, .codex: .subscription
        case .anthropic, .openAI, .gemini, .openRouter: .api
        }
    }

    /// Kept for old files, never for new conversations.
    public var isRetired: Bool { !Self.offered.contains(self) }

    public var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .claudeCode: "Claude Code"
        case .codex: "ChatGPT (Codex)"
        }
    }

    /// Whether the service needs a key at all. The on-device model does not, and neither
    /// does an engine: those are signed in on their own, outside the app.
    public var requiresCredential: Bool {
        self != .apple && !isEngine
    }

    /// A vendor's own agent on this Mac, driven as a subprocess, rather than a service
    /// reached over HTTP with a key. See `ChatEngine`.
    public var isEngine: Bool {
        self == .claudeCode || self == .codex
    }

    /// The engine behind this provider, if it is one.
    public var engine: ChatEngine? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        default: nil
        }
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
        // The engine's own default — whatever the user set it to — rather than a name
        // chosen here that would be stale by the next release of either.
        case .claudeCode, .codex: ChatEngine.defaultModel
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
                    var splitter = LineSplitter()
                    for try await byte in bytes {
                        if let line = splitter.feed(byte) {
                            try Task.checkCancellation()
                            continuation.yield(line)
                        }
                    }
                    if let line = splitter.finish() { continuation.yield(line) }
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
