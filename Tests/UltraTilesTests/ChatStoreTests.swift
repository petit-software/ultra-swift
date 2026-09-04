import Testing
import Foundation
@testable import UltraTiles
@testable import UltraChat

/// The chat store against a scripted provider: what a send does to the conversation, what
/// a failure does, and what reaches disk.
@Suite("Chat store")
@MainActor
struct ChatStoreTests {

    /// Answers with a fixed script, or fails, and remembers what it was asked.
    final class ScriptedProvider: ChatProvider, @unchecked Sendable {
        let id = ChatProviderID.anthropic
        var events: [ChatEvent]
        var failure: Error?
        var requests: [ChatRequest] = []

        init(events: [ChatEvent] = [], failure: Error? = nil) {
            self.events = events
            self.failure = failure
        }

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
            requests.append(request)
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
        }

        func models() async throws -> [String] { ["claude-opus-5"] }
    }

    private func scratchRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-chat-store-\(UUID().uuidString)")
    }

    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if !store.isStreaming { return }
        }
        Issue.record("the answer never finished")
    }

    @Test("a send appends the question, streams the answer into one message, and saves")
    func send() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider(events: [
            .text("Hel"), .text("lo"), .finished(ChatFinish(reason: .complete)),
        ])
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)

        store.send("  Hi there  ")
        #expect(store.isStreaming)
        #expect(store.current.messages.map(\.role) == [.user, .assistant])
        #expect(store.current.messages.first?.text == "Hi there")
        try await settle(store)

        #expect(store.current.messages.last?.text == "Hello")
        #expect(store.current.messages.last?.note == nil)
        #expect(store.current.messages.last?.model == "claude-opus-5")
        // The provider saw the system prompt, the history WITHOUT the empty answer slot,
        // and the model the conversation is on.
        let request = try #require(provider.requests.first)
        #expect(request.model == "claude-opus-5")
        #expect(request.system?.contains(root.path) == true)
        #expect(request.messages.map(\.text) == ["Hi there"])
        // On disk, and listed.
        #expect(ChatArchive(root: root).load(id: store.current.id)?.messages.count == 2)
        #expect(store.conversations.map(\.id) == [store.current.id])
    }

    @Test("a cut-off or refused answer says so under the message")
    func notes() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider(events: [.text("Part"), .finished(ChatFinish(reason: .length))])
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)
        store.send("Go")
        try await settle(store)
        #expect(store.current.messages.last?.text == "Part")
        #expect(store.current.messages.last?.note?.contains("cut off") == true)
    }

    @Test("a failure before any text removes the empty answer and reports above the list")
    func failureBeforeText() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider(failure: ChatError.http(status: 401, message: "bad key"))
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)
        store.send("Go")
        try await settle(store)
        #expect(store.current.messages.map(\.role) == [.user])
        #expect(store.error == "bad key")
        // The next send clears it.
        provider.failure = nil
        provider.events = [.text("ok"), .finished(ChatFinish(reason: .complete))]
        store.send("Again")
        #expect(store.error == nil)
        try await settle(store)
        #expect(store.current.messages.count == 3)
    }

    @Test("a failure mid-answer keeps what arrived and notes the error on it")
    func failureMidAnswer() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider(events: [.text("Half")],
                                        failure: ChatError.http(status: 0, message: "dropped"))
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)
        store.send("Go")
        try await settle(store)
        #expect(store.current.messages.last?.text == "Half")
        #expect(store.current.messages.last?.note == "dropped")
        #expect(store.error == nil)
    }

    @Test("a new conversation keeps the model, and the old one is still on disk")
    func newConversation() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider(events: [.text("x"), .finished(ChatFinish(reason: .complete))])
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)
        store.setModel("claude-sonnet-5")
        store.send("First")
        try await settle(store)
        let first = store.current.id

        store.newConversation()
        #expect(store.current.id != first)
        #expect(store.current.messages.isEmpty)
        #expect(store.current.model == "claude-sonnet-5")
        // Empty, so not saved: the list still holds only the first.
        #expect(store.conversations.map(\.id) == [first])

        store.open(first)
        #expect(store.current.id == first)
        #expect(store.current.messages.count == 2)

        // A store built later on the same conversation reopens it.
        let again = ChatStore(root: root, conversationID: first, makeProvider: { _ in provider })
        #expect(again.current.messages.map(\.text) == ["First", "x"])
    }

    @Test("stop keeps a partial answer and drops an empty one")
    func stop() async throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A provider that never finishes.
        struct Stalled: ChatProvider {
            let id = ChatProviderID.anthropic
            func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.text("Some"))
                    // Never finished; cancellation ends it.
                }
            }
            func models() async throws -> [String] { [] }
        }
        let store = ChatStore(root: root, makeProvider: { _ in Stalled() })
        store.setProvider(.anthropic)
        store.send("Go")
        // Until the first piece has landed — the point is what stop does to a PARTIAL answer.
        for _ in 0..<100 where store.current.messages.last?.text.isEmpty == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isStreaming)
        #expect(store.current.messages.last?.text == "Some")
        store.stop()
        #expect(!store.isStreaming)
        #expect(store.current.messages.last?.text == "Some")
        #expect(store.current.messages.last?.note == "Stopped.")
    }
}
