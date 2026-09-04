import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, through the Foundation Models framework.
///
/// The provider that needs nothing: no key, no network, no account. It is the default a
/// fresh Chat pane opens on, so the pane does something the moment it exists. It is also
/// the one provider this can be tested against for real on a development Mac.
///
/// A session is rebuilt from the conversation on every request rather than kept between
/// them. The framework's session holds its own transcript, and a second copy of the
/// history — ours on disk, its in memory — would drift the first time a message was edited
/// or a conversation reopened. Rebuilding costs a little prompt processing and keeps one
/// truth.
public struct AppleProvider: ChatProvider {
    public let id = ChatProviderID.apple

    public init() {}

    /// Why the model cannot be used right now, in the user's words, or nil when it can.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac cannot run Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in System Settings."
            case .modelNotReady:
                return "The on-device model is still downloading."
            @unknown default:
                return "The on-device model is unavailable."
            }
        }
        #else
        return "Apple Intelligence is not available on this system."
        #endif
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason { throw ChatError.unavailable(reason) }
                    #if canImport(FoundationModels)
                    guard let last = request.messages.last, last.role == .user else {
                        throw ChatError.malformed("nothing to answer")
                    }
                    let session = LanguageModelSession(transcript: Self.transcript(
                        system: request.system, history: request.messages.dropLast()))
                    // Snapshots are CUMULATIVE — each carries the whole answer so far — and
                    // the chat wants deltas, so the previously seen prefix is subtracted.
                    var seen = ""
                    for try await snapshot in session.streamResponse(to: last.text) {
                        try Task.checkCancellation()
                        let whole = snapshot.content
                        guard whole.count > seen.count else { continue }
                        let delta = whole.hasPrefix(seen) ? String(whole.dropFirst(seen.count)) : whole
                        seen = whole
                        continuation.yield(.text(delta))
                    }
                    continuation.yield(.finished(ChatFinish(reason: .complete)))
                    continuation.finish()
                    #endif
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    #if canImport(FoundationModels)
                    if let generation = error as? LanguageModelSession.GenerationError {
                        continuation.finish(throwing: ChatError.unavailable(Self.describe(generation)))
                        return
                    }
                    #endif
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func models() async throws -> [String] { [ChatProviderID.apple.defaultModel] }

    #if canImport(FoundationModels)
    /// The framework's transcript, from ours.
    static func transcript(system: String?, history: ArraySlice<ChatMessage>) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let system, !system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: system))], toolDefinitions: [])))
        }
        for message in history {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: message.text))
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            }
        }
        return Transcript(entries: entries)
    }

    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            "The conversation is too long for the on-device model. Start a new chat."
        case .guardrailViolation:
            "The on-device model declined this request."
        case .unsupportedLanguageOrLocale:
            "The on-device model does not support this language."
        case .rateLimited:
            "The on-device model is busy. Try again in a moment."
        default:
            error.localizedDescription
        }
    }
    #endif
}
