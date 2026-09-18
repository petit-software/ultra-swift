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
                    let tools: [any Tool] = request.toolbox.map { toolbox in
                        toolbox.tools.compactMap { tool in
                            BridgedTool(tool, toolbox: toolbox) { continuation.yield($0) }
                        }
                    } ?? []
                    let session = LanguageModelSession(tools: tools, transcript: Self.transcript(
                        system: request.system, history: request.messages.dropLast(), tools: tools))
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
    /// One of our tools, as the framework's. The session runs the loop itself — it calls
    /// this, reads what comes back, and goes on — so all that is left to do is say so to
    /// the pane, through `report`.
    struct BridgedTool: Tool {
        /// The on-device model's whole context is a few thousand tokens. A result is cut
        /// to a size that leaves room for the question and the answer; the cut is said in
        /// the text, so the model knows there was more and can ask for a narrower piece.
        static let maxResultCharacters = 3_000

        let name: String
        let description: String
        let parameters: GenerationSchema
        let toolbox: any ChatToolbox
        let report: @Sendable (ChatEvent) -> Void

        /// Nil if the schema cannot be built, in which case the tool is simply not offered.
        init?(_ tool: ChatTool, toolbox: any ChatToolbox, report: @escaping @Sendable (ChatEvent) -> Void) {
            let properties = tool.parameters.map { parameter in
                DynamicGenerationSchema.Property(
                    name: parameter.name, description: parameter.description,
                    schema: parameter.kind == .integer
                        ? DynamicGenerationSchema(type: Int.self)
                        : DynamicGenerationSchema(type: String.self),
                    isOptional: !parameter.isRequired)
            }
            let root = DynamicGenerationSchema(name: tool.name, description: tool.description,
                                               properties: properties)
            guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
            self.name = tool.name
            self.description = tool.description
            self.parameters = schema
            self.toolbox = toolbox
            self.report = report
        }

        func call(arguments: GeneratedContent) async throws -> String {
            let call = ChatToolCall(id: UUID().uuidString, name: name, arguments: arguments.jsonString)
            report(.toolCall(call))
            var result = await toolbox.run(call)
            if result.count > Self.maxResultCharacters {
                result = String(result.prefix(Self.maxResultCharacters))
                    + "\n… cut off: the on-device model can only take in a little at a time."
            }
            report(.toolResult(id: call.id, result: result))
            return result
        }
    }

    /// The framework's transcript, from ours. Earlier turns go in as their text alone:
    /// what a tool returned three questions ago is not worth the little context there is.
    static func transcript(system: String?, history: ArraySlice<ChatMessage>,
                           tools: [any Tool] = []) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let system, !system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: system))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
        }
        for message in history where !message.text.isEmpty {
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
