import Foundation

/// Claude, through the user's own Claude Code binary.
///
/// One `claude -p` per turn, speaking stream-json on stdout: the same events the API
/// streams, wrapped in a line each, plus the agent's own — the tools it called, the
/// result. The conversation is Claude Code's: the first turn names a session, every
/// later one resumes it, so the history is never sent twice. It has its own tools and may
/// change the project with them: edits are accepted without asking, since nobody is at
/// the prompt to ask; a command is allowed by the user's own Claude Code rules or not at
/// all. The pane shows each edit and command as a row above the answer.
public struct ClaudeCodeProvider: ChatProvider {
    public let id = ChatProviderID.claudeCode
    let executable: URL?

    public init(executable: URL? = ChatEngine.claudeCode.executable) {
        self.executable = executable
    }

    /// The command line, in the shape the headless mode documents. Public so a test can
    /// read it. The prompt goes on stdin, so no flag can swallow it.
    public static func arguments(model: String, system: String?, session: String,
                                 resume: Bool) -> [String] {
        var arguments = [
            "-p", "--verbose",
            "--output-format", "stream-json", "--include-partial-messages",
            // No MCP servers from the project's settings and no browser: a chat has
            // nobody at a prompt to answer the questions those raise. Edits are accepted
            // for the same reason; a command follows the user's own permission rules.
            "--strict-mcp-config", "--no-chrome",
            "--permission-mode", "acceptEdits",
        ]
        if model != ChatEngine.defaultModel { arguments += ["--model", model] }
        if let system, !system.isEmpty { arguments += ["--append-system-prompt", system] }
        arguments += resume ? ["--resume", session] : ["--session-id", session]
        return arguments
    }

