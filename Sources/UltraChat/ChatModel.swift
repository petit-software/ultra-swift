import Foundation

/// Who said a thing in a conversation.
public enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

/// One turn of a conversation, as stored and as shown.
public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var createdAt: Date
    /// The provider and model that produced an assistant turn. Nil for the user's own.
    public var model: String?
    /// Why the model stopped, when it was not simply done: a refusal, a length cap, an
    /// error. Shown under the message so a short answer is not mistaken for a full one.
    public var note: String?

    public init(id: UUID = UUID(), role: ChatRole, text: String, createdAt: Date = Date(),
                model: String? = nil, note: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.note = note
    }
}

/// A conversation with one provider and one model, as a file on disk.
///
/// The provider and model are properties of the CONVERSATION rather than of the pane, so a
/// thread started with one model stays with it and a new thread can start with another.
public struct ChatConversation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var provider: ChatProviderID
    public var model: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "", provider: ChatProviderID, model: String,
                messages: [ChatMessage] = [], createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.provider = provider
        self.model = model
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the conversation is called: the title if one was set, else the first thing
    /// the user asked, trimmed to a line.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first, !first.isEmpty
        else { return "New chat" }
        return first.count > 48 ? String(first.prefix(48)).trimmingCharacters(in: .whitespaces) + "…" : first
    }
}

/// What a provider is asked for: the system prompt, the history, and the model to use.
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var system: String?
    public var messages: [ChatMessage]

    public init(model: String, system: String? = nil, messages: [ChatMessage]) {
        self.model = model
        self.system = system
        self.messages = messages
    }
}

/// How a response ended.
public struct ChatFinish: Sendable, Equatable {
    public enum Reason: String, Sendable {
        /// The model said everything it had to say.
        case complete
        /// The output cap was hit; the answer is cut off.
        case length
        /// The provider declined to answer.
        case refusal
        /// Something else, named by the provider.
        case other
    }

    public var reason: Reason
    public var detail: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(reason: Reason, detail: String? = nil, inputTokens: Int? = nil,
                outputTokens: Int? = nil) {
        self.reason = reason
        self.detail = detail
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// One thing a streaming response says.
public enum ChatEvent: Sendable, Equatable {
    /// More of the answer. Appended to what came before.
    case text(String)
    /// The end, and how it ended.
    case finished(ChatFinish)
}

/// What went wrong with a request, in words the pane can show.
public enum ChatError: Error, LocalizedError, Equatable, Sendable {
    case missingCredential(ChatProviderID)
    case unavailable(String)
    case http(status: Int, message: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            "No API key for \(provider.title). Add one in Settings ▸ Chat."
        case .unavailable(let reason):
            reason
        case .http(let status, let message):
            message.isEmpty ? "The request failed (HTTP \(status))." : message
        case .malformed(let what):
            "Could not read the response: \(what)"
        }
    }
}
