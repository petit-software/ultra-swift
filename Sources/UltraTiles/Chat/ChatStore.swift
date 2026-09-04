import Foundation
import UltraChat

/// One pane's chat: the conversation on screen, the others on disk, and the answer that
/// is arriving.
///
/// Owned by the tile FACTORY rather than the view, the way an editor's tabs are: a pane is
/// rebuilt when it is converted or restored, and an answer half-way through streaming must
/// not die with the view that was showing it.
@MainActor
@Observable
public final class ChatStore {
    /// Every conversation this project has, newest first. Summaries for the switcher; the
    /// one on screen is `current`.
    public private(set) var conversations: [ChatConversation] = []
    public private(set) var current: ChatConversation
    public private(set) var isStreaming = false
    /// Something that stopped a request before an answer began. Shown once, in a bar,
    /// and cleared by the next send. A failure mid-answer is a note on the message instead.
    public private(set) var error: String?
    /// What each service says it offers, once asked. Empty until `refreshModels`.
    public private(set) var models: [ChatProviderID: [String]] = [:]
    /// Why the on-device model cannot be used, read once at construction so the empty
    /// state can say so before anyone types.
    public let appleUnavailable: String?

    /// The header follows the conversation: its title, and the model it is on.
    public var onChange: ((ChatConversation) -> Void)?

    private let archive: ChatArchive
    private let root: URL
    private let makeProvider: (ChatProviderID) -> any ChatProvider
    private var task: Task<Void, Never>?

    public init(root: URL, conversationID: UUID? = nil,
                makeProvider: @escaping (ChatProviderID) -> any ChatProvider = ChatCredentials.provider(for:)) {
        self.root = root
        self.archive = ChatArchive(root: root)
        self.makeProvider = makeProvider
        self.appleUnavailable = AppleProvider.unavailableReason
        conversations = archive.load()
        if let conversationID, let saved = archive.load(id: conversationID) {
            current = saved
        } else {
            current = Self.fresh()
        }
    }

    /// A conversation that has not been saved yet. It is written the first time it has a
    /// message in it, so opening a Chat pane and closing it leaves no file behind.
    private static func fresh() -> ChatConversation {
        let provider = ChatDefaults.startingProvider
        return ChatConversation(provider: provider, model: provider.defaultModel)
    }

    // MARK: - Conversations

    public func newConversation() {
        stop()
        // Keep the provider and model: a new thread is usually "same model, different
        // subject", and re-choosing both every time would make new threads expensive.
        var next = Self.fresh()
        next.provider = current.provider
        next.model = current.model
        current = next
        error = nil
        onChange?(current)
    }

    public func open(_ id: UUID) {
        guard id != current.id, let saved = archive.load(id: id) else { return }
        stop()
        current = saved
        error = nil
        onChange?(current)
    }

    public func delete(_ id: UUID) {
        archive.delete(id: id)
        conversations.removeAll { $0.id == id }
        if current.id == id { newConversation() }
    }

    public func setProvider(_ provider: ChatProviderID) {
        guard provider != current.provider else { return }
        current.provider = provider
        current.model = models[provider]?.first { $0 == provider.defaultModel } ?? provider.defaultModel
        saveIfStarted()
        onChange?(current)
    }

    public func setModel(_ model: String) {
        guard model != current.model else { return }
        current.model = model
        saveIfStarted()
        onChange?(current)
    }

    /// Whether the conversation on screen can be sent right now.
    public var canSend: Bool {
        if current.provider == .apple { return appleUnavailable == nil }
        return ChatCredentials.isConfigured(current.provider)
    }

    /// Why not, when `canSend` is false.
    public var blockedReason: String? {
        if current.provider == .apple { return appleUnavailable }
        return ChatCredentials.isConfigured(current.provider) ? nil
            : "No API key for \(current.provider.title). Add one in Settings ▸ Chat."
    }

    // MARK: - Sending

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        error = nil
        current.messages.append(ChatMessage(role: .user, text: trimmed))
        current.messages.append(ChatMessage(role: .assistant, text: "", model: current.model))
        touch()
        save()
        onChange?(current)

        let request = ChatRequest(model: current.model,
                                  system: Self.systemPrompt(root: root),
                                  messages: Array(current.messages.dropLast()))
        let provider = makeProvider(current.provider)
        let conversationID = current.id
        isStreaming = true
        task = Task { [weak self] in
            do {
                for try await event in provider.stream(request) {
                    guard let self, self.current.id == conversationID else { return }
                    switch event {
                    case .text(let piece):
                        self.appendToAnswer(piece)
                    case .finished(let finish):
                        self.note(for: finish).map { self.annotateAnswer($0) }
                    }
                }
                self?.finishStreaming()
            } catch is CancellationError {
                self?.finishStreaming()
            } catch {
                guard let self, self.current.id == conversationID else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if self.current.messages.last?.text.isEmpty == true {
                    // Nothing arrived: take the empty bubble away and say why above the
                    // list. The user's question stays, so it can be sent again.
                    self.current.messages.removeLast()
                    self.error = message
                } else {
                    self.annotateAnswer(message)
                }
                self.finishStreaming()
            }
        }
    }

    /// Give up on the answer that is arriving. What has arrived stays.
    public func stop() {
        guard isStreaming else { return }
        task?.cancel()
        task = nil
        if current.messages.last?.role == .assistant, current.messages.last?.text.isEmpty == true {
            current.messages.removeLast()
        } else {
            annotateAnswer("Stopped.")
        }
        finishStreaming()
    }

    private func appendToAnswer(_ piece: String) {
        guard let index = current.messages.indices.last,
              current.messages[index].role == .assistant else { return }
        current.messages[index].text += piece
    }

    private func annotateAnswer(_ note: String) {
        guard let index = current.messages.indices.last,
              current.messages[index].role == .assistant else { return }
        current.messages[index].note = note
    }

    private func finishStreaming() {
        isStreaming = false
        task = nil
        touch()
        save()
        onChange?(current)
    }

    private func note(for finish: ChatFinish) -> String? {
        switch finish.reason {
        case .complete: nil
        case .length: "The answer was cut off at the model's output limit."
        case .refusal: "The model declined to answer this."
        case .other: finish.detail.map { "Stopped: \($0)" }
        }
    }

    // MARK: - Models

    /// Ask the current provider what it offers. Quietly: a service that cannot be reached
    /// leaves the picker with what it already had.
    public func refreshModels() {
        let provider = current.provider
        let client = makeProvider(provider)
        Task { [weak self] in
            guard let list = try? await client.models(), !list.isEmpty else { return }
            self?.models[provider] = list
        }
    }

    /// What the picker offers for the current provider: the live list if there is one,
    /// with the model in use always present so the tick has something to sit beside.
    public var modelChoices: [String] {
        var list = models[current.provider] ?? [current.provider.defaultModel]
        if !list.contains(current.model) { list.insert(current.model, at: 0) }
        return list
    }

    // MARK: - Persistence

    private func touch() { current.updatedAt = Date() }

    /// Written once it has something in it; see `fresh`.
    private func saveIfStarted() {
        if !current.messages.isEmpty { save() }
    }

    private func save() {
        try? archive.save(current)
        conversations.removeAll { $0.id == current.id }
        conversations.insert(current, at: 0)
    }

    /// What every model is told before the conversation.
    static func systemPrompt(root: URL) -> String {
        """
        You are a coding assistant inside Ultra, a macOS terminal for working alongside \
        agent command-line tools. The user is working in the project folder \(root.path). \
        Be concise. Put shell commands and code in fenced code blocks with a language tag, \
        because the user can send a block straight to their terminal.
        """
    }
}