    // MARK: - Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let box = ProcessBox()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let executable else { throw ChatError.notInstalled(id) }
                    let prompt = request.messages.last?.text ?? ""
                    if let session = request.session {
                        let outcome = try await run(executable, box: box, request: request,
                                                    prompt: prompt, session: session, resume: true,
                                                    yield: { continuation.yield($0) })
                        if outcome == .finished {
                            continuation.finish()
                            return
                        }
                        // Claude Code no longer has the session — its history was cleaned
                        // up, or the folder moved. Start another and tell it what was said.
                    }
                    let session = UUID().uuidString.lowercased()
                    continuation.yield(.session(session))
                    _ = try await run(executable, box: box, request: request,
                                      prompt: request.session == nil ? prompt : ChatEngine.transcript(request.messages),
                                      session: session, resume: false,
                                      yield: { continuation.yield($0) })
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.terminate()
            }
        }
    }

    enum Outcome: Equatable {
        case finished
        /// The session to resume was not there. Nothing was yielded.
        case sessionLost
    }

    private func run(_ executable: URL, box: ProcessBox, request: ChatRequest, prompt: String,
                     session: String, resume: Bool,
                     yield: @escaping @Sendable (ChatEvent) -> Void) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(model: request.model, system: request.system,
                                           session: session, resume: resume)
        process.environment = Subprocess.environment()
        process.currentDirectoryURL = request.workingDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        box.hold(process)
        EngineLog.note(.claudeCode, "started pid \(process.processIdentifier) \(resume ? "resuming" : "starting") \(session) in \(request.workingDirectory?.path ?? "?")")
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        async let errorText = Subprocess.read(stderr.fileHandleForReading)

        // A line must arrive now and then, or the process is given up on: one that has
        // died without closing its pipe, or is waiting on something nobody can answer,
        // would otherwise leave the chat waiting forever.
        let watchdog = Watchdog(limit: Subprocess.turnInactivityLimit) { box.terminate() }
        var state = State(workingDirectory: request.workingDirectory)
        var lines = 0
        do {
            for try await line in stdout.fileHandleForReading.engineLines() {
                try Task.checkCancellation()
                await watchdog.touch()
                lines += 1
                for event in try Self.handle(line: line, state: &state) { yield(event) }
            }
        } catch {
            await watchdog.stop()
            box.terminate()
            EngineLog.note(.claudeCode, "turn failed after \(lines) lines: \(error)")
            throw error
        }
        await watchdog.stop()
        let stderrText = await errorText
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        EngineLog.note(.claudeCode, "exited \(process.terminationStatus) after \(lines) lines, finished: \(state.finished)")
        if state.finished { return .finished }
        if await watchdog.fired {
            throw ChatError.unavailable("Claude Code said nothing for \(Int(Subprocess.turnInactivityLimit.components.seconds / 60)) minutes and was stopped.")
        }

        // It stopped without saying how. stderr says why, in its words.
        let reason = Subprocess.lastLine(of: stderrText) ?? ""
        EngineLog.note(.claudeCode, "stderr: \(reason)")
        if resume, reason.contains("No conversation found") { return .sessionLost }
        if reason.localizedCaseInsensitiveContains("log in")
            || reason.localizedCaseInsensitiveContains("login")
            || reason.localizedCaseInsensitiveContains("logged in") {
            throw ChatError.notSignedIn(id)
        }
        throw ChatError.unavailable(reason.isEmpty
                                    ? "Claude Code stopped (exit \(process.terminationStatus))."
                                    : reason)
    }

    // MARK: - Lines

    /// What has been learned from the turn so far.
    struct State {
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var finished = false
        /// Calls already announced. The agent repeats its message as blocks arrive.
        var announcedCalls: Set<String> = []
        /// Where the project is, so a path in a command can be looked at on disk.
        var workingDirectory: URL?
        /// What each announced call was counted as, to be corrected by its result.
        var changes: [String: [ChatFileChange]] = [:]
    }

    /// One line of stream-json as chat events — none, for the many lines that carry
    /// nothing a chat shows. Public so the parsing is testable against a transcript.
    public static func handle(line: String) throws -> [ChatEvent] {
        var state = State()
        return try handle(line: line, state: &state)
    }

    static func handle(line: String, state: inout State) throws -> [ChatEvent] {
        // Claude Code may print a warning line between the JSON; it is not an event.
        guard let data = line.data(using: .utf8), let object = HTTPProviderSupport.object(data) else {
            return []
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.text(text)]
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    state.inputTokens = usage["input_tokens"] as? Int
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    state.stopReason = delta["stop_reason"] as? String ?? state.stopReason
                }
                if let usage = event["usage"] as? [String: Any] {
                    state.outputTokens = usage["output_tokens"] as? Int ?? state.outputTokens
                }
            default:
                break
            }
            return []
        case "assistant":
            // The text came as deltas already; what is new here is the tools it called.
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use",
                      let id = block["id"] as? String, let name = block["name"] as? String,
                      state.announcedCalls.insert(id).inserted else { return nil }
                let input = block["input"] ?? [:]
                let arguments = (try? HTTPProviderSupport.json(input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let call = ChatToolCall(id: id, name: name, arguments: arguments)
                let changes = ChatEngine.fileChanges(of: call, in: state.workingDirectory)
                if let changes { state.changes[id] = changes }
                return .toolCall(ChatToolCall(id: id, name: name, arguments: arguments, changes: changes))
            }
        case "user":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String else { return nil }
                // An edit that failed — the old text not found, the file not read first —
                // changed nothing, whatever its arguments promised.
                let result = resultText(block["content"])
                let failed = block["is_error"] as? Bool == true
                return .toolResult(id: id, result: result,
                                   changes: failed ? [] : settled(state.changes[id], by: result))
            }
        case "result":
            state.finished = true
            if object["is_error"] as? Bool == true {
                let errors = (object["errors"] as? [String])?.joined(separator: "\n")
                let message = (object["result"] as? String) ?? errors ?? "Claude Code reported an error."
                if message.localizedCaseInsensitiveContains("log in")
                    || message.localizedCaseInsensitiveContains("login") {
                    throw ChatError.notSignedIn(.claudeCode)
                }
                throw ChatError.http(status: 0, message: message)
            }
            let usage = object["usage"] as? [String: Any]
            let reason: ChatFinish.Reason = switch state.stopReason ?? (object["stop_reason"] as? String) {
            case nil, "end_turn", "stop_sequence", "tool_use": .complete
            case "max_tokens": .length
            case "refusal": .refusal
            default: .other
            }
            return [.finished(ChatFinish(
                reason: reason,
                detail: reason == .other ? state.stopReason : nil,
                inputTokens: usage?["input_tokens"] as? Int ?? state.inputTokens,
                outputTokens: usage?["output_tokens"] as? Int ?? state.outputTokens))]
        default:
            return []
        }
    }

    /// A write's kind, as its result tells it: whether the file was there was read off
    /// the disk as the call was announced, and the result says for sure — "File created
    /// successfully" for a new one, "has been updated" for one that was there. Nil when
    /// there is nothing to correct, which leaves the call's own count.
    static func settled(_ changes: [ChatFileChange]?, by result: String) -> [ChatFileChange]? {
        guard var changes, changes.count == 1 else { return nil }
        if result.hasPrefix("File created successfully") {
            guard changes[0].kind != .added else { return nil }
            changes[0].kind = .added
            changes[0].deletions = 0
        } else if result.contains("has been updated successfully") {
            guard changes[0].kind == .added else { return nil }
            changes[0].kind = .modified
        } else {
            return nil
        }
        return changes
    }

    /// A tool result's text: a string, or blocks of text joined. Cut to what the
    /// project tools would return, since it is stored with the conversation.
    static func resultText(_ content: Any?) -> String {
        let text: String
        switch content {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default:
            text = ""
        }
        guard text.count > ProjectFiles.maxCharacters else { return text }
        return String(text.prefix(ProjectFiles.maxCharacters)) + "\n…"
    }

    // MARK: - Models

    /// Claude Code takes an alias or a full id; the aliases are what it documents, and
    /// the default is whatever the user set in it.
    public func models() async throws -> [String] {
        guard executable != nil else { throw ChatError.notInstalled(id) }
        return [ChatEngine.defaultModel, "opus", "sonnet", "haiku"]
    }
}

/// A timer that fires when nothing has touched it for a while, and does one thing then.
actor Watchdog {
    private let limit: Duration
    private let onFire: @Sendable () -> Void
    private var timer: Task<Void, Never>?
    private(set) var fired = false

    init(limit: Duration, onFire: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onFire = onFire
        Task { await self.touch() }
    }

    func touch() {
        timer?.cancel()
        timer = Task { [limit] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    private func fire() {
        fired = true
        onFire()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
